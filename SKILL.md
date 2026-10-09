---
name: dingtalk-mcp-force-enable
description: 在钉钉 PC 定制版（如券商定制客户端）本地启用被企业策略关闭的内置 MCP Server，从而让外部 AI 客户端通过 http://127.0.0.1:8090/mcp 读写钉钉会话。适用于：用户要求「打开钉钉 MCP」「让 AI 收发钉钉消息」「企业没开通 MCP 想本地启用」；也适用于为一台新机器/新版本重新定位注入偏移。触发词：钉钉 MCP、DingTalk MCP、enable_mcp_server、聚力 MCP、钉钉 AI 桥、8090、MCP Server 强行打开、钉钉消息归档。
---

# 钉钉定制版内置 MCP Server 本地启用

## 这个 skill 解决什么

钉钉 PC 端（含券商等企业定制版，如「招证聚力」CMSDING）**内置了一套完整的 MCP Server**
（`DingTalk MCP Server Library`），提供收发/查询钉钉消息的能力，但默认被服务端下发的
特性开关 `general.enable_mcp_server` 关闭。

本 skill 通过在客户端进程内做两件事把它打开：

1. 把启动前的条件跳转 patch 成无条件（`74 0B` → `90 90`）
2. 直接调用启动例程并传入端口 `0x1F9A`（8090）

**全程只 patch 内存，磁盘零改动，重启钉钉即自动回滚。**

## 核心事实（实测确认）

| 项 | 值 |
|---|---|
| MCP 代码位置 | `MainFrame.dll`（钉钉主框架，非任何企业定制模块） |
| CompanyName | `Alibaba software (Shanghai) Corporation.` |
| 开关名 | `general.enable_mcp_server`（服务端下发，存于共享内存映射区，无本地文件） |
| 服务端口 | **8090**（HTTP，仅响应 `POST /mcp`） |
| 服务名 | `DingTalk MCP Server Library` v1.0.0 |
| 协议版本 | `2025-03-26` |
| 已验证版本 | **8.3.10.80113** 与 **8.2.0.80121** 均含完整 MCP 代码 |

## 快速使用

```powershell
# 1. 定位偏移（换新版本必须重做；同版本可跳过）
.\scripts\locate-offsets.ps1 -MainFrameDll "<安装目录>\MainFrame.dll"

# 2. 编译注入器（需 MSVC）
.\scripts\build.ps1

# 3. 注入并启动 MCP（目标为主进程：无 --type= 参数且加载了 MainFrame.dll）
.\scripts\inject.ps1 -ProcessName CMSDING -Dll .\build\dtinject21.dll

# 4. 验证
Invoke-WebRequest 'http://127.0.0.1:8090/mcp' -Method POST `
  -Body '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' `
  -ContentType 'application/json'
```

## MCP 提供的能力

**11 个工具**（详见 `reference/mcp-tools.md`）：

| 类别 | 工具 |
|---|---|
| 发 | `send_message` |
| 收（实时） | `listen_messages`（start/poll/stop） |
| 查（历史） | `query_messages`（cursor 分页）、`search_conversation` |
| 会话 | `latest_conversations`、`get_current_conversation_id` |
| 通讯录 | `search_user`、`my_profile` |
| 辅助 | `get_current_time`、`network_check`、`echo` |

**只实现了 5 个协议方法**：`initialize`、`tools/list`、`tools/call`、`prompts/list`、`resources/list`。
其余（含 `ping`、`prompts/get`、`resources/read`）返回 `-32601`。

## 必须知道的实测坑

**① 发消息用 `cid`，别用 `uid`** — 用 uid 让工具自拼会话 ID 会被服务端判为
「你当前已经退出该群」（错误码 130003）；显式传 cid 才成功。

**② `query_messages` 单次上限是 69 条**，不是文档写的 100。

**③ 返回是双层 JSON** — 外层 `result.content[0].text` 里是**转义后的 JSON 字符串**，
必须二次解析。

**④ `listen_messages` 只捕获 start 之后到达的入站消息** —
start 之前的历史要用 `query_messages`；自己发给自己的消息不触发。

**⑤ `listen_messages` 的 poll 是"取走"语义** — 首次 poll 拿到并清空缓冲，之后返回 0 条。

**⑥ 两套字段格式** — 监听（`received_at`/`sender_id`/`is_single_conv`）与
查询（`create_time`/`sender_uid`/`msg_type`）不同源，归档时需归一化。

**⑦ 分页到底信号** — `next_cursor` 不再前进，且该页只返回 1 条与上页末条重复的记录。

## 适用范围

**通用**：MCP 是钉钉官方基线能力，只要该定制版基于含 MCP 的版本构建（≥ 8.2.0），
思路一致，**任何定制版都可套用**。是否"已开通"取决于**各自企业的服务端策略**，
互不影响。

**不通用**：**具体偏移地址随版本变动**（实测 8.2.0 与 8.3.10 的文件偏移差约 0x8A0000）。
换版本**必须重跑定位探针**，不能照搬 `reference/offsets.md` 里的地址。

## 边界与风险

- **需要管理员或同等权限**才能 `OpenProcess` + `CreateRemoteThread`
- **重启即失效**，需重新注入（可配合计划任务自动化）
- **不保证所有定制版都无完整性校验**，若注入后客户端异常退出，说明存在防护
- 本 skill **只做只读与内存 patch**，不修改钉钉任何文件、不改服务端协议
- 请仅在**你拥有或被授权操作的设备与账号**上使用

## 文件导航

```
SKILL.md                  本文件
README.md                 完整技术原理与复现步骤
scripts/
  locate-offsets.ps1      偏移定位入口（封装三个探针）
  dtinject18.cpp          探针1：定位 MCP 字符串在代码段中的引用点
  dtinject19.cpp          探针2：用 int3 填充找函数边界 + 找 call 点
  dtinject20.cpp          探针3：dump 调用点字节，识别 flag 检查模式
  dtinject21.cpp          主注入器：patch 条件跳转 + 调用启动例程
  inject.ps1              通用 DLL 注入器（CreateRemoteThread + LoadLibraryW）
  dt-archive.ps1          消息归档器：全量拉取 + 实时监听 + 可搜索消息库
  build.ps1               一键编译全部 C++ 探针
docs/
  offsets.md              偏移表与版本差异说明
  protocol.md             MCP 协议层实测画像（方法矩阵 / HTTP 行为 / 边界参数）
reference/
  mcp-tools.md            11 个工具的完整参数与实测返回
```
