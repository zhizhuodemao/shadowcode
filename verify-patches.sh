#!/bin/bash
set -e

# ─────────────────────────────────────────────────────
#  Patch Verifier
#
#  拉取 Claude Code，提取 cli.js，检查 patch 兼容性
#  不安装、不修改任何文件
#  日志按版本保存到 verify-logs/ 目录
#
#  用法:
#    bash verify-patches.sh
#    bash verify-patches.sh --version 2.1.130
#    bash verify-patches.sh --log-dir /path/to/logs
# ─────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_BASE_DIR="${SCRIPT_DIR}/verify-logs"
VERSION="2.1.126"

GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

_log_file=""
_tee_out() {
  if [ -n "$_log_file" ]; then echo "$1" | tee -a "$_log_file"; else echo "$1"; fi
}
info()  { _tee_out "  ✓ $1"; }
warn()  { _tee_out "  ✗ $1"; }
dim()   { _tee_out "    $1"; }
header(){ _tee_out ""; _tee_out "  $1"; _tee_out ""; }

WORK_DIR=$(mktemp -d)
trap "rm -rf '$WORK_DIR'" EXIT

echo ""
echo -e "${BOLD}  Patch Verifier${NC}"
echo ""

# ─── 参数解析 ─────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --version) VERSION="$2"; shift 2 ;;
    --log-dir) LOG_BASE_DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ─── 前置检查 ─────────────────────────────────────

command -v node &>/dev/null || { warn "需要 Node.js >= 18"; exit 1; }
command -v npm &>/dev/null || { warn "需要 npm"; exit 1; }

# ─── 检测平台 ─────────────────────────────────────

case "$(uname -s)" in Darwin) os="darwin";; Linux) os="linux";; *) warn "不支持的平台"; exit 1;; esac
case "$(uname -m)" in arm64|aarch64) arch="arm64";; x86_64|amd64) arch="x64";; *) warn "不支持的架构"; exit 1;; esac
[ "$os" = "linux" ] && ldd /bin/ls 2>/dev/null | grep -q musl && PLATFORM="${os}-${arch}-musl" || PLATFORM="${os}-${arch}"

# ─── 下载 ─────────────────────────────────────────

NPM_PKG="@anthropic-ai/claude-code-${PLATFORM}"
dim "正在从 npm 拉取 ${NPM_PKG}@${VERSION} ..."

( cd "$WORK_DIR" && npm pack "${NPM_PKG}@${VERSION}" --silent >/dev/null 2>&1 ) || { warn "npm pack 失败"; exit 1; }
TARBALL=$(ls "$WORK_DIR"/*.tgz 2>/dev/null | head -1)
[ -z "$TARBALL" ] && { warn "未找到 .tgz 文件"; exit 1; }
( cd "$WORK_DIR" && tar xzf "$TARBALL" )

NATIVE_BIN="$WORK_DIR/package/claude"
[ ! -f "$NATIVE_BIN" ] && { warn "未找到二进制文件"; exit 1; }

PKG_VERSION=$(node -e "console.log(require('$WORK_DIR/package/package.json').version)" 2>/dev/null || echo "unknown")
BIN_SIZE=$(stat -f%z "$NATIVE_BIN" 2>/dev/null || stat -c%s "$NATIVE_BIN" 2>/dev/null || echo 0)

# ─── 初始化日志 ───────────────────────────────────

mkdir -p "$LOG_BASE_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
_log_file="${LOG_BASE_DIR}/v${PKG_VERSION}_${TIMESTAMP}.log"

cat > "$_log_file" << LOGHEADER
================================================================================
  Patch Verify Report
================================================================================
  版本:     v${PKG_VERSION}
  平台:     ${PLATFORM}
  时间:     $(date '+%Y-%m-%d %H:%M:%S')
  npm 包:   ${NPM_PKG}
  二进制:   $(echo "$BIN_SIZE" | awk '{printf "%.1f MB", $1/1024/1024}')
================================================================================

LOGHEADER

info "已下载: ${NPM_PKG}@${PKG_VERSION}"
dim "二进制大小: $(echo "$BIN_SIZE" | awk '{printf "%.1f MB", $1/1024/1024}')"
dim "日志文件: ${_log_file}"

# ─── 检查 scripts/ 目录 ──────────────────────────

SCRIPTS_DIR="$SCRIPT_DIR/scripts"
for f in extract-natives.mjs post-process.mjs patch.mjs; do
  [ ! -f "$SCRIPTS_DIR/$f" ] && { warn "未找到 scripts/$f"; exit 1; }
done
info "工具脚本已就绪"

# ─── 提取 cli.js ──────────────────────────────────

CLI_EXTRACT_DIR="$WORK_DIR/extract"
mkdir -p "$CLI_EXTRACT_DIR"

dim "正在提取 cli.js ..."
node "$SCRIPTS_DIR/extract-natives.mjs" "$NATIVE_BIN" "$CLI_EXTRACT_DIR" --cli-js 2>&1 | while IFS= read -r line; do dim "  $line"; done
[ ! -f "$CLI_EXTRACT_DIR/cli.original.js" ] && { warn "cli.js 提取失败"; exit 1; }

cp "$SCRIPTS_DIR/post-process.mjs" "$CLI_EXTRACT_DIR/"
( cd "$CLI_EXTRACT_DIR" && node post-process.mjs 2>&1 | while IFS= read -r line; do dim "  $line"; done )
[ ! -f "$CLI_EXTRACT_DIR/cli.original.cjs" ] && { warn "后处理失败"; exit 1; }

CLI_SIZE=$(stat -f%z "$CLI_EXTRACT_DIR/cli.original.cjs" 2>/dev/null || stat -c%s "$CLI_EXTRACT_DIR/cli.original.cjs" 2>/dev/null || echo 0)
info "cli.original.cjs 提取完成 ($(echo "$CLI_SIZE" | awk '{printf "%.1f MB", $1/1024/1024}'))"

# ─── Patch 兼容性检查 ─────────────────────────────

cp "$SCRIPTS_DIR/patch.mjs" "$CLI_EXTRACT_DIR/"

header "═══ Patch 兼容性检查 (v${PKG_VERSION}) ═══"
node "$CLI_EXTRACT_DIR/patch.mjs" --verify 2>&1 | while IFS= read -r line; do _tee_out "$line"; done

# ─── 锚点检查 ─────────────────────────────────────

CJS_FILE="$CLI_EXTRACT_DIR/cli.original.cjs"

check_sentinel() {
  local name="$1" sentinel="$2"
  if grep -q "$sentinel" "$CJS_FILE" 2>/dev/null; then
    _tee_out "  [存在] ${name}"
  else
    _tee_out "  [缺失] ${name}"
  fi
}

header "═══ 已有 Patch 覆盖的锚点 ═══"

check_sentinel "CYBER_RISK_INSTRUCTION" "Assist with authorized security testing"
check_sentinel "URL 生成限制" "NEVER generate or guess URLs"
check_sentinel "操作审慎提示" "Executing actions with care"
check_sentinel "登录提示" "Not logged in"
check_sentinel "安全编码指令 (OWASP)" "OWASP top 10"
check_sentinel "Prompt injection 警告" "attempt at prompt injection"
check_sentinel "文件创建限制" "NEVER create files unless"
check_sentinel "权限拒绝行为约束" "do not re-attempt the exact same tool call"

header "═══ 未覆盖的 Prompt 指令层锚点 ═══"

check_sentinel "恶意代码提醒 (旧)" "considered malware"
check_sentinel "恶意代码提醒 (新)" "MUST refuse to improve"
check_sentinel "文件创建限制 (旧措辞)" "Do not create files unless"

header "═══ 客户端硬规则层锚点 ═══"

check_sentinel "Bash 危险模式 (process substitution)" "process substitution"
check_sentinel "Zsh 危险命令 (zmodload)" "zmodload"
check_sentinel "YOLO 分类器 (xml_2stage)" "xml_2stage"
check_sentinel "YOLO 分类器 (blocking for safety)" "blocking for safety"
check_sentinel "Unicode 清洗 (NFKC)" 'normalize("NFKC")'
check_sentinel "秘密扫描" "cannot be written to team memory"
check_sentinel "破坏性命令警告" "may discard uncommitted changes"
check_sentinel "敏感路径保护 (classifierApprovable)" "classifierApprovable"

# ─── 汇总 ─────────────────────────────────────────

header "═══ 汇总 ═══"

TOTAL=0; PRESENT=0
for sentinel in \
  "Assist with authorized security testing" \
  "NEVER generate or guess URLs" \
  "Executing actions with care" \
  "Not logged in" \
  "OWASP top 10" \
  "attempt at prompt injection" \
  "NEVER create files unless" \
  "do not re-attempt the exact same tool call" \
  "considered malware" \
  "MUST refuse to improve" \
  "Do not create files unless" \
  "process substitution" \
  "zmodload" \
  "xml_2stage" \
  "blocking for safety" \
  "cannot be written to team memory" \
  "may discard uncommitted changes" \
  "classifierApprovable"; do
  TOTAL=$((TOTAL + 1))
  grep -q "$sentinel" "$CJS_FILE" 2>/dev/null && PRESENT=$((PRESENT + 1))
done

_tee_out "  Claude Code:  v${PKG_VERSION}"
_tee_out "  平台:         ${PLATFORM}"
_tee_out "  二进制:       $(echo "$BIN_SIZE" | awk '{printf "%.1f MB", $1/1024/1024}')"
_tee_out "  cli.js:       $(echo "$CLI_SIZE" | awk '{printf "%.1f MB", $1/1024/1024}')"
_tee_out "  锚点存在:     ${PRESENT}/${TOTAL}"
_tee_out "  日志已保存:   ${_log_file}"

# ─── 保存 cli.original.cjs ────────────────────────

CJS_SAVE="${LOG_BASE_DIR}/v${PKG_VERSION}_${TIMESTAMP}_cli.original.cjs"
cp "$CJS_FILE" "$CJS_SAVE"
_tee_out "  cli.js 已保存: ${CJS_SAVE}"
_tee_out ""

echo ""
echo -e "${BOLD}  日志已保存到: ${_log_file}${NC}"
echo -e "${BOLD}  cli.js 已保存到: ${CJS_SAVE}${NC}"
echo ""
