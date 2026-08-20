#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
VERSION="${MAINFRAME_TOOLKIT_VERSION:-0.1.13}"
UV_VERSION="${UV_VERSION:-0.12.5}"

SOURCE="$ROOT/.claude/skills/mainframe-jcl-migration"
TARGET="$ROOT/.devin/skills/mainframe-jcl-migration-devin"
MCP_CONFIG="$ROOT/.devin/mcp_config.json"
BIN_DIR="$ROOT/.devin/bin"
UV_CACHE_DIR="$ROOT/.devin/cache/uv"
UVX="$BIN_DIR/uvx.exe"

fail() {
  printf 'Erro: %s\n' "$1" >&2
  exit 1
}

[[ -f "$SOURCE/SKILL.md" ]] ||
  fail "skill MCP não encontrada em $SOURCE/SKILL.md"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) fail "este instalador deve ser executado no Git Bash do Windows" ;;
esac

command -v powershell.exe >/dev/null ||
  fail "PowerShell do Windows não encontrado"

command -v cygpath >/dev/null ||
  fail "cygpath não encontrado; execute o script pelo Git Bash"

case "$(uname -m)" in
  x86_64|amd64) UV_TARGET="x86_64-pc-windows-msvc" ;;
  arm64|aarch64) UV_TARGET="aarch64-pc-windows-msvc" ;;
  *) fail "arquitetura do Windows não suportada: $(uname -m)" ;;
esac

mkdir -p "$TARGET" "$BIN_DIR" "$UV_CACHE_DIR"
cp -R "$SOURCE/." "$TARGET/"

PS_SCRIPT="$ROOT/.devin/setup-devin.tmp.ps1"
trap 'rm -f "$PS_SCRIPT"' EXIT

cat >"$PS_SCRIPT" <<'POWERSHELL'
param(
    [string]$SkillPath,
    [string]$McpPath,
    [string]$BinDir,
    [string]$CacheDir,
    [string]$ToolkitVersion,
    [string]$UvVersion,
    [string]$UvTarget
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$utf8 = New-Object Text.UTF8Encoding($false)

$requiredTools = @(
    "mainframe_preflight",
    "mainframe_dependency_graph",
    "mainframe_get_callers",
    "mainframe_resolve_copybook",
    "mainframe_impact_analysis",
    "mainframe_run_migration_tool",
    "mainframe_query_artifact"
)

$content = [IO.File]::ReadAllText($SkillPath, [Text.Encoding]::UTF8)
$missing = @($requiredTools | Where-Object { -not $content.Contains($_) })
if ($missing.Count -ne 0) {
    throw "A skill MCP de origem não contém as tools esperadas: $($missing -join ', ')"
}

$namePattern = "(?m)^name:\s*mainframe-jcl-migration\s*$"
if ([regex]::Matches($content, $namePattern).Count -ne 1) {
    throw "Não foi possível adaptar o nome da skill."
}
$content = [regex]::Replace(
    $content,
    $namePattern,
    "name: mainframe-jcl-migration-devin",
    1
)

if ($content -notmatch "(?m)^triggers:") {
    $argumentPattern = "(?m)^(argument-hint:[^\r\n]*(?:\r?\n))"
    if ([regex]::Matches($content, $argumentPattern).Count -ne 1) {
        throw "Não foi possível adicionar os triggers."
    }
    $content = [regex]::Replace(
        $content,
        $argumentPattern,
        ('$1' + "triggers:`n  - user`n  - model`n"),
        1
    )
}
[IO.File]::WriteAllText($SkillPath, $content, $utf8)

[IO.Directory]::CreateDirectory($BinDir) | Out-Null
[IO.Directory]::CreateDirectory($CacheDir) | Out-Null
$uvxPath = Join-Path $BinDir "uvx.exe"
if (-not (Test-Path -LiteralPath $uvxPath -PathType Leaf)) {
    $archive = Join-Path ([IO.Path]::GetTempPath()) ("uv-" + [Guid]::NewGuid() + ".zip")
    $url = "https://github.com/astral-sh/uv/releases/download/$UvVersion/uv-$UvTarget.zip"
    Write-Host "Baixando runtime portátil uv $UvVersion..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $BinDir -Force
    }
    finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path -LiteralPath $uvxPath -PathType Leaf)) {
    throw "O pacote portátil do uv não forneceu $uvxPath."
}

if (Test-Path -LiteralPath $McpPath -PathType Leaf) {
    try {
        $config = [IO.File]::ReadAllText($McpPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    }
    catch {
        throw "JSON inválido em ${McpPath}: $($_.Exception.Message)"
    }
}
else {
    $config = [PSCustomObject]@{}
}

if ($config -isnot [PSCustomObject]) {
    throw "$McpPath precisa conter um objeto JSON."
}
if ($null -eq $config.PSObject.Properties["mcpServers"]) {
    $config | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{})
}
if ($config.mcpServers -isnot [PSCustomObject]) {
    throw "'mcpServers' em $McpPath precisa ser um objeto."
}

$server = [ordered]@{
    command = $uvxPath
    args = @(
        "--from",
        "mainframe-modernization-toolkit==$ToolkitVersion",
        "mainframe-toolkit",
        "mcp",
        "serve"
    )
    env = [ordered]@{
        UV_CACHE_DIR = $CacheDir
    }
}
$config.mcpServers |
    Add-Member -NotePropertyName "mainframe-toolkit" -NotePropertyValue $server -Force

$json = $config | ConvertTo-Json -Depth 20
$temporary = "$McpPath.tmp"
[IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, $utf8)
Move-Item -LiteralPath $temporary -Destination $McpPath -Force
[void](ConvertFrom-Json ([IO.File]::ReadAllText($McpPath, [Text.Encoding]::UTF8)))
POWERSHELL

powershell.exe \
  -NoLogo \
  -NoProfile \
  -NonInteractive \
  -ExecutionPolicy Bypass \
  -File "$(cygpath -w "$PS_SCRIPT")" \
  "$(cygpath -w "$TARGET/SKILL.md")" \
  "$(cygpath -w "$MCP_CONFIG")" \
  "$(cygpath -w "$BIN_DIR")" \
  "$(cygpath -w "$UV_CACHE_DIR")" \
  "$VERSION" \
  "$UV_VERSION" \
  "$UV_TARGET"

rm -f "$PS_SCRIPT"
trap - EXIT

printf 'Validando pacote %s...\n' "$VERSION"

INSTALLED_VERSION="$(
  UV_CACHE_DIR="$UV_CACHE_DIR" "$UVX" \
    --from "mainframe-modernization-toolkit==$VERSION" \
    mainframe-toolkit --version |
    tr -d '\r'
)"

[[ "$INSTALLED_VERSION" == "$VERSION" ]] ||
  fail "versão inesperada: $INSTALLED_VERSION"

printf '\nConfiguração concluída.\n'
printf 'Skill: %s\n' \
  ".devin/skills/mainframe-jcl-migration-devin/SKILL.md"
printf 'MCP:   %s\n' ".devin/mcp_config.json"
printf 'Versão validada: %s\n' "$INSTALLED_VERSION"
printf '\nReinicie o Devin Desktop e invoque:\n'
printf '/mainframe-jcl-migration-devin <workspace> <JOB.jcl>\n'
