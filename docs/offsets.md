# 偏移表与版本差异

## 为什么偏移会变

`MainFrame.dll` 是钉钉主框架，体积随版本增长（实测 8.2.0 约 144MB，8.3.10 约 155MB）。
代码段与只读数据段的重排会导致所有符号地址平移。

因此 **`dtinject21.cpp` 中的两个偏移是版本相关的，不能跨版本照搬**。

## 已实测版本

### 8.3.10.80113（本 skill 的默认值）

| 项 | 值 |
|---|---|
| 文件大小 | 155,211,904 bytes |
| `enable_mcp_server` 文件偏移 | `0x7513D78` |
| `DingTalk Integrated MCP Server` 文件偏移 | `0x77E74C8` |
| `SendMessageTool registered...` 文件偏移 | `0x77E7760` |
| `DingTalkMcpServer started...` 文件偏移 | `0x77E7958` |
| **模块内 patch 点** | **`0x57A0F4D`**（`74 0B` → `90 90`） |
| **模块内启动例程** | **`0x57AB2B0`**（参数 `ecx = 0x1F9A`） |
| MCP 代码区范围 | 约 `0x57AA000` – `0x57AC000` |
| 函数边界（含 STARTLOG） | `0x57AB070` – `0x57AB2A3` |
| 函数边界（含 DTSTART） | `0x57AB2B0` – `0x57AB602` |

参考反汇编：

```asm
57A0F46: E8 E5 C1 00 FB      call  <配置查询>
57A0F4B: 84 DB               test  bl, bl
57A0F4D: 74 0B               jz    57A0F5A        ; ★ patch 此处
57A0F4F: B9 9A 1F 00 00      mov   ecx, 0x1F9A   ; 端口 8090
57A0F54: E8 57 A3 00 00      call  57AB2B0       ; ★ 启动例程
57A0F59: 90                  nop
57A0F5A: ...
```

### 8.2.0.80121（仅静态比对，未动态验证）

| 项 | 值 |
|---|---|
| 文件大小 | 144,133,752 bytes |
| `enable_mcp_server` 文件偏移 | `0x6C6A020` |
| `DingTalk Integrated MCP Server` 文件偏移 | `0x6F03008` |
| `SendMessageTool registered...` 文件偏移 | `0x6F032A0` |
| `DingTalkMcpServer started...` 文件偏移 | `0x6F03448` |

**两版对比结论**：

- 都含完整 MCP 代码 → MCP 是跨版本的基线能力
- `BANNER → SendMessageTool` 间距两版均为 `0x298` → 字符串表结构同源
- `SendMessageTool → DTSTART` 间距 8.3.10 为 `0x1F8`、8.2.0 为 `0x1A8`
  → 8.3.10 在该区间新增了内容
- 文件偏移整体差约 `0x8A0000` → **地址不可复用**

## 如何为新版本重新定位

### 自动化

```powershell
.\scripts\locate-offsets.ps1 -MainFrameDll '<安装目录>\main\current\MainFrame.dll'
```

脚本会：静态确认 MCP 字符串存在 → 注入三个探针 → 收集日志 → 提示判读方法。

### 手工判读

从 `logs\probe20.log` 的字节 dump 中找这个序列：

1. `E8 xx xx xx xx` —— `call`，目标为配置查询函数
2. `84 DB` —— `test bl, bl`（也可能是 `84 C0` / `85 C0`，取决于编译器分配）
3. `74 xx` —— `jz`，**这就是 patch 点**（把两个字节改成 `90 90`）
4. `B9 xx xx xx xx` —— `mov ecx, imm32`，**立即数就是端口**（十进制 8090 = `0x1F9A`）
5. `E8 xx xx xx xx` —— `call`，**目标就是启动例程偏移**

### 校验

改完 `dtinject21.cpp` 后重新编译注入，验证：

```powershell
Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 8090
```

出现监听即成功。

## 常见失败模式

| 现象 | 原因 |
|---|---|
| 注入成功但 8090 不监听 | 偏移不对（patch 打偏或调用了错误函数） |
| 调用后客户端崩溃 | 启动例程签名判断错误（可能不是静态函数，需要 this 指针） |
| 端口起了但 MCP 握手失败 | patch 了错误的条件跳转（走到了别的分支） |
| 找不到 `enable_mcp_server` | 该版本早于 MCP 引入，无法启用 |
| `OpenProcess` 返回 5 | 权限不足，需要管理员 |
