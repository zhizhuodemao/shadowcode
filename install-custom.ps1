# ─────────────────────────────────────────────────────────
#  Custom Installer (Windows)
#
#  用法:
#    powershell -ExecutionPolicy Bypass -File install-custom.ps1
#    powershell -ExecutionPolicy Bypass -File install-custom.ps1 -Version 2.1.126
#    powershell -ExecutionPolicy Bypass -File install-custom.ps1 -Uninstall
# ─────────────────────────────────────────────────────────

param(
    [string]$Version = "2.1.126",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SHADOWCODE_DIR = Join-Path $env:USERPROFILE ".shadowcode"
$BIN_DIR = Join-Path $env:USERPROFILE ".local\bin"

function Info($msg)  { Write-Host "  + $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "  x $msg" -ForegroundColor Red }
function Dim($msg)   { Write-Host "    $msg" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  Custom Installer (Windows)" -ForegroundColor White
Write-Host ""

# ─── Uninstall ────────────────────────────────────

if ($Uninstall) {
    $dirs = @($BIN_DIR)
    $claudeBin = (Get-Command claude -ErrorAction SilentlyContinue)?.Source
    if ($claudeBin) { $dirs += Split-Path $claudeBin }

    foreach ($dir in ($dirs | Select-Object -Unique)) {
        if (-not $dir) { continue }
        $origCmd = Join-Path $dir "claude.orig.cmd"
        $claudeCmd = Join-Path $dir "claude.cmd"
        if (Test-Path $origCmd) { Move-Item -Force $origCmd $claudeCmd; Info "Original claude restored" }
        $shadowcodeCmd = Join-Path $dir "shadowcode.cmd"
        if (Test-Path $shadowcodeCmd) { Remove-Item -Force $shadowcodeCmd; Info "Removed alias" }
    }

    @("vendor","cli.original.js","cli.original.js.bak","cli.original.cjs","cli.original.cjs.bak",
      "cli.cjs","patch.mjs","extract-natives.mjs","post-process.mjs","repatch.mjs",".source-version"
    ) | ForEach-Object {
        $p = Join-Path $SHADOWCODE_DIR $_
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    }

    Info "Uninstalled. Restart your terminal."
    exit 0
}

# ─── Prerequisites ────────────────────────────────

try { $nv = (node -e "console.log(process.versions.node.split('.')[0])").Trim(); if ([int]$nv -lt 18) { throw } }
catch { Warn "Node.js >= 18 required. https://nodejs.org"; exit 1 }

try { $null = Get-Command npm -ErrorAction Stop } catch { Warn "npm required"; exit 1 }

$BUN_BIN = ""
try { $BUN_BIN = (Get-Command bun -ErrorAction Stop).Source }
catch {
    $bunPath = Join-Path $env:USERPROFILE ".bun\bin\bun.exe"
    if (Test-Path $bunPath) { $BUN_BIN = $bunPath }
    else {
        Dim "Installing Bun..."
        try { irm https://bun.sh/install.ps1 | iex; $BUN_BIN = $bunPath }
        catch { Warn "Bun installation failed. https://bun.sh"; exit 1 }
    }
}
if (-not (Test-Path $BUN_BIN)) { Warn "Bun not found"; exit 1 }
Info "Bun: $(& $BUN_BIN --version)"

try { $rgv = (rg --version | Select-Object -First 1); Info "ripgrep: $rgv" }
catch { Warn "ripgrep required. Install: scoop install ripgrep"; exit 1 }

# ─── Download ─────────────────────────────────────

New-Item -ItemType Directory -Force -Path $SHADOWCODE_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $BIN_DIR | Out-Null

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$PLATFORM = "win32-$arch"
$NPM_PKG = "@anthropic-ai/claude-code-$PLATFORM"

Dim "Fetching $NPM_PKG@$Version ..."
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) "shadowcode-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

try { Push-Location $tmpDir; npm pack "$NPM_PKG@$Version" --silent 2>$null | Out-Null; Pop-Location }
catch { Warn "npm pack failed"; exit 1 }

$tarball = Get-ChildItem "$tmpDir\*.tgz" | Select-Object -First 1
if (-not $tarball) { Warn "No .tgz found"; exit 1 }
Push-Location $tmpDir; tar xzf $tarball.FullName 2>$null; Pop-Location

$NATIVE_BIN = Join-Path $tmpDir "package\claude.exe"
if (-not (Test-Path $NATIVE_BIN)) { $NATIVE_BIN = Join-Path $tmpDir "package\claude" }
if (-not (Test-Path $NATIVE_BIN)) { Warn "Binary not found"; exit 1 }

$PKG_VERSION = (node -e "console.log(require('$($tmpDir -replace '\\','/')/package/package.json').version)").Trim()
Info "Downloaded: $NPM_PKG@$PKG_VERSION"

# ─── Copy scripts & extract ──────────────────────

Copy-Item "$SCRIPT_DIR\scripts\extract-natives.mjs" $SHADOWCODE_DIR -Force
Copy-Item "$SCRIPT_DIR\scripts\post-process.mjs" $SHADOWCODE_DIR -Force
Copy-Item "$SCRIPT_DIR\scripts\patch.mjs" $SHADOWCODE_DIR -Force
Copy-Item "$SCRIPT_DIR\scripts\repatch.mjs" $SHADOWCODE_DIR -Force
Copy-Item "$SCRIPT_DIR\scripts\cli.cjs" $SHADOWCODE_DIR -Force

$VENDOR_DIR = Join-Path $SHADOWCODE_DIR "vendor"
if (Test-Path $VENDOR_DIR) { Remove-Item -Recurse -Force $VENDOR_DIR }
New-Item -ItemType Directory -Force -Path $VENDOR_DIR | Out-Null

Dim "Extracting cli.js ..."
node (Join-Path $SHADOWCODE_DIR "extract-natives.mjs") $NATIVE_BIN $SHADOWCODE_DIR --cli-js
if (-not (Test-Path (Join-Path $SHADOWCODE_DIR "cli.original.js"))) { Warn "cli.js extraction failed"; exit 1 }

Dim "Extracting native modules ..."
node (Join-Path $SHADOWCODE_DIR "extract-natives.mjs") $NATIVE_BIN $VENDOR_DIR

Dim "Post-processing ..."
node (Join-Path $SHADOWCODE_DIR "post-process.mjs")
if (-not (Test-Path (Join-Path $SHADOWCODE_DIR "cli.original.cjs"))) { Warn "Post-process failed"; exit 1 }
Info "cli.original.cjs ready ($PKG_VERSION)"

Set-Content -Path (Join-Path $SHADOWCODE_DIR ".source-version") -Value $PKG_VERSION
Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

# ─── Patch ────────────────────────────────────────

Dim "Applying patches ..."
node (Join-Path $SHADOWCODE_DIR "patch.mjs")

# ─── 保存 patch 后的 cli.original.cjs 到项目目录 ──

$outputDir = Join-Path $SCRIPT_DIR "output"
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
Copy-Item (Join-Path $SHADOWCODE_DIR "cli.original.cjs") (Join-Path $outputDir "cli.original.cjs") -Force
Info "patch 后的 cli.original.cjs 已保存到 $outputDir"

# ─── Default configs ──────────────────────────────

$featDst = Join-Path $SHADOWCODE_DIR "features.json"
if (-not (Test-Path $featDst)) {
    Copy-Item "$SCRIPT_DIR\config\features.json" $featDst
    Info "Default features.json created"
}

# ─── Sanity check ─────────────────────────────────

Dim "Verifying Bun can load cli.original.cjs ..."
$out = & $BUN_BIN (Join-Path $SHADOWCODE_DIR "cli.cjs") --version 2>&1 | Out-String
if ($out -match "Expected CommonJS module") { Warn "Bun too old. Run: bun upgrade --canary"; exit 1 }
Info "Bun loads cli.original.cjs"

# ─── Install launcher (.cmd) ─────────────────────

$claudeBin = (Get-Command claude -ErrorAction SilentlyContinue)?.Source
if (-not $claudeBin) { $claudeBin = Join-Path $BIN_DIR "claude.cmd"; Dim "No existing claude found, installing to $BIN_DIR" }
$claudeDir = Split-Path $claudeBin

# Backup
$origCmd = Join-Path $claudeDir "claude.orig.cmd"
if (-not (Test-Path $origCmd) -and (Test-Path $claudeBin)) {
    Copy-Item $claudeBin $origCmd
    Info "Original claude backed up -> claude.orig.cmd"
}

$launcherContent = "@echo off`r`n`"$BUN_BIN`" `"$SHADOWCODE_DIR\cli.cjs`" %*"

New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
Set-Content -Path (Join-Path $claudeDir "claude.cmd") -Value $launcherContent -Encoding ASCII
Info "Command 'claude' -> patched"

if ($claudeDir -ne $BIN_DIR) {
    New-Item -ItemType Directory -Force -Path $BIN_DIR | Out-Null
    Set-Content -Path (Join-Path $BIN_DIR "claude.cmd") -Value $launcherContent -Encoding ASCII
}
Set-Content -Path (Join-Path $BIN_DIR "shadowcode.cmd") -Value $launcherContent -Encoding ASCII
Info "Command 'shadowcode' -> patched"

# ─── Done ─────────────────────────────────────────

Write-Host ""
Write-Host "  Installed!" -ForegroundColor Green
Write-Host ""
Dim "  claude       - Start patched Claude Code"
Dim "  claude.orig  - Run original unpatched Claude Code"
Write-Host ""
Dim "  Config: $SHADOWCODE_DIR\provider.json"
Dim "  Flags:  $SHADOWCODE_DIR\features.json"
Write-Host ""
