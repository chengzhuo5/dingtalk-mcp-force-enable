# MCP 协议层实测画像

全部结论来自对 `http://127.0.0.1:8090/mcp` 的实际请求，含原始返回。

## 服务器标识

```json
{
  "capabilities": {
    "logging": {},
    "prompts":  { "listChanged": true },
    "resources": { "listChanged": true, "subscribe": false },
    "tools":    { "listChanged": true }
  },
  "protocolVersion": "2025-03-26",
  "serverInfo": {
    "buildTime": "<构建时间>",
    "name": "DingTalk MCP Server Library",
    "version": "1.0.0"
  }
}
```

> ⚠️ `initialize` 里声明的 `logging` / `prompts` / `resources` 能力**大多是空头支票**，
> 详见下方方法矩阵。

## 方法可用性矩阵（13 个方法实测）

| 方法 | 结果 |
|---|---|
| `initialize` | ✅ 200 |
| `tools/list` | ✅ 200 |
| `tools/call` | ✅ 200 |
| `prompts/list` | ✅ 200（返回 1 个库自带示例） |
| `resources/list` | ✅ 200（返回 1 个库自带示例） |
| `ping` | ❌ `-32601` |
| `logging/setLevel` | ❌ `-32601` |
| `resources/subscribe` | ❌ `-32601` |
| `resources/unsubscribe` | ❌ `-32601` |
| `resources/templates/list` | ❌ `-32601` |
| `prompts/get` | ❌ `-32601` |
| `resources/read` | ❌ `-32601` |
| `completion/complete` | ❌ `-32601` |
| `roots/list` | ❌ `-32601` |
| `sampling/createMessage` | ❌ `-32601` |
| `elicitation/create` | ❌ `-32601` |

**连 `ping` 都没实现** —— 说明这是一个极简实现，只做了必要方法。

### prompts / resources 是脚手架

| 类型 | 唯一项 | 说明 |
|---|---|---|
| prompt | `library_greeting`（参数 `name` 必填） | "Generate a greeting from the MCP library" |
| resource | `library://mcp/info`（`application/json`） | "Information about the MCP library" |

`prompts/get` 与 `resources/read` 都返回 `-32601` —— **只有 list 有实现，内容取不出来**。

这与工具 `echo`（"Echo tool from MCP library"）同源，都是 MCP 库的默认脚手架，**无业务价值**。

## HTTP 传输层

### 方法矩阵

| 方法 | 结果 |
|---|---|
| `POST /mcp` | ✅ 200 |
| `OPTIONS /mcp` | ✅ 200（CORS 预检） |
| `GET /mcp` | ❌ 404 —— **不支持 SSE 流式传输** |
| `PUT` / `DELETE` / `PATCH /mcp` | ❌ 404 |

**只支持 POST**，因此无法使用 MCP 的 SSE 传输模式。

### Session 机制：完全不校验

携带伪造的 `Mcp-Session-Id: totally-bogus-session-123` 请求**依然 200 正常返回**。

→ **无状态服务，session 可选且不验证**。

（响应头里确实会返回 `Mcp-Session-Id: lib_session_<id>_<id>`，但服务端不检查它。）

### 端点唯一

| 路径 | 结果 |
|---|---|
| `/mcp` | ✅ |
| `/` `/sse` `/messages` `/health` `/tools` `/jsonrpc` `/api` | ❌ 全部 404 |

### 响应头

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Headers: Content-Type, Authorization, Mcp-Session-Id
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
Mcp-Session-Id: lib_session_<id>_<id>
Content-Type: application/json
```

CORS 全开（`*`），但实际只接受 POST。

## 错误处理行为

| 输入 | 行为 |
|---|---|
| 畸形 JSON | `-32700 Parse error`，**错误信息泄露底层实现**：`json.exception.parse_error.101`（nlohmann/json） |
| 缺 `method` | `-32601 Method not found:`（方法名为空） |
| 未知工具 | `-32601 Tool not found: <name>` |
| 缺必填参数 | **不报 JSON-RPC 错误**，而是塞进 `result.content`：`Error executing tool '<tool>': Required parameter '<p>' is missing or invalid` |
| `Content-Type: text/plain` | 照样正常处理（不校验 Content-Type） |

**参数校验错误以"工具执行结果"形式返回**，这是需要特别注意的一点 ——
调用方如果只看 JSON-RPC 层的 `error` 字段，会漏掉这类失败。

## 同机其他端口（非 MCP）

| 端口 | 性质 |
|---|---|
| **8090** | **MCP Server**（唯一） |
| 8440 | 普通 HTTP server（返回标准 404 HTML 页） |
| 62910 | TCP 可连，但**对 HTTP 完全静默**（内部二进制通道） |

## 双层 JSON 返回结构（关键）

所有 `tools/call` 返回都是这个形状：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      { "type": "text", "text": "{\"messages\":[...],\"next_cursor\":\"...\"}" }
    ]
  }
}
```

`content[0].text` 是**转义后的 JSON 字符串**，必须二次解析。

直接对原始响应做正则匹配 `"messages":[` 会失配 —— 实际字节是 `\"messages\":[`。

## 参数边界速查（query_messages）

| 参数 | 行为 |
|---|---|
| `cursor: "0"` | ✅ 取最新（推荐首页用法） |
| `cursor: ""` | ❌ `Invalid cursor parameter: must be a valid timestamp string` + `invalid stoll argument` |
| `cursor: "not-a-timestamp"` | ❌ 同上 |
| `cursor: "9999999999999"`（超大） | ✅ 容忍，当取最新 |
| `cursor: "1"`（超小） | ❌ `Failed to get messages ...: 未知类型` |
| `count: 0` / `-5` / `99999` | ✅ 不报错，走默认，受 69 条封顶 |
| `cid` 不存在 / 格式非法 | ✅ 返回 `{"messages":[],"next_cursor":"0"}` |
| `cid` 缺失 | ❌ `Required parameter 'cid' is missing or invalid` |

## 单次条数上限：69

| 请求 count | 实收 |
|---|---|
| 3 | 3 |
| 50 | 50 |
| 100 | **69** |
| 200 | **69** |
| 500 | **69** |

工具描述称上限 100，**实测是 69**。
