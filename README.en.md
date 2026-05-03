# ShadowCode

> Security research and customization toolkit for Claude Code
>
> English · [中文](README.md)

Systematic reverse engineering and patch toolkit for the client-side security mechanisms of Claude Code v2.1.126.

---

## What is this

[Claude Code](https://claude.com/code) is Anthropic's command-line AI coding assistant. Since v2.1.113, it ships as a Bun standalone executable containing the full JS source + Bun runtime + native modules.

**ShadowCode** is a toolkit for security research and customization:

- Extracts the full cli.js (~13MB minified) from the official binary
- Applies patches via regex matching on string anchors (cross-version compatible)
- Provides patch compatibility verification (no install, no modification)
- Provides a color theme picker (interactive browser preview)
- Includes 6 detailed security mechanism analysis documents

## Features

### Safety Restriction Removal (Prompt Layer)

Patches that remove behavioral instructions from system prompts:

| Patch | What it removes |
|-------|----------------|
| `CYBER_RISK_INSTRUCTION` | Cyber security testing refusal |
| URL restriction | "Never generate or guess URLs" |
| Cautious actions | Forced confirmation before destructive ops |
| Login notice | Startup banner |
| OWASP coding guard | Auto-fix "insecure code" instruction |
| Prompt injection warning | Tool result vigilance |
| File creation restriction | "Prefer editing over creating" |
| Tool denial persistence | "Don't retry the same denied tool call" |

### Feature Unlocking

| Patch | Effect |
|-------|--------|
| `USER_TYPE → ant` | Unlock internal features |
| Agent Teams | Enable Agent Teams |
| Computer Use | Bypass subscription check |
| Ultraplan / Ultrareview | Enable advanced features |
| Auto-mode for 3rd-party | Auto-mode on 3rd-party APIs |

### Brand Customization

- Amber terminal theme (replaces original orange)
- Banner brand replacement ("Claude Code" → "Shadow Code")
- HTML color picker for custom theme colors

### Content Moderation Research

Documentation analyzes Claude Code's defense layers:

- **Client hard rules** (Bash danger detection, SSRF guard, Unicode sanitization, secret scanning)
- **YOLO classifier** (LLM-as-judge using Claude to review tool calls)
- **Server-side moderation** (out of reach)
- **Model weight alignment** (out of reach)

---

## Prerequisites

Before running the installer, prepare the following:

| Tool | Why | Install |
|------|-----|---------|
| **Claude Code** (native binary) | ShadowCode patches the official binary | macOS/Linux: `curl -fsSL https://claude.ai/install.sh \| bash`<br>Windows: `irm https://claude.ai/install.ps1 \| iex` |
| **ripgrep** | Required by Claude Code's Grep tool | macOS: `brew install ripgrep`<br>Linux: `apt install ripgrep`<br>Windows: `winget install BurntSushi.ripgrep.MSVC` |
| **Node.js >= 18** | Patcher runtime | [nodejs.org](https://nodejs.org) |
| **Bun** (canary) | Loads patched cli.original.cjs. Script auto-installs stable, but you'll likely need canary | macOS/Linux: `bun upgrade --canary`<br>Windows: `powershell -c "iex & {$(irm https://bun.sh/install.ps1)} -Version canary"` |

> **About Bun canary**: Anthropic builds cli.js with Bun canary. Stable Bun fails with `Expected CommonJS module to have a function wrapper`. Upgrade to canary if the sanity check fails.

---

## Installation

### macOS / Linux

```bash
git clone <repo-url> ~/Documents/claude-patch
cd ~/Documents/claude-patch
bash install-custom.sh
```

### Windows

```powershell
git clone <repo-url> $env:USERPROFILE\Documents\claude-patch
cd $env:USERPROFILE\Documents\claude-patch
powershell -ExecutionPolicy Bypass -File install-custom.ps1
```

### Verify Patches (no install, no modification)

```bash
bash verify-patches.sh                      # macOS / Linux
powershell -File verify-patches.ps1         # Windows
```

Output shows which patches match, which anchors exist/missing, and saves logs + extracted cli.original.cjs to `verify-logs/`.

### Uninstall

```bash
bash install-custom.sh --uninstall          # macOS / Linux
powershell -File install-custom.ps1 -Uninstall   # Windows
```

Uninstall only removes ShadowCode (`~/.shadowcode/`); the official Claude Code config (`~/.claude/`) is untouched.

---

## Usage

After installation, the `claude` command is replaced:

```bash
claude              # Start patched Claude Code (amber banner)
claude.orig         # Start original unpatched Claude Code
shadowcode          # Explicit ShadowCode invocation (same as claude)
```

### Configuration

```
~/.shadowcode/provider.json    API config (baseURL, key, model, timeout)
~/.shadowcode/features.json    Feature flag overrides
```

`provider.json` schema:

```json
{
  "apiKey": "",
  "baseURL": "https://api.anthropic.com",
  "model": "",
  "smallModel": "",
  "timeoutMs": 3000000
}
```

---

## Project Layout

```
claude-patch/
  ├── install-custom.sh         macOS / Linux installer
  ├── install-custom.ps1        Windows installer
  ├── verify-patches.sh         macOS / Linux verifier
  ├── verify-patches.ps1        Windows verifier
  ├── color-picker.html         Theme color picker (open in browser)
  ├── extract-scripts.py        Tool to extract scripts from install-custom.sh
  ├── README.md                 Chinese version
  ├── README.en.md              This document
  ├── scripts/                  Cross-platform shared scripts
  │   ├── extract-natives.mjs   Extract cli.js + native modules from Bun binary
  │   ├── post-process.mjs      Path rewriting, IIFE wrapping
  │   ├── patch.mjs             Core patcher (all patch definitions)
  │   ├── repatch.mjs           Re-patch on upgrade
  │   └── cli.cjs               Runtime wrapper
  ├── config/
  │   └── features.json         Default feature flags
  ├── output/                   Patched cli.original.cjs (auto-generated)
  └── docs/
       ├── 06-设备指纹收集分析.md            Device fingerprinting analysis
       ├── 07-LLM-API请求内容分析.md         LLM API request content
       ├── 08-客户端安全防护体系分析.md      Client-side defense system
       ├── 09-ShadowCode安装脚本逆向分析.md  Installation pipeline reverse
       ├── 10-v2.1.126-Patch适配报告.md      v2.1.126 compatibility report
       └── 11-claude-trace适配ShadowCode修复.md  claude-trace integration
```

---

## Version Support

Scripts pin to **v2.1.126** by default, where all patches have been verified.

```bash
# Default (v2.1.126)
bash install-custom.sh

# Other versions
bash install-custom.sh --version 2.1.130
bash verify-patches.sh --version 2.1.130
```

New versions may change minified code structure, breaking some patches. `verify-patches.sh` reports per-patch match status on the target version.

---

## Documentation

Detailed reverse engineering analysis in `docs/` (Chinese only for now):

- **06-设备指纹收集分析** — 30+ device fingerprint fields and destinations
- **07-LLM-API请求内容分析** — Full request structure sent to the model
- **08-客户端安全防护体系分析** — 8-layer defense in depth
- **09-ShadowCode安装脚本逆向分析** — Installation pipeline & patch mechanism
- **10-v2.1.126-Patch适配报告** — Current version compatibility record
- **11-claude-trace适配ShadowCode修复** — claude-trace adaptation for Bun binary

---

## How It Works

```
Official Bun standalone binary (~90 MB)
       │
       │  extract-natives.mjs parses Mach-O / ELF / PE
       │
       ├─ cli.js (13 MB minified JS text)
       └─ vendor/*.node (native modules)
       │
       │  post-process.mjs rewrites paths
       │
   cli.original.cjs (loadable by external Bun)
       │
       │  patch.mjs applies regex replacements (30+ patches)
       │
   patched cli.original.cjs
       │
       │  cli.cjs wrapper injects config
       │
       ▼
       bun cli.cjs → Claude Code launches
```

**Key insight**: Bun standalone executables embed JavaScript source as **text** (not machine code), making it possible to extract, modify, and reload via external Bun runtime.

---

## Disclaimer

This project is for **security research and educational purposes only**. Users must comply with:

- Local laws and regulations
- [Anthropic Terms of Service](https://www.anthropic.com/legal/consumer-terms)
- [Claude Code Acceptable Use Policy](https://www.anthropic.com/legal/aup)

The author assumes no responsibility for any consequences of using this tool.

---

## License

MIT License
