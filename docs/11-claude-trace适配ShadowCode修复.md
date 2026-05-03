# claude-trace 适配 ShadowCode 修复记录

> 修复 claude-trace 无法识别 shadowcode launcher 的问题

## 问题描述

运行 `claude-trace --include-all-requests` 报错：

```
Using Claude binary: $BUN_BIN
Uncaught exception: Error: Cannot find module '/Users/chen/$BUN_BIN'
```

或升级后报错：

```
Uncaught exception: /Users/chen/.bun/bin/bun:1
SyntaxError: Invalid or unexpected token
```

## 根因分析

### claude-trace 的工作原理

```
claude-trace 启动流程:
  ① which claude → 找到 launcher 脚本
  ② 读取 launcher 内容，正则 exec\s+"([^"]+)" 提取路径
  ③ resolveToJsFile() 检查是否是 JS 文件
  ④ spawn("node", ["--require", interceptor, claudePath]) 启动
```

### 原版 claude launcher（兼容）

```bash
exec "/Users/chen/.local/share/claude/versions/xxx/claude"
     ↑ 绝对路径，正则直接匹配
```

### shadowcode launcher（不兼容）

```bash
BUN_BIN="/Users/chen/.bun/bin/bun"
SHADOWCODE_CLI="/Users/chen/.shadowcode/cli.cjs"
exec "$BUN_BIN" "$SHADOWCODE_CLI" "$@"
     ↑ 变量引用，正则匹配到字面量 "$BUN_BIN"
```

### 两个问题

1. **路径解析**：正则拿到 `$BUN_BIN` 字面量，不是实际路径
2. **运行时不兼容**：即使拿到正确路径，claude-trace 用 `node` 启动，而 `cli.cjs` 需要 `bun` 运行时

## 修复方案

### 修改文件

```
/Users/chen/.nvm/versions/node/v24.13.0/lib/node_modules/@mariozechner/claude-trace/dist/cli.js
```

### 修改点 1：bash wrapper 路径解析（约第 195-207 行）

**原代码**：

```javascript
// Check if the path is a bash wrapper
if (fs.existsSync(claudePath)) {
    const content = fs.readFileSync(claudePath, "utf-8");
    if (content.startsWith("#!/bin/bash")) {
        // Parse bash wrapper to find actual executable
        const execMatch = content.match(/exec\s+"([^"]+)"/);
        if (execMatch && execMatch[1]) {
            const actualPath = execMatch[1];
            // Resolve any symlinks to get the final JS file
            return resolveToJsFile(actualPath);
        }
    }
}
```

**修改后**：

```javascript
// Check if the path is a bash wrapper
if (fs.existsSync(claudePath)) {
    const content = fs.readFileSync(claudePath, "utf-8");
    if (content.startsWith("#!/bin/bash")) {
        // Parse bash wrapper to find actual executable
        const execMatch = content.match(/exec\s+"([^"]+)"/);
        if (execMatch && execMatch[1]) {
            let actualPath = execMatch[1];
            // Resolve shell variables (e.g. $BUN_BIN from shadowcode launcher)
            if (actualPath.startsWith("$")) {
                const varName = actualPath.replace(/^\$\{?/, "").replace(/\}?$/, "");
                const varMatch = content.match(new RegExp(varName + '="([^"]+)"'));
                if (varMatch && varMatch[1]) actualPath = varMatch[1];
            }
            // If first arg is a runtime binary (bun/node), extract second arg as the JS file
            if (/\/(bun|node)(\.exe)?$/.test(actualPath)) {
                const allQuoted = content.match(/exec\s+((?:"[^"]+"\s*)+)/);
                if (allQuoted) {
                    const parts = allQuoted[1].match(/"([^"]+)"/g);
                    if (parts && parts.length >= 2) {
                        let secondArg = parts[1].replace(/^"|"$/g, "");
                        if (secondArg.startsWith("$")) {
                            const vn = secondArg.replace(/^\$\{?/, "").replace(/\}?$/, "");
                            const vm = content.match(new RegExp(vn + '="([^"]+)"'));
                            if (vm && vm[1]) secondArg = vm[1];
                        }
                        if (fs.existsSync(secondArg)) return resolveToJsFile(secondArg);
                    }
                }
            }
            // Resolve any symlinks to get the final JS file
            return resolveToJsFile(actualPath);
        }
    }
}
```

**逻辑说明**：

```
exec "$BUN_BIN" "$SHADOWCODE_CLI" "$@"
       │              │
       ↓              ↓
  ① 正则匹配到 "$BUN_BIN"
  ② 检测到 $ 开头，从脚本中找 BUN_BIN="..." 赋值
  ③ 解析为 /Users/chen/.bun/bin/bun
  ④ 检测到路径以 /bun 结尾 → 这是运行时，不是 JS 文件
  ⑤ 提取 exec 行第二个参数 "$SHADOWCODE_CLI"
  ⑥ 同样解析变量 → /Users/chen/.shadowcode/cli.cjs
  ⑦ 返回 cli.cjs 路径
```

### 修改点 2：运行时自动切换（约第 256-257 行）

**原代码**：

```javascript
// Launch node with interceptor and absolute path to claude, plus any additional arguments
const spawnArgs = ["--require", loaderPath, claudePath, ...claudeArgs];
const child = (0, child_process_1.spawn)("node", spawnArgs, {
```

**修改后**：

```javascript
// Launch with interceptor — use bun for .cjs files (shadowcode), node otherwise
const useBun = claudePath.endsWith(".cjs");
const runtime = useBun ? (process.env.BUN_BIN || require("child_process").execSync("which bun", { encoding: "utf-8" }).trim()) : "node";
const spawnArgs = useBun
    ? ["--preload", loaderPath, claudePath, ...claudeArgs]
    : ["--require", loaderPath, claudePath, ...claudeArgs];
const child = (0, child_process_1.spawn)(runtime, spawnArgs, {
```

**逻辑说明**：

```
claudePath 以 .cjs 结尾？
  ├─ 是 → bun --preload interceptor.js cli.cjs
  └─ 否 → node --require interceptor.js cli.js（原行为）
```

注意：bun 用 `--preload` 而不是 `--require` 来注入模块。

## install.sh 的改动

install.sh 不需要为 claude-trace 做额外改动。launcher 保持变量形式：

```bash
exec "$BUN_BIN" "$SHADOWCODE_CLI" "$@"
```

claude-trace 侧的修复已能正确解析此格式。

## 使用方式

```bash
# 唯一可用的方式 — 自动找到 shadowcode launcher
claude-trace --include-all-requests
```

## 已知限制

| 命令 | 状态 | 原因 |
|------|------|------|
| `claude-trace --include-all-requests` | ✅ 可用 | 自动找到 shadowcode launcher → 解析变量 → bun + cli.cjs |
| `claude-trace --claude-path cli.cjs` | ✅ 可用 | 检测 .cjs → bun --preload |
| `claude-trace --claude-path claude.orig` | ❌ 不可用 | 原版是 Bun 单文件二进制，无法注入 interceptor |
| `claude-trace --claude-path cli.original.cjs.bak` | ❌ 不可用 | 未 patch 的 cjs 也需要 bun 运行时环境完整配置 |

### 为什么 claude.orig 不能用

claude-trace 的工作原理是通过 `--require`/`--preload` 注入 interceptor 来 hook `fetch()` 调用。这要求目标是一个 **JS 文件**，由 node 或 bun 运行时加载。

`claude.orig` 指向的是 Bun 单文件可执行体（Mach-O/ELF 二进制），它自带 Bun 运行时 + 嵌入的 JS，是一个独立的可执行文件，不接受外部 `--preload` 注入。

### 如果需要抓原版 claude 的请求

使用其他方式：

```bash
# 方法 1: claude 自带的 debug 模式
claude.orig --debug

# 方法 2: 通过代理抓包（mitmproxy）
HTTPS_PROXY=http://127.0.0.1:8080 claude.orig
```

## 注意事项

- claude-trace 通过 npm 更新后，此修改会被覆盖，需要重新应用
- 修改的是编译后的 `dist/cli.js`，不是 TypeScript 源码
- bun 的 `--preload` 与 node 的 `--require` 行为类似但不完全相同，interceptor 的 fetch hook 兼容性待验证
