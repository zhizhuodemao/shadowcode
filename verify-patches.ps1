# ─────────────────────────────────────────────────────
#  Patch Verifier (Windows)
#
#  拉取 Claude Code，提取 cli.js，检查 patch 兼容性
#  不安装、不修改任何文件
#  日志按版本保存到 verify-logs/ 目录
#
#  用法:
#    powershell -ExecutionPolicy Bypass -File verify-patches.ps1
#    powershell -ExecutionPolicy Bypass -File verify-patches.ps1 -Version 2.1.130
# ─────────────────────────────────────────────────────

param(
    [string]$Version = "2.1.126",
    [string]$LogDir = ""
)

$ErrorActionPreference = "Stop"

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $LogDir) { $LogDir = Join-Path $SCRIPT_DIR "verify-logs" }
$SCRIPTS_DIR = Join-Path $SCRIPT_DIR "scripts"

function Info($msg)  { Write-Host "  + $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "  x $msg" -ForegroundColor Red }
function Dim($msg)   { Write-Host "    $msg" -ForegroundColor DarkGray }
function Header($msg){ Write-Host ""; Write-Host "  $msg"; Write-Host "" }

$logFile = ""
function Log($msg) {
    if ($logFile) { $msg | Tee-Object -FilePath $logFile -Append } else { Write-Output $msg }
}

Write-Host ""
Write-Host "  Patch Verifier (Windows)" -ForegroundColor White
Write-Host ""

# ─── 前置检查 ─────────────────────────────────────

try { $null = node -e "1" } catch { Warn "需要 Node.js >= 18"; exit 1 }
try { $null = Get-Command npm -ErrorAction Stop } catch { Warn "需要 npm"; exit 1 }

foreach ($f in @("extract-natives.mjs", "post-process.mjs", "patch.mjs")) {
    if (-not (Test-Path (Join-Path $SCRIPTS_DIR $f))) { Warn "未找到 scripts/$f"; exit 1 }
}

# ─── 检测平台 ─────────────────────────────────────

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$PLATFORM = "win32-$arch"

# ─── 下载 ─────────────────────────────────────────

$NPM_PKG = "@anthropic-ai/claude-code-$PLATFORM"
Dim "正在从 npm 拉取 ${NPM_PKG}@${Version} ..."

$tmpDir = Join-Path ([IO.Path]::GetTempPath()) "verify-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

try { Push-Location $tmpDir; npm pack "$NPM_PKG@$Version" --silent 2>$null | Out-Null; Pop-Location }
catch { Warn "npm pack 失败"; exit 1 }

$tarball = Get-ChildItem "$tmpDir\*.tgz" | Select-Object -First 1
if (-not $tarball) { Warn "未找到 .tgz 文件"; exit 1 }
Push-Location $tmpDir; tar xzf $tarball.FullName 2>$null; Pop-Location

$NATIVE_BIN = Join-Path $tmpDir "package\claude.exe"
if (-not (Test-Path $NATIVE_BIN)) { $NATIVE_BIN = Join-Path $tmpDir "package\claude" }
if (-not (Test-Path $NATIVE_BIN)) { Warn "未找到二进制文件"; exit 1 }

$PKG_VERSION = (node -e "console.log(require('$($tmpDir -replace '\\','/')/package/package.json').version)").Trim()
$BIN_SIZE = (Get-Item $NATIVE_BIN).Length
$BIN_SIZE_MB = [math]::Round($BIN_SIZE / 1MB, 1)

# ─── 初始化日志 ───────────────────────────────────

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $LogDir "v${PKG_VERSION}_${timestamp}.log"

@"
================================================================================
  Patch Verify Report
================================================================================
  版本:     v${PKG_VERSION}
  平台:     ${PLATFORM}
  时间:     $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  npm 包:   ${NPM_PKG}
  二进制:   ${BIN_SIZE_MB} MB
================================================================================

"@ | Set-Content $logFile

Info "已下载: ${NPM_PKG}@${PKG_VERSION}"
Dim "二进制大小: ${BIN_SIZE_MB} MB"
Dim "日志文件: ${logFile}"
Info "工具脚本已就绪"

# ─── 提取 cli.js ──────────────────────────────────

$extractDir = Join-Path $tmpDir "extract"
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

Dim "正在提取 cli.js ..."
node (Join-Path $SCRIPTS_DIR "extract-natives.mjs") $NATIVE_BIN $extractDir --cli-js

$cliOrigJs = Join-Path $extractDir "cli.original.js"
if (-not (Test-Path $cliOrigJs)) { Warn "cli.js 提取失败"; exit 1 }

Copy-Item (Join-Path $SCRIPTS_DIR "post-process.mjs") $extractDir
Push-Location $extractDir; node post-process.mjs; Pop-Location

$cliOrigCjs = Join-Path $extractDir "cli.original.cjs"
if (-not (Test-Path $cliOrigCjs)) { Warn "后处理失败"; exit 1 }

$CLI_SIZE = (Get-Item $cliOrigCjs).Length
Info "cli.original.cjs 提取完成 ($([math]::Round($CLI_SIZE / 1MB, 1)) MB)"

# ─── Patch 兼容性检查 ─────────────────────────────

Copy-Item (Join-Path $SCRIPTS_DIR "patch.mjs") $extractDir

Header "=== Patch 兼容性检查 (v${PKG_VERSION}) ==="
$verifyOutput = node (Join-Path $extractDir "patch.mjs") --verify 2>&1 | Out-String
Log $verifyOutput
Write-Output $verifyOutput

# ─── 锚点检查 ─────────────────────────────────────

$cjsContent = Get-Content $cliOrigCjs -Raw

function Check-Sentinel($name, $sentinel) {
    if ($cjsContent.Contains($sentinel)) {
        Log "  [存在] $name"
    } else {
        Log "  [缺失] $name"
    }
}

Header "=== 已有 Patch 覆盖的锚点 ==="

Check-Sentinel "CYBER_RISK_INSTRUCTION" "Assist with authorized security testing"
Check-Sentinel "URL 生成限制" "NEVER generate or guess URLs"
Check-Sentinel "操作审慎提示" "Executing actions with care"
Check-Sentinel "登录提示" "Not logged in"
Check-Sentinel "安全编码指令 (OWASP)" "OWASP top 10"
Check-Sentinel "Prompt injection 警告" "attempt at prompt injection"
Check-Sentinel "文件创建限制" "NEVER create files unless"
Check-Sentinel "权限拒绝行为约束" "do not re-attempt the exact same tool call"

Header "=== 未覆盖的 Prompt 指令层锚点 ==="

Check-Sentinel "恶意代码提醒 (旧)" "considered malware"
Check-Sentinel "恶意代码提醒 (新)" "MUST refuse to improve"
Check-Sentinel "文件创建限制 (旧措辞)" "Do not create files unless"

Header "=== 客户端硬规则层锚点 ==="

Check-Sentinel "Bash 危险模式 (process substitution)" "process substitution"
Check-Sentinel "Zsh 危险命令 (zmodload)" "zmodload"
Check-Sentinel "YOLO 分类器 (xml_2stage)" "xml_2stage"
Check-Sentinel "YOLO 分类器 (blocking for safety)" "blocking for safety"
Check-Sentinel "Unicode 清洗 (NFKC)" 'normalize("NFKC")'
Check-Sentinel "秘密扫描" "cannot be written to team memory"
Check-Sentinel "破坏性命令警告" "may discard uncommitted changes"
Check-Sentinel "敏感路径保护 (classifierApprovable)" "classifierApprovable"

# ─── 汇总 ─────────────────────────────────────────

Header "=== 汇总 ==="

$sentinels = @(
    "Assist with authorized security testing",
    "NEVER generate or guess URLs",
    "Executing actions with care",
    "Not logged in",
    "OWASP top 10",
    "attempt at prompt injection",
    "NEVER create files unless",
    "do not re-attempt the exact same tool call",
    "considered malware",
    "MUST refuse to improve",
    "Do not create files unless",
    "process substitution",
    "zmodload",
    "xml_2stage",
    "blocking for safety",
    "cannot be written to team memory",
    "may discard uncommitted changes",
    "classifierApprovable"
)

$total = $sentinels.Count
$present = ($sentinels | Where-Object { $cjsContent.Contains($_) }).Count

Log "  Claude Code:  v${PKG_VERSION}"
Log "  平台:         ${PLATFORM}"
Log "  二进制:       ${BIN_SIZE_MB} MB"
Log "  cli.js:       $([math]::Round($CLI_SIZE / 1MB, 1)) MB"
Log "  锚点存在:     ${present}/${total}"
Log "  日志已保存:   ${logFile}"

# ─── 保存 cli.original.cjs ────────────────────────

$cjsSave = Join-Path $LogDir "v${PKG_VERSION}_${timestamp}_cli.original.cjs"
Copy-Item $cliOrigCjs $cjsSave
Log "  cli.js 已保存: ${cjsSave}"
Log ""

# ─── 清理 ─────────────────────────────────────────

Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  日志已保存到: $logFile" -ForegroundColor White
Write-Host "  cli.js 已保存到: $cjsSave" -ForegroundColor White
Write-Host ""
