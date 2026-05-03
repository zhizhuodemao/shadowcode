#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────
#  Custom Installer (macOS / Linux)
#
#  用法:
#    bash install-custom.sh
#    bash install-custom.sh --version 2.1.126
#    bash install-custom.sh --uninstall
# ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHADOWCODE_DIR="$HOME/.shadowcode"
BIN_DIR="$HOME/.local/bin"
VERSION="${SHADOWCODE_VERSION:-2.1.126}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --version) VERSION="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) shift ;;
  esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${RED}✗${NC} $1"; }
dim()   { echo -e "  ${DIM}$1${NC}"; }

echo ""
echo -e "${BOLD}  Custom Installer${NC}"
echo ""

# ─── Uninstall ────────────────────────────────────

if [ "$UNINSTALL" = "1" ]; then
  CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
  for DIR in "${CLAUDE_BIN:+$(dirname "$CLAUDE_BIN")}" "$BIN_DIR"; do
    [ -z "$DIR" ] && continue
    [ -e "$DIR/claude.orig" ] && mv "$DIR/claude.orig" "$DIR/claude" && info "Original claude restored ($DIR/claude)"
    [ -f "$DIR/shadowcode" ] && grep -q "shadowcode" "$DIR/shadowcode" 2>/dev/null && rm -f "$DIR/shadowcode" && info "Removed alias ($DIR/shadowcode)"
  done
  rm -rf "$SHADOWCODE_DIR/vendor" "$SHADOWCODE_DIR/cli.original.js" "$SHADOWCODE_DIR/cli.original.js.bak" "$SHADOWCODE_DIR/cli.original.cjs" "$SHADOWCODE_DIR/cli.original.cjs.bak" "$SHADOWCODE_DIR/cli.cjs" "$SHADOWCODE_DIR/patch.mjs" "$SHADOWCODE_DIR/extract-natives.mjs" "$SHADOWCODE_DIR/post-process.mjs" "$SHADOWCODE_DIR/repatch.mjs" "$SHADOWCODE_DIR/.source-version"
  hash -r 2>/dev/null
  info "Uninstalled. Restart your terminal or run: hash -r"
  exit 0
fi

# ─── Prerequisites ────────────────────────────────

command -v node &>/dev/null || { warn "Node.js >= 18 required"; exit 1; }
NODE_VERSION=$(node -e "console.log(process.versions.node.split('.')[0])")
[ "$NODE_VERSION" -lt 18 ] && { warn "Node.js >= 18 required (found v$NODE_VERSION)"; exit 1; }
command -v npm &>/dev/null || { warn "npm required"; exit 1; }

# Bun
BUN_BIN=""
if command -v bun &>/dev/null; then BUN_BIN=$(command -v bun)
elif [ -x "$HOME/.bun/bin/bun" ]; then BUN_BIN="$HOME/.bun/bin/bun"
else
  dim "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || true
  BUN_BIN="$HOME/.bun/bin/bun"
  [ ! -x "$BUN_BIN" ] && { warn "Bun installation failed"; exit 1; }
fi
info "Bun: $($BUN_BIN --version)"

# ripgrep
command -v rg &>/dev/null || { warn "ripgrep (rg) required. Install: brew install ripgrep"; exit 1; }
info "ripgrep: $(rg --version | head -1)"

# ─── Download ─────────────────────────────────────

mkdir -p "$SHADOWCODE_DIR" "$BIN_DIR"
NATIVE_BIN_TMPDIR=$(mktemp -d)

case "$(uname -s)" in Darwin) os="darwin";; Linux) os="linux";; *) warn "Unsupported OS"; exit 1;; esac
case "$(uname -m)" in arm64|aarch64) arch="arm64";; x86_64|amd64) arch="x64";; *) warn "Unsupported arch"; exit 1;; esac
[ "$os" = "linux" ] && ldd /bin/ls 2>/dev/null | grep -q musl && PLATFORM="${os}-${arch}-musl" || PLATFORM="${os}-${arch}"

NPM_PKG="@anthropic-ai/claude-code-${PLATFORM}"
dim "Fetching $NPM_PKG@$VERSION ..."

( cd "$NATIVE_BIN_TMPDIR" && npm pack "$NPM_PKG@$VERSION" --silent >/dev/null 2>&1 ) || { warn "npm pack failed"; exit 1; }
TARBALL=$(ls "$NATIVE_BIN_TMPDIR"/*.tgz 2>/dev/null | head -1)
[ -z "$TARBALL" ] && { warn "No .tgz found"; exit 1; }
( cd "$NATIVE_BIN_TMPDIR" && tar xzf "$TARBALL" )

NATIVE_BIN="$NATIVE_BIN_TMPDIR/package/claude"
[ ! -f "$NATIVE_BIN" ] && { warn "Binary not found"; exit 1; }

PKG_VERSION=$(node -e "console.log(require('$NATIVE_BIN_TMPDIR/package/package.json').version)" 2>/dev/null || echo "unknown")
info "Downloaded: $NPM_PKG@$PKG_VERSION"

# ─── Copy scripts & extract ──────────────────────

cp "$SCRIPT_DIR/scripts/extract-natives.mjs" "$SHADOWCODE_DIR/"
cp "$SCRIPT_DIR/scripts/post-process.mjs" "$SHADOWCODE_DIR/"
cp "$SCRIPT_DIR/scripts/patch.mjs" "$SHADOWCODE_DIR/"
cp "$SCRIPT_DIR/scripts/repatch.mjs" "$SHADOWCODE_DIR/"
cp "$SCRIPT_DIR/scripts/cli.cjs" "$SHADOWCODE_DIR/"
chmod +x "$SHADOWCODE_DIR/cli.cjs" "$SHADOWCODE_DIR/repatch.mjs"

VENDOR_DIR="$SHADOWCODE_DIR/vendor"
rm -rf "$VENDOR_DIR" 2>/dev/null; mkdir -p "$VENDOR_DIR"

dim "Extracting cli.js ..."
node "$SHADOWCODE_DIR/extract-natives.mjs" "$NATIVE_BIN" "$SHADOWCODE_DIR" --cli-js 2>&1 | while IFS= read -r line; do dim "  $line"; done
[ -f "$SHADOWCODE_DIR/cli.original.js" ] || { warn "cli.js extraction failed"; exit 1; }

dim "Extracting native modules ..."
node "$SHADOWCODE_DIR/extract-natives.mjs" "$NATIVE_BIN" "$VENDOR_DIR" 2>&1 | while IFS= read -r line; do dim "  $line"; done

dim "Post-processing ..."
node "$SHADOWCODE_DIR/post-process.mjs" 2>&1 | while IFS= read -r line; do dim "  $line"; done
[ -f "$SHADOWCODE_DIR/cli.original.cjs" ] || { warn "Post-process failed"; exit 1; }
info "cli.original.cjs ready ($PKG_VERSION)"

echo "$PKG_VERSION" > "$SHADOWCODE_DIR/.source-version"
rm -rf "$NATIVE_BIN_TMPDIR"

# ─── Patch ────────────────────────────────────────

dim "Applying patches ..."
node "$SHADOWCODE_DIR/patch.mjs" 2>&1 | while IFS= read -r line; do echo "  $line"; done

# ─── 保存 patch 后的 cli.original.cjs 到项目目录 ──

mkdir -p "$SCRIPT_DIR/output"
cp "$SHADOWCODE_DIR/cli.original.cjs" "$SCRIPT_DIR/output/cli.original.cjs"
info "patch 后的 cli.original.cjs 已保存到 $SCRIPT_DIR/output/"

# ─── Default configs ──────────────────────────────

[ ! -f "$SHADOWCODE_DIR/features.json" ] && cp "$SCRIPT_DIR/config/features.json" "$SHADOWCODE_DIR/" && info "Default features.json created"

# ─── Sanity check ─────────────────────────────────

dim "Verifying Bun can load cli.original.cjs ..."
sanity_out=$("$BUN_BIN" "$SHADOWCODE_DIR/cli.cjs" --version 2>&1 || true)
if echo "$sanity_out" | grep -q "Expected CommonJS module"; then
  warn "Bun $($BUN_BIN --version) cannot load cli.original.cjs. Run: bun upgrade --canary"
  exit 1
fi
info "Bun loads cli.original.cjs"

# ─── Install launcher ────────────────────────────

CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
[ -z "$CLAUDE_BIN" ] && CLAUDE_BIN="$BIN_DIR/claude" && dim "No existing claude found, installing to $BIN_DIR"
CLAUDE_DIR=$(dirname "$CLAUDE_BIN")

# Backup
if [ ! -e "$CLAUDE_BIN.orig" ]; then
  if [ -L "$CLAUDE_BIN" ]; then
    ln -sf "$(readlink "$CLAUDE_BIN")" "$CLAUDE_BIN.orig"
    info "Original claude backed up → claude.orig"
  elif [ -f "$CLAUDE_BIN" ]; then
    cp "$CLAUDE_BIN" "$CLAUDE_BIN.orig"
    info "Original claude backed up → claude.orig"
  fi
fi

write_launcher() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  rm -f "$target"
  cat > "$target" << LAUNCHER
#!/bin/bash
# shadowcode launcher
SHADOWCODE_CLI="$SHADOWCODE_DIR/cli.cjs"
BUN_BIN="$BUN_BIN"
if [ ! -f "\$SHADOWCODE_CLI" ]; then echo "shadowcode: cli.cjs not found" >&2; exit 127; fi
if [ ! -x "\$BUN_BIN" ]; then command -v bun >/dev/null 2>&1 && BUN_BIN="\$(command -v bun)"; fi
if [ ! -x "\$BUN_BIN" ]; then echo "shadowcode: bun not found" >&2; exit 127; fi
exec "\$BUN_BIN" "\$SHADOWCODE_CLI" "\$@"
LAUNCHER
  chmod +x "$target"
}

write_launcher "$CLAUDE_BIN"
info "Command 'claude' → patched ($CLAUDE_BIN)"
[ "$CLAUDE_DIR" != "$BIN_DIR" ] && write_launcher "$BIN_DIR/claude" && dim "Also installed to $BIN_DIR/claude"
write_launcher "$BIN_DIR/shadowcode"
info "Command 'shadowcode' → patched ($BIN_DIR/shadowcode)"

hash -r 2>/dev/null

echo ""
echo -e "  ${BOLD}${GREEN}Installed!${NC}"
echo ""
dim "  claude       — Start patched Claude Code"
dim "  claude.orig  — Run original unpatched Claude Code"
echo ""
dim "  Config: ~/.shadowcode/provider.json"
dim "  Flags:  ~/.shadowcode/features.json"
echo ""
