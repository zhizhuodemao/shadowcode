# LLM API 请求内容分析

> 基于 Claude Code 反编译源码分析

## 概述

本文档详细拆解当用户在 Claude Code 中发送一条消息时，实际发往 Anthropic LLM API (`api.anthropic.com/v1/messages`) 的完整请求内容。以用户输入 `hello` 为例。

## 一、HTTP 请求头

**文件**: `src/services/api/client.ts`（约第 100-138 行）

### 固定 Headers

```http
POST /v1/messages HTTP/1.1
Host: api.anthropic.com
Authorization: Bearer sk-ant-xxx...  (或 OAuth Bearer token)
User-Agent: Claude-Code/1.x.x
x-app: cli
X-Claude-Code-Session-Id: a1b2c3d4-xxxx-xxxx-xxxx-xxxx
x-client-request-id: e5f6g7h8-xxxx-xxxx-xxxx-xxxx
```

### 条件性 Headers

| Header | 条件 | 说明 |
|--------|------|------|
| `x-claude-remote-container-id` | 容器环境 | `CLAUDE_CODE_CONTAINER_ID` 环境变量 |
| `x-claude-remote-session-id` | 远程会话 | `CLAUDE_CODE_REMOTE_SESSION_ID` 环境变量 |
| `x-client-app` | SDK 调用 | `CLAUDE_AGENT_SDK_CLIENT_APP` 环境变量 |
| `x-anthropic-additional-protection` | 显式启用 | `CLAUDE_CODE_ADDITIONAL_PROTECTION=true` |
| 自定义 Headers | 用户配置 | `ANTHROPIC_CUSTOM_HEADERS` 环境变量 |

### 构建代码

```typescript
const defaultHeaders: { [key: string]: string } = {
  'x-app': 'cli',
  'User-Agent': getUserAgent(),
  'X-Claude-Code-Session-Id': getSessionId(),
  ...customHeaders,
  ...(containerId ? { 'x-claude-remote-container-id': containerId } : {}),
  ...(remoteSessionId ? { 'x-claude-remote-session-id': remoteSessionId } : {}),
  ...(clientApp ? { 'x-client-app': clientApp } : {}),
}
```

### 隐含信息

服务端从 HTTP 层天然获取的信息（代码不主动发送）：
- **客户端 IP 地址** — TCP 连接固有属性
- **TLS 指纹** — TLS 握手特征

## 二、请求体 JSON 完整结构

**文件**: `src/services/api/claude.ts`（约第 1699-1728 行 `paramsFromContext()`）

### 完整请求体示例

```jsonc
{
  // ① 模型选择
  "model": "claude-opus-4-6",

  // ② 系统提示词（分块，用于缓存控制）
  "system": [
    {
      "type": "text",
      "text": "x-anthropic-billing-header: cc_version=1.0.50.a3f; cc_entrypoint=cli;"
    },
    {
      "type": "text",
      "text": "You are Claude Code, Anthropic's official CLI...[完整系统提示词]",
      "cache_control": { "type": "ephemeral", "scope": "org" }
    }
  ],

  // ③ 用户消息
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "hello" }
      ]
    }
  ],

  // ④ 工具定义
  "tools": [
    { "type": "bash_20241022", "name": "bash", ... },
    { "name": "Read", "input_schema": {...} },
    // ... 所有可用工具
  ],

  // ⑤ 元数据
  "metadata": {
    "user_id": "{\"device_id\":\"a1b2c3...\",\"account_uuid\":\"xxx\",\"session_id\":\"yyy\"}"
  },

  // ⑥ 其他参数
  "max_tokens": 16384,
  "thinking": { "type": "adaptive" },
  "tool_choice": "auto",
  "betas": ["interleaved-thinking-2025-05-14", "prompt-caching-2024-07-16"],
  "stream": true
}
```

## 三、各部分详解

### 3.1 系统提示词（System Prompt）

**构建位置**: `src/services/api/claude.ts`（约第 1358-1379 行）、`src/constants/prompts.ts`

#### 构建流程

```typescript
systemPrompt = asSystemPrompt([
  getAttributionHeader(fingerprint),     // 归属追踪头
  getCLISyspromptPrefix({...}),          // "You are Claude Code..."
  ...systemPrompt,                       // 核心指令（多个 section）
  ...(advisorModel ? [ADVISOR_TOOL_INSTRUCTIONS] : []),
  ...(injectChromeHere ? [CHROME_TOOL_SEARCH_INSTRUCTIONS] : []),
].filter(Boolean))
```

#### 系统提示词包含的 Section

| Section | 内容 | 来源文件 |
|---------|------|----------|
| 归属头 | `x-anthropic-billing-header: cc_version=...` | `src/constants/system.ts` |
| 前缀 | `You are Claude Code, Anthropic's official CLI...` | `src/constants/system.ts` |
| 简介 | 角色定义 + CYBER_RISK_INSTRUCTION | `src/constants/prompts.ts` |
| 系统行为 | 工具执行、权限模式、Hook 系统说明 | `src/constants/prompts.ts` |
| 任务处理 | 编码规范、安全注意事项 | `src/constants/prompts.ts` |
| 工具使用 | 各工具使用说明和优先级 | `src/constants/prompts.ts` |
| 环境信息 | OS、Shell、工作目录、git 状态 | `src/constants/prompts.ts` |
| 记忆/上下文 | MEMORY.md 内容（如有） | 动态加载 |
| MCP 指令 | MCP 服务器说明（如有连接） | 动态加载 |
| 语言偏好 | 用户语言设置（如有） | 设置 |
| 输出风格 | 输出样式配置（如有） | 设置 |

#### 环境信息详解

**来源**: `src/constants/prompts.ts`（约第 677-709 行）

系统提示词中明文包含以下用户环境信息：

```
# Environment
You have been invoked in the following environment:
 - Primary working directory: /Users/chen/Documents/my-project    ← 真实路径
 - Is a git repository: true
 - Platform: darwin                                                ← 操作系统
 - Shell: zsh                                                      ← Shell 类型
 - OS Version: Darwin 25.3.0                                       ← 内核版本
 - You are powered by the model named Opus 4.6. The exact model ID is claude-opus-4-6.
```

**注意**: 工作目录路径包含用户名（如 `/Users/chen/...`），这是模型能"看到"的真实用户信息。

#### git 状态信息

系统提示词末尾还包含当前 git 仓库状态：

```
gitStatus:
Current branch: main
Main branch: main
Status: (clean)
Recent commits:
  2ca5dda Fix login bug
  b61a296 Add i18n support
```

### 3.2 归属追踪头

**文件**: `src/constants/system.ts`（约第 73-94 行）

```typescript
const header = `x-anthropic-billing-header: cc_version=${version}; cc_entrypoint=${entrypoint};${cch}${workloadPair}`
```

#### 字段分解

| 字段 | 说明 | 示例 |
|------|------|------|
| `cc_version` | 版本号 + 消息指纹 | `1.0.50.a3f` |
| `cc_entrypoint` | 入口方式 | `cli`, `vscode`, `agent` |
| `cch` | 客户端证明令牌占位符（Bun HTTP 栈覆写） | `cch=00000` |
| `cc_workload` | 工作负载类型（用于 QoS 路由） | `cron`, `auto` |

#### 消息指纹嵌入

`cc_version` 的值是 `版本号.指纹`，其中指纹由 `src/utils/fingerprint.ts` 计算：

```
fingerprint = SHA256("59cf53e54c78" + msg[4] + msg[7] + msg[20] + version)[:3]
```

### 3.3 元数据（metadata）

**文件**: `src/services/api/claude.ts`（约第 503-528 行）

```typescript
export function getAPIMetadata() {
  let extra: JsonObject = {}
  const extraStr = process.env.CLAUDE_CODE_EXTRA_METADATA
  if (extraStr) {
    const parsed = safeParseJSON(extraStr, false)
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      extra = parsed as JsonObject
    }
  }
  return {
    user_id: jsonStringify({
      ...extra,
      device_id: getOrCreateUserID(),
      account_uuid: getOauthAccountInfo()?.accountUuid ?? '',
      session_id: getSessionId(),
    }),
  }
}
```

#### metadata.user_id 的内容

```json
{
  "device_id": "a1b2c3d4e5f6...（64字符hex）",
  "account_uuid": "uuid-of-oauth-account",
  "session_id": "current-session-uuid"
}
```

**注意**: `user_id` 字段是 JSON 字符串化的对象，不是简单的用户 ID。

#### 额外元数据

通过环境变量 `CLAUDE_CODE_EXTRA_METADATA` 可以注入额外的元数据键值对，会被展开到 `user_id` JSON 中。

### 3.4 工具定义（tools）

每次请求都携带所有可用工具的完整 schema 定义，典型的工具列表包括：

| 工具 | 类型 | 说明 |
|------|------|------|
| `bash` | `bash_20241022` | Bash 命令执行 |
| `Read` | 自定义 | 文件读取 |
| `Write` | 自定义 | 文件写入 |
| `Edit` | 自定义 | 文件编辑 |
| `Glob` | 自定义 | 文件名模式匹配 |
| `Grep` | 自定义 | 文件内容搜索 |
| `Agent` | 自定义 | 子 Agent 启动 |
| `WebFetch` | 自定义 | 网页抓取 |
| `WebSearch` | 自定义 | 网页搜索 |
| `NotebookEdit` | 自定义 | Jupyter Notebook 编辑 |
| MCP 工具 | 自定义 | MCP 服务器提供的工具 |

工具定义可能占据请求体的很大比例（数十 KB）。

### 3.5 Beta 功能标识

**文件**: `src/utils/betas.ts`

常见的 beta header 包括：

| Beta | 说明 |
|------|------|
| `interleaved-thinking-2025-05-14` | 交错思考 |
| `prompt-caching-2024-07-16` | 提示缓存 |
| `tool-use-2024-04-04` | 工具使用 |
| `advanced-tool-use-2025-01-15` | 高级工具使用（工具搜索） |
| `structured-outputs-2025-01-15` | 结构化输出 |

具体启用哪些 beta 取决于模型能力、feature flag、用户类型和查询来源。

### 3.6 其他参数

| 参数 | 说明 | 典型值 |
|------|------|--------|
| `max_tokens` | 最大输出 token 数 | 模型相关，如 16384 |
| `thinking` | 思考模式配置 | `{ "type": "adaptive" }` |
| `temperature` | 温度（仅思考禁用时发送） | `1`（默认） |
| `tool_choice` | 工具选择策略 | `"auto"` |
| `speed` | 快速模式（如启用） | `"fast"` |
| `context_management` | 上下文管理（如启用） | `{ "type": "auto" }` |
| `output_config` | 输出配置（effort、task_budget） | `{ "effort": "medium" }` |

## 四、与分析管道的对比

### LLM API 请求 vs 分析事件：数据差异

| 数据 | LLM API 请求 | 分析事件 |
|------|-------------|----------|
| 用户消息内容 | Yes | No |
| 工具定义 | Yes | No |
| 系统提示词 | Yes | No |
| 工作目录路径 | Yes（system prompt） | No |
| git 状态 | Yes（system prompt） | No |
| OS/Shell/内核 | Yes（system prompt，简略） | Yes（详细） |
| device_id | Yes（metadata） | Yes |
| session_id | Yes（metadata） | Yes |
| account_uuid | Yes（metadata） | Yes |
| CPU 架构 | No | Yes |
| 包管理器列表 | No | Yes |
| 运行时列表 | No | Yes |
| 内存/CPU 指标 | No | Yes |
| 仓库 URL 哈希 | No | Yes |
| 订阅类型 | No | Yes |
| Node.js 版本 | No | Yes |

### 关键区别

1. **LLM API** 携带的环境信息是**功能性的**（模型需要知道 OS 才能给出正确命令）
2. **分析管道** 携带的环境信息是**遥测性的**（用于统计和优化）
3. 两条通道通过 `session_id` 和 `device_id` 可在服务端**关联**

## 五、请求大小估算

一个典型的首次 "hello" 请求大致大小：

| 组成部分 | 大约大小 |
|----------|----------|
| 系统提示词 | 15-30 KB |
| 工具定义 | 20-50 KB |
| 用户消息 | < 1 KB |
| 元数据 + 其他参数 | < 1 KB |
| **总计** | **约 40-80 KB** |

后续多轮对话时，messages 数组会累积历史消息，请求体会持续增长（直到触发上下文压缩）。

## 关联文件索引

| 文件 | 职责 |
|------|------|
| `src/services/api/claude.ts` | API 请求构建主逻辑（`paramsFromContext()`） |
| `src/services/api/client.ts` | HTTP 客户端创建、Headers 构建 |
| `src/constants/system.ts` | 归属头、系统提示词前缀 |
| `src/constants/prompts.ts` | 系统提示词各 Section 构建 |
| `src/utils/fingerprint.ts` | 消息指纹算法 |
| `src/utils/api.ts` | 系统提示词分块与缓存控制 |
| `src/utils/betas.ts` | Beta 功能标识管理 |
| `src/utils/sideQuery.ts` | 侧查询（分类器、验证等使用） |
