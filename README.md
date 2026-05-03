# ShadowCode

> Claude Code 安全逆向分析与定制工具集
>
> [English](README.en.md) · 中文

基于 Claude Code v2.1.126 的客户端安全机制系统性逆向分析与 patch 工具。

---

## 这是什么

[Claude Code](https://claude.com/code) 是 Anthropic 的命令行 AI 编码助手。从 v2.1.113 起，它以 Bun 单文件可执行体的形式分发，包含全部 JS 源码 + Bun 运行时 + 原生模块。

**ShadowCode** 是一套用于安全研究和定制的工具集：

- 从官方二进制中提取完整的 cli.js（约 13MB，minified）
- 通过正则匹配字符串锚点应用 patch（跨版本兼容）
- 提供 patch 兼容性验证工具（不安装、不修改）
- 提供颜色主题选择器（浏览器交互式预览）
- 提供 6 篇详细的安全机制分析文档

## 功能特性

### 安全限制移除（Prompt 指令层）

通过 patch 移除 system prompt 中的部分行为约束指令：

| Patch | 移除内容 |
|-------|---------|
| `CYBER_RISK_INSTRUCTION` | 网络安全测试拒绝提示 |
| URL 限制 | "禁止生成或猜测 URL" |
| 操作审慎提示 | 破坏性操作前的强制提示 |
| 登录提示 | 启动横幅 |
| OWASP 安全编码 | 自动修复"不安全代码"的指令 |
| Prompt injection 警告 | 工具结果中的注入警觉 |
| 文件创建限制 | "尽量编辑不要新建文件"的指令 |
| 权限拒绝行为约束 | 被拒绝后不重试同操作的指令 |

### 功能解锁

| Patch | 效果 |
|-------|------|
| `USER_TYPE → ant` | 解锁内部功能 |
| Agent Teams | 启用 Agent Teams 功能 |
| Computer Use | 跳过订阅检查 |
| Ultraplan / Ultrareview | 启用高级功能 |
| Auto-mode for 3rd-party | 第三方 API 启用 Auto 模式 |

### 品牌定制

- 琥珀终端主题（替代原版橙色）
- Banner 品牌名替换（"Claude Code" → "Shadow Code"）
- 颜色选择器 HTML 工具支持自定义主题色

### 内容审核研究

完整文档分析了 Claude Code 的多层安全防护：

- **客户端硬规则**（Bash 危险检测、SSRF 防护、Unicode 清洗、秘密扫描等）
- **YOLO 分类器**（用 Claude 模型审查工具调用的 LLM-as-judge 机制）
- **服务端审核**（不可触及）
- **模型权重对齐**（不可触及）

---

## 前置依赖

在运行安装脚本之前，请准备以下环境：

| 工具 | 为什么需要 | 安装方式 |
|------|-----------|---------|
| **Claude Code**（原生二进制） | ShadowCode 在官方二进制基础上打 patch | macOS/Linux: `curl -fsSL https://claude.ai/install.sh \| bash`<br>Windows: `irm https://claude.ai/install.ps1 \| iex` |
| **ripgrep** | Claude Code 的 Grep 工具需要它 | macOS: `brew install ripgrep`<br>Linux: `apt install ripgrep`<br>Windows: `winget install BurntSushi.ripgrep.MSVC` |
| **Node.js >= 18** | Patcher 运行时 | [nodejs.org](https://nodejs.org) |
| **Bun**（canary 版本） | 加载 patch 后的 cli.original.cjs。脚本会自动安装 stable 版，但通常需手动升级 canary | macOS/Linux: `bun upgrade --canary`<br>Windows: `powershell -c "iex & {$(irm https://bun.sh/install.ps1)} -Version canary"` |

> **关于 Bun canary**：Anthropic 用 Bun canary 编译 cli.js。stable 版会报错 `Expected CommonJS module to have a function wrapper`。校验失败时按上表升级到 canary。

---

## 安装

### macOS / Linux

```bash
git clone https://github.com/zhizhuodemao/shadowcode.git ~/shadowcode
cd ~/shadowcode
bash install-custom.sh
```

### Windows

```powershell
git clone https://github.com/zhizhuodemao/shadowcode.git $env:USERPROFILE\shadowcode
cd $env:USERPROFILE\shadowcode
powershell -ExecutionPolicy Bypass -File install-custom.ps1
```

### 验证 Patch（不安装、不修改）

```bash
bash verify-patches.sh                      # macOS / Linux
powershell -File verify-patches.ps1         # Windows
```

输出会显示哪些 patch 生效、哪些锚点存在/缺失，并保存日志和提取的 cli.original.cjs 到 `verify-logs/` 目录。

### 卸载

```bash
bash install-custom.sh --uninstall          # macOS / Linux
powershell -File install-custom.ps1 -Uninstall   # Windows
```

卸载只移除 ShadowCode（`~/.shadowcode/`），不影响官方 Claude Code 配置（`~/.claude/`）。

---

## 使用

安装完成后，原 `claude` 命令已被替换：

```bash
claude              # 启动 patch 后的 Claude Code（琥珀色 banner）
claude.orig         # 启动原版未 patch 的 Claude Code
shadowcode          # 显式调用 ShadowCode（同 claude）
```

配置仍然沿用 Claude Code 官方的 `~/.claude/settings.json`，无需额外设置。

---

## 项目结构

```
claude-patch/
  ├── install-custom.sh         macOS / Linux 安装脚本
  ├── install-custom.ps1        Windows 安装脚本
  ├── verify-patches.sh         macOS / Linux 验证工具
  ├── verify-patches.ps1        Windows 验证工具
  ├── color-picker.html         主题色选择器（浏览器打开）
  ├── extract-scripts.py        从 install-custom.sh 提取脚本的工具
  ├── README.md                 本文档
  ├── README.en.md              英文版
  ├── scripts/                  跨平台共用的核心脚本
  │   ├── extract-natives.mjs   从 Bun 二进制提取 cli.js + 原生模块
  │   ├── post-process.mjs      路径重写、IIFE 包装
  │   ├── patch.mjs             核心 Patcher（含所有 patch 定义）
  │   ├── repatch.mjs           升级时重新打 patch
  │   └── cli.cjs               运行时 wrapper
  ├── config/
  │   └── features.json         默认 feature flag 配置
  ├── output/                   patch 后的 cli.original.cjs（自动生成）
  └── docs/
       ├── 06-设备指纹收集分析.md
       ├── 07-LLM-API请求内容分析.md
       ├── 08-客户端安全防护体系分析.md
       ├── 09-ShadowCode安装脚本逆向分析.md
       ├── 10-v2.1.126-Patch适配报告.md
       └── 11-claude-trace适配ShadowCode修复.md
```

---

## 版本支持

脚本默认锁定 **v2.1.126**，所有 patch 已在该版本上验证通过。

```bash
# 默认（v2.1.126）
bash install-custom.sh

# 指定其他版本
bash install-custom.sh --version 2.1.130
bash verify-patches.sh --version 2.1.130
```

新版本可能改变 minified 代码结构，导致部分 patch 失效。`verify-patches.sh` 会显示每条 patch 在目标版本上的匹配状态。

---

## 文档

详细的逆向分析文档在 `docs/` 目录：

- **[06-设备指纹收集分析](docs/06-设备指纹收集分析.md)** — Claude Code 收集的 30+ 设备指纹字段及发送目标
- **[07-LLM-API请求内容分析](docs/07-LLM-API请求内容分析.md)** — 每次发给模型的完整请求结构
- **[08-客户端安全防护体系分析](docs/08-客户端安全防护体系分析.md)** — 8 层纵深防御体系详解
- **[09-ShadowCode安装脚本逆向分析](docs/09-ShadowCode安装脚本逆向分析.md)** — 安装管线和 patch 机制
- **[10-v2.1.126-Patch适配报告](docs/10-v2.1.126-Patch适配报告.md)** — 当前版本兼容性详细记录
- **[11-claude-trace适配ShadowCode修复](docs/11-claude-trace适配ShadowCode修复.md)** — 让 claude-trace 支持 Bun 二进制

---

## 技术原理

```
官方 Bun 单文件二进制（~90 MB）
       │
       │  extract-natives.mjs 解析 Mach-O / ELF / PE 格式
       │
       ├─ cli.js（13 MB JS 文本，minified）
       └─ vendor/*.node（原生模块）
       │
       │  post-process.mjs 重写路径
       │
   cli.original.cjs（可被外置 Bun 加载）
       │
       │  patch.mjs 应用正则替换（30+ 条 patch）
       │
   patched cli.original.cjs
       │
       │  cli.cjs wrapper 注入配置
       │
       ▼
       bun cli.cjs → Claude Code 启动
```

**核心 insight**：Bun 单文件可执行体把 JavaScript 源码以**文本**形式嵌入二进制（不是机器码），所以可以提取、修改、再用 Bun 运行时加载。

---

## 免责声明

本项目仅用于**安全研究和教育目的**。使用者需遵守：

- 当地法律法规
- [Anthropic 服务条款](https://www.anthropic.com/legal/consumer-terms)
- [Claude Code 使用条款](https://www.anthropic.com/legal/aup)

本项目作者不对任何使用本工具产生的后果负责。

---

## 许可

MIT License
