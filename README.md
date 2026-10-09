# 钉钉定制版内置 MCP Server 本地启用

> 把钉钉 PC 定制版（券商等企业专属客户端）里**被企业策略关闭**的内置 MCP Server 在本地打开，
> 让外部 AI 客户端通过 `http://127.0.0.1:8090/mcp` 读写钉钉会话。

**只 patch 内存，磁盘零改动，重启客户端即自动回滚。**

---

## 目录

- [背景：为什么客户端里会有 MCP](#背景为什么客户端里会有-mcp)
- [技术原理](#技术原理)
- [完整复现步骤](#完整复现步骤)
- [偏移表与版本差异](#偏移表与版本差异)
- [MCP 能力速查](#mcp-能力速查)
- [实测踩坑清单](#实测踩坑清单)
- [适用范围](#适用范围)
- [风险与合规](#风险与合规)

---

## 背景：为什么客户端里会有 MCP

在 `MainFrame.dll`（钉钉主框架）中可以直接搜到完整的 MCP Server 实现痕迹：

```
DingTalk Integrated MCP Server
D:\...\DingTalk\dingtalk\mcp\mcp_server.cc
DingTalkMcpServer started successfully on port
DateTool registered successfully using register_tool method
LatestConversationTool registered successfully using register_tool method
...
SendMessageTool registered successfully using register_tool method
```

也就是说 **MCP 是钉钉官方基线能力**，不是企业定制出来的功能。

同时存在一个特性开关名：

```
general.enable_mcp_server
```

它与 `dark_mode`、`performance_report`、`advertising_enable` 等一起出现在 MainFrame.dll 的
**特性开关名表**中 —— 说明它由服务端灰度/企业管理策略控制。

**"公司没开"的真相**：服务端下发了 `false`。客户端代码是完整的，只是没执行启动分支。

---

## 技术原理

### 开关值的存放位置

`general.enable_mcp_server` 的值**不在任何磁盘文件里**：

- 注册表 `HKCU\Software\<客户端>\Feature` 下只有 2 个无关项
- 用户数据目录全文搜索无命中
- 运行时它出现在**共享内存映射区**（`prot=PAGE_READWRITE`，`type=MEM_MAPPED`，
  且 `GetMappedFileName` 返回"无映射文件"）

条目格式为 `[hash 4B][seq 1B][flags 1B][字符串][8B 值指针]`，
该 flag 是第 `0x2A` 号条目。因为值是**指针**而非内联布尔，直接改内存不可靠。

**结论：没有"改配置文件"的路，只能改代码路径。**

### 启动逻辑（反汇编还原）

在 `MainFrame.dll` 的 MCP 代码区（约 8KB 连续区间）内，启动分支形如：

```asm
57A0F46: E8 E5 C1 00 FB      call  <配置查询>        ; 读 general.enable_mcp_server
57A0F4B: 84 DB               test  bl, bl            ; 检查返回值
57A0F4D: 74 0B               jz    57A0F5A          ; false 则跳过启动   ★
57A0F4F: B9 9A 1F 00 00      mov   ecx, 0x1F9A       ; 端口 = 8090
57A0F54: E8 57 A3 00 00      call  57AB2B0          ; ★ 启动例程
57A0F59: 90                  nop
57A0F5A:                     <继续>
```

`0x1F9A` = **8090**，即 MCP 监听端口。

### 绕过手法

两个动作：

1. **patch 条件跳转**：`74 0B`（`jz +11`）→ `90 90`（`nop nop`）
   —— 让启动分支无条件执行
2. **直接调用启动例程**：`0x57AB2B0(0x1F9A)`
   —— 该例程是静态函数、唯一参数为端口（调用前只设置了 `ecx`），
     因此不必依赖外层函数被重新触发，立即生效

第 2 步让效果**无需重启**；第 1 步保证后续流程经过该处时也能正常启动。

---

## 完整复现步骤

### 前置条件

- Windows x64
- 目标客户端已启动并登录
- 管理员或同等权限（注入需要 `OpenProcess` + `CreateRemoteThread`）
- Visual Studio（含「使用 C++ 的桌面开发」）用于编译探针

### 步骤 1 — 确认目标版本含 MCP

```powershell
$dll = '<安装目录>\main\current\MainFrame.dll'
$ascii = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($dll))
$ascii.IndexOf('enable_mcp_server')      # >= 0 即说明该版本含 MCP
(Get-Item $dll).VersionInfo.FileVersion  # 记录版本号
```

### 步骤 2 — 编译探针与注入器

```powershell
cd <skill>\scripts
.\build.ps1
```

产出 `build\dtinject18.dll` ~ `dtinject21.dll`。

### 步骤 3 — 定位偏移

```powershell
.\locate-offsets.ps1 -MainFrameDll '<安装目录>\main\current\MainFrame.dll'
```

三个探针依次运行：

| 探针 | 作用 | 输出 |
|---|---|---|
| `dtinject18` | 找 MCP 字符串的 RIP-relative 引用点 | 字符串地址 + 引用指令偏移 |
| `dtinject19` | 用 int3 填充识别函数边界；找 call 指令 | 函数入口表 + 调用点偏移 |
| `dtinject20` | dump 调用点附近字节 | 可人工判读的 `test/jz/mov ecx/call` 序列 |

把判读出的 **patch 点**与**启动例程**偏移填入 `dtinject21.cpp` 顶部常量。

**已验证版本（8.3.10.80113）** 的偏移可直接使用，见 `docs/offsets.md`。

### 步骤 4 — 注入并启动 MCP

```powershell
# 目标进程：无 --type= 参数、且加载了 MainFrame.dll 的那个
.\inject.ps1 -ProcessName CMSDING -DllPath ..\build\dtinject21.dll
```

### 步骤 5 — 验证

```powershell
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
(Invoke-WebRequest 'http://127.0.0.1:8090/mcp' -Method POST -Body $body -ContentType 'application/json').Content
```

期望返回：

```json
{"result":{"capabilities":{"tools":{"listChanged":true}},
 "protocolVersion":"2025-03-26",
 "serverInfo":{"name":"DingTalk MCP Server Library","version":"1.0.0"}}}
```

### 步骤 6 —（可选）归档消息

```powershell
.\dt-archive.ps1 -Action Init        # 初始化，拉会话列表
.\dt-archive.ps1 -Action Fetch       # 全量拉历史（可反复跑，自动去重）
.\dt-archive.ps1 -Action Listen      # 实时监听增量
.\dt-archive.ps1 -Action Search -Keyword "关键词"
.\dt-archive.ps1 -Action Stats
```

---

## 偏移表与版本差异

| 版本 | 文件大小 | `enable_mcp_server` 文件偏移 |
|---|---|---|
| **8.3.10.80113** | 155,211,904 | 0x7513D78 |
| **8.2.0.80121** | 144,133,752 | 0x6C6A020 |

**关键结论：偏移不可跨版本复用**（两版差约 `0x8A0000`）。

字符串表结构同源（`BANNER → SendMessageTool` 间距均为 `0x298`），但具体地址随版本变动。

**换版本必须重跑 `locate-offsets.ps1`。**

详见 `docs/offsets.md`。

---

## MCP 能力速查

**11 个工具**（完整参数见 `reference/mcp-tools.md`）：

| 类别 | 工具 | 说明 |
|---|---|---|
| 发 | `send_message` | 发文本消息 |
| 收 | `listen_messages` | 实时监听（start/poll/stop） |
| 查 | `query_messages` | 按会话查历史，cursor 分页 |
| 查 | `search_conversation` | 搜索会话 |
| 会话 | `latest_conversations` | 最近会话列表 |
| 会话 | `get_current_conversation_id` | 当前打开的会话 |
| 通讯录 | `search_user` | 搜索用户 |
| 通讯录 | `my_profile` | 自己的资料 |
| 辅助 | `get_current_time` / `network_check` / `echo` | 时间 / 网络诊断 / 回显 |

**协议方法只实现了 5 个**：`initialize`、`tools/list`、`tools/call`、`prompts/list`、`resources/list`。
其余（含 `ping`、`prompts/get`、`resources/read`）一律返回 `-32601`。

**传输层**：仅 `POST /mcp`（无 SSE）；session 完全不校验（无状态）；
只有 `/mcp` 一个端点；畸形 JSON 会泄露底层为 nlohmann/json。

详见 `docs/protocol.md`。

---

## 实测踩坑清单

这些都是实际踩过并验证过的，不是推测：

**① 发消息用 `cid`，不要用 `uid`**
用 uid 让工具自拼会话 ID 会被服务端拒绝：`130003 你当前已经退出该群`。
显式传 cid 才能成功。

**② `query_messages` 单次上限是 69 条**，不是工具描述里写的 100。
`count=100/200/500` 都只返回 69。

**③ 返回是双层 JSON**
外层 `result.content[0].text` 里装的是**转义后的 JSON 字符串**，必须二次解析。
直接正则匹配 `"messages":[` 会失配（实际是 `\"messages\":[`）。

**④ `listen_messages` 只捕获 start 之后到达的入站消息**
- start 之前的历史消息捕不到（要用 `query_messages`）
- **自己发给自己的消息不触发**
- 实测延迟约 2.4 秒（`received_at` − `created_at`）

**⑤ `listen_messages` 的 poll 是"取走"语义**
首次 poll 拿到并清空缓冲，之后 poll 返回 0 条。必须立刻落库。

**⑥ 监听与查询是两套字段格式**
| 监听（实时事件） | 查询（数据库） |
|---|---|
| `received_at` | `create_time` |
| `sender_id` | `sender_uid` |
| `is_single_conv` | `msg_type` |
| `content_type: "text"` | `content_type: "1"` |

归档时需归一化并打 `source` 标记。

**⑦ 分页到底的信号**
`next_cursor` 不再前进，**且该页只返回 1 条与上页末条重复的记录**。
页边界会重叠，必须按 `mid` 去重。

**⑧ cursor 参数必须是合法时间戳字符串**
`cursor:""` 或非数字会抛 `Invalid cursor parameter` +
`invalid stoll argument`（C++ `std::stoll` 异常泄露）。
`cursor:"0"` 是"取最新"的正确用法。

**⑨ PowerShell 写归档器时的两个真坑**
- `$Args` 是**自动变量**，不能用作函数参数名（会报类型转换错误）
- `return $set` 会**展开集合**，空 HashSet 退化成 `$null`；
  需用 `return ,$set` 阻止展开

---

## 适用范围

**方法通用**：MCP 是钉钉官方基线能力。只要目标定制版基于含 MCP 的版本构建
（实测 ≥ 8.2.0 就有），**同一套方法适用于任何定制版**——其他券商版、其他企业专属版、
乃至通用版钉钉。

**开关独立**：`general.enable_mcp_server` 由**各企业服务端分别下发**。
A 公司没开不代表 B 公司没开，互不影响。

**偏移不通用**：具体地址随版本变动，换版本必须重跑定位探针。

---

## 风险与合规

- **需要管理员或同等权限**；普通用户权限下 `OpenProcess` 会被拒绝
- **重启即失效**：内存 patch 不持久，重启后需重新注入
- **可能存在完整性校验**：实测的这个客户端没有拦截，但不保证所有定制版都没有。
  若注入后客户端异常退出或 `Responding=False`，说明存在防护，应停止并回滚
- **不修改任何磁盘文件、不改服务端协议、不做持久化**
- **不包含任何真实账号信息**：仓库内所有示例均为占位符

> 请仅在**你拥有或被明确授权操作的设备与账号**上使用。
> 在受雇环境中，开启被企业策略关闭的能力可能违反内部规定，请先确认授权。

---

## 许可

仅供安全研究与技术学习。使用者需自行承担合规责任。
