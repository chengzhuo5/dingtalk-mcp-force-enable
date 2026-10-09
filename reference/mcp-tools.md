# MCP 工具完整参考

共 **11 个工具**。其中 10 个是钉钉业务能力，`echo` 是 MCP 库自带的脚手架。

`*` 标记的是必填参数。

---

## 发消息

### `send_message`

向指定用户或会话发送文本消息。

| 参数 | 类型 | 说明 |
|---|---|---|
| `text`* | string | 消息内容 |
| `cid` | string | 会话 ID（**推荐**） |
| `uid` | integer | 用户 ID（单聊，由工具自动构造会话 ID） |

**实测要点**：

- **必须传 `cid`**。用 `uid` 让工具自动拼会话 ID 会被服务端拒绝：
  `Failed to send message. Error code: 130003, Message: 你当前已经退出该群`
- 用 `cid` 则成功，返回：

```json
{"cid":"<会话ID>","mid":"<消息ID>","status":"success","timestamp":"<毫秒时间戳>"}
```

**单聊 cid 格式**：`min(uidA, uidB):max(uidA, uidB)`
**群聊 cid**：直接用 `latest_conversations` 或 `search_conversation` 返回的值

---

## 收消息（实时）

### `listen_messages`

实时监听钉钉新消息。

| 参数 | 类型 | 说明 |
|---|---|---|
| `action`* | string | `start` / `poll` / `stop` |
| `filter_cid` | string | 仅监听指定会话 |
| `filter_sender_id` | string | 仅监听指定发送者 |
| `max_count` | integer | 单次最多返回条数 |

**`start` 返回**：

```json
{"status":"started","filter_cid":"none","filter_sender_id":"none",
 "message":"Message listener started. Use action='poll' to retrieve new messages."}
```

**`poll` 返回（有消息时）**：

```json
{"message_count":"1","status":"ok","messages":[{
  "cid":"<会话ID>","content":"<内容>","content_type":"text",
  "created_at":"<消息创建毫秒>","received_at":"<接收毫秒>",
  "is_single_conv":true,"mid":"<消息ID>",
  "sender_id":"<发送者>","sender_nick":""}]}
```

**`poll` 返回（无消息）**：`{"message_count":"0","messages":[],"status":"ok"}`

**`stop` 返回**：`{"status":"stopped","discarded_messages":"0"}`

**⚠️ 五条实测行为**：

1. **只捕获 `start` 之后到达的入站消息** —— start 之前的要用 `query_messages` 补
2. **自己发给自己的消息不触发** —— 只认入站
3. **`poll` 是"取走"语义** —— 首次 poll 拿到并清空缓冲，后续返回 0 条，必须立刻落库
4. **实测延迟约 2.4 秒**（`received_at` − `created_at`）
5. **字段格式与 `query_messages` 不同**（见下方字段对照）

---

## 查消息（历史）

### `query_messages`

按会话查询历史消息，支持游标分页。

| 参数 | 类型 | 说明 |
|---|---|---|
| `cid`* | string | 会话 ID |
| `count` | integer | 条数，**实际上限 69** |
| `cursor` | string | 毫秒时间戳；**首页传 `"0"` 取最新** |

**返回**（注意是双层 JSON 的内层）：

```json
{
  "messages": [{
    "at_open_ids": "{}",
    "cid": "<会话ID>",
    "content": "<内容>",
    "content_type": "1",
    "create_time": "<毫秒>",
    "mid": "<消息ID>",
    "msg_type": "1",
    "sender_uid": "<发送者>",
    "status": "1",
    "update_time": "<毫秒>"
  }],
  "next_cursor": "<下一页游标>"
}
```

**翻页算法**：

```
cursor = "0"
seen = set()
loop:
    r = query_messages(cid, count=69, cursor=cursor)
    for m in r.messages:
        if m.mid not in seen:  # 页边界会重叠，必须去重
            save(m); seen.add(m.mid)
    if r.next_cursor == cursor: break    # 到底
    cursor = r.next_cursor
```

**到底的三条判据**：
1. `next_cursor` 与传入值相同（不再前进）
2. 该页只返回 **1 条**与上页末条重复的记录
3. 或 `messages` 为空数组

**实测深度**：无硬性上限。某 1500 人群翻 **34 页约 2300+ 条**，回溯约 **2 个月**；
小会话 2 页 39 条回溯约 4 个月。能翻多早取决于本地缓存完整度。

---

## 会话

### `latest_conversations`

最近会话列表，按最后修改倒序。

| 参数 | 类型 | 说明 |
|---|---|---|
| `count` | integer | 数量 |

**返回**（数组）：

```json
[{
  "alias": "", "cid": "<会话ID>", "createAt": "<毫秒>",
  "groupIcon": "", "lastMid": "<最新消息ID>",
  "lastModify": "<毫秒>", "memberCount": "2",
  "orgId": "0", "title": "<标题>", "unreadCount": "0"
}]
```

**实用技巧**：用 `unreadCount` 定位新消息落在哪个会话（非 0 的即是）。

### `get_current_conversation_id`

获取客户端**当前打开**的会话 ID。

| 参数 | 类型 | 说明 |
|---|---|---|
| `placeholder` | string | 占位参数，无实际作用 |

**返回**：`{"cid":"<会话ID>","hasCurrentConversation":true}`

**实测**：会**随客户端窗口切换而动态变化**（两次调用可能返回不同 cid）。

### `search_conversation`

按关键词搜索会话，支持分页。

| 参数 | 类型 | 说明 |
|---|---|---|
| `keyword`* | string | 关键词 |
| `offset` | integer | 偏移 |
| `size` | integer | 数量 |
| `startCreateAt` | integer | 起始创建时间 |

**返回**（数组，元数据丰富）：

```json
[{
  "cid":"<会话ID>","createTime":"<毫秒>",
  "isInConference":"false","isMute":"true","isSearchable":"true",
  "isShowHistory":"true","isShowMemberCount":"true","isTop":"false",
  "lastModify":"<毫秒>","memberCount":"18","title":"<标题>","type":"2"
}]
```

---

## 通讯录

### `search_user`

搜索通讯录用户。

| 参数 | 类型 | 说明 |
|---|---|---|
| `keyword`* | string | 姓名 / 手机号等 |
| `orgId` | integer | 组织 ID |
| `size` | integer | 数量 |
| `uids` | string | 按 uid 批量查 |
| `validUserTypeArr` | string | 用户类型过滤 |

**返回**（数组）：

```json
[{
  "alias":"", "avatar_media_id":"<mediaId>", "avatar_url":"<URL>",
  "email":"", "extension":"", "mobile":"",
  "nick":"<昵称>", "nick_pinyin":"<拼音>",
  "uid":"<用户ID>", "user_type":"5", ...
}]
```

### `my_profile`

获取当前登录用户资料。

| 参数 | 类型 | 说明 |
|---|---|---|
| `placeholder` | string | 占位参数 |

**返回**：`{"mobile":"","nick":"<昵称>","real_name":"","uid":"<自己的 uid>"}`

**用途**：拿自己的 uid，用于构造单聊 cid。

---

## 辅助

### `get_current_time`

| 参数 | 类型 | 说明 |
|---|---|---|
| `timezone` | string | 如 `+08:00`、`-05:00`；不传则 UTC |

**返回**：`"2026-10-09 12:36:38"` 格式字符串。

**实测**：`timezone="+08:00"` 与不传返回相差 8 小时 —— **参数真实生效**。

### `network_check`

网络诊断。

| 参数 | 类型 | 说明 |
|---|---|---|
| `target` | string | 目标主机 |

**返回**（3.4KB 级详细报告，实测约 2.4 秒）：

- 多域名 DNS 解析 + TCP 443 连通性
- 代理 / VPN 状态（app / browser / system 三处）
- 公网出口 IP + 地理位置 + ASN
- 客户端网络配置（`env_type`、`unit_type`、代理设置）
- `resource_loader_test` 下载自检

### `echo`

MCP 库自带的回显工具，用于测试通道。

| 参数 | 类型 | 说明 |
|---|---|---|
| `message`* | string | 回显内容 |

**返回**：

```json
{"echo_response":"<原样返回>","port":8090,
 "source":"DingTalk MCP Server Library","timestamp":"<秒级时间戳>"}
```

---

## 字段格式对照（重要）

监听与查询返回的是**两套不同来源**的数据，字段名不一致：

| 含义 | `listen_messages` | `query_messages` |
|---|---|---|
| 会话 ID | `cid` | `cid` |
| 消息 ID | `mid` | `mid` |
| 内容 | `content` | `content` |
| 发送者 | `sender_id` | `sender_uid` |
| 创建时间 | `created_at` | `create_time` |
| 接收时间 | `received_at` | — |
| 更新时间 | — | `update_time` |
| 内容类型 | `content_type: "text"` | `content_type: "1"` |
| 消息类型 | — | `msg_type` |
| 是否单聊 | `is_single_conv` | — |
| @ 列表 | — | `at_open_ids` |
| 状态 | — | `status` |

**归档时必须归一化**，并建议打 `source` 标记区分来源。
