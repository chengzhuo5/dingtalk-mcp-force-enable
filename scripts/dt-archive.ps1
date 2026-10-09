<#
.SYNOPSIS
  DingTalk MCP 消息归档器 —— 全量拉取历史 + 增量实时监听，落成本地可搜索消息库。

.DESCRIPTION
  通过本地 DingTalk MCP Server (127.0.0.1:8090/mcp) 的 query_messages / listen_messages
  接口，把钉钉消息归档为 JSONL 文件。全程只读，不发送任何消息。

  关键实现要点（均由实测得出）：
    * 返回是双层 JSON：外层 result.content[0].text 内是转义后的 JSON 字符串，需二次解析
    * query_messages 单次上限 69 条（不是文档说的 100）
    * 首页用 cursor="0" 取最新；next_cursor 与传入值相同即到底
    * 页边界会重叠 1 条，必须按 mid 去重
    * listen_messages 只捕获 start 之后到达的入站消息，poll 为取走语义
    * listen_messages 与 query_messages 字段格式不同，归档时统一归一化

.PARAMETER Action
  Init      初始化数据库与目录
  Fetch     全量拉取历史（可重复运行，自动去重）
  Listen    启动实时监听（前台持续运行，Ctrl+C 停止）
  Rescan    仅刷新会话列表
  Search    按关键词检索已归档消息
  Stats     显示归档统计

.PARAMETER Keyword
  Search 动作使用的关键词

.PARAMETER Cid
  可选，仅对指定会话执行 Fetch

.PARAMETER MaxPages
  每个会话最多翻页数，默认 500（防止意外长循环）

.EXAMPLE
  .\dt-archive.ps1 -Action Init
  .\dt-archive.ps1 -Action Fetch
  .\dt-archive.ps1 -Action Listen
  .\dt-archive.ps1 -Action Search -Keyword "上线"
  .\dt-archive.ps1 -Action Stats
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'Fetch', 'Listen', 'Rescan', 'Search', 'Stats')]
    [string]$Action,

    [string]$Keyword = '',
    [string]$Cid = '',
    [int]$MaxPages = 500,
    [int]$PollSeconds = 3,
    [string]$Root = "$PSScriptRoot\archive"
)

$ErrorActionPreference = 'Stop'
$McpUrl       = 'http://127.0.0.1:8090/mcp'
$MsgFile      = Join-Path $Root 'messages.jsonl'
$ConvFile     = Join-Path $Root 'conversations.json'
$StateFile    = Join-Path $Root 'state.json'
$LogFile      = Join-Path $Root 'archive.log'
$PreCount     = 69          # 实测单次上限
$PageDelayMs  = 120         # 翻页间隔，避免给客户端压力

# ---------------------------------------------------------------- 基础设施
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Get-McpReady {
    if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    $ls = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
          Where-Object { $_.LocalPort -eq 8090 }
    if (-not $ls) {
        throw "MCP Server 未在 127.0.0.1:8090 监听。请先确认招证聚力已启动且 MCP 已开启（注入 dtinject21.dll）。"
    }
    return $ls.OwningProcess
}

function Invoke-Mcp {
    param([string]$Method, [hashtable]$Params = @{})
    $rid = Get-Random -Minimum 10000 -Maximum 99999
    $payload = @{ jsonrpc = '2.0'; id = $rid; method = $Method; params = $Params } |
               ConvertTo-Json -Depth 8 -Compress
    $resp = Invoke-WebRequest -Uri $McpUrl -Method POST -Body $payload `
              -ContentType 'application/json' -UseBasicParsing -TimeoutSec 60
    return ($resp.Content | ConvertFrom-Json)
}

function Invoke-Tool {
    param([string]$Tool, [hashtable]$Arguments = @{})
    $r = Invoke-Mcp -Method 'tools/call' -Params @{ name = $Tool; arguments = $Arguments }
    $text = $r.result.content[0].text
    if ($null -eq $text) { return $null }
    if ($text -like "Error executing tool*") {
        Write-Log -Message "$Tool 返回错误: $text" -Level 'WARN'
        return $null
    }
    # 第二层解析：text 内是 JSON 字符串（部分工具返回非 JSON，此处按需兜底）
    try { return ($text | ConvertFrom-Json) } catch { return $text }
}

function Get-SeenIds {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path $MsgFile) {
        foreach ($line in [System.IO.File]::ReadLines($MsgFile)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $o = $line | ConvertFrom-Json
                if ($o.mid) { [void]$set.Add([string]$o.mid) }
            } catch { }
        }
    }
    # 逗号操作符：阻止 PowerShell 展开集合（空集合会退化成 $null）
    return ,$set
}

# 统一的归档写入（按 mid 去重，UTF-8 追加）
function Add-Messages {
    param(
        [Parameter(Mandatory)] $Messages,
        [System.Collections.Generic.HashSet[string]]$Seen,
        [string]$Source = 'query'     # query | listen
    )
    if ($null -eq $Seen) { $Seen = Get-SeenIds }
    $added = 0; $skipped = 0
    $sw = New-Object System.IO.StreamWriter($MsgFile, $true, (New-Object Text.UTF8Encoding($false)))
    try {
        foreach ($m in $Messages) {
            if ($null -eq $m) { continue }
            # 归一化：listen 与 query 两套字段名并存
            $mid = if ($m.mid) { [string]$m.mid } else { $null }
            if (-not $mid) { continue }
            if ($Seen.Contains($mid)) { $skipped++; continue }

            $createdAt = if ($m.create_time) { [string]$m.create_time }
                         elseif ($m.created_at) { [string]$m.created_at } else { '' }
            $senderId  = if ($m.sender_uid) { [string]$m.sender_uid }
                         elseif ($m.sender_id) { [string]$m.sender_id } else { '' }
            $ct        = if ($m.content_type) { [string]$m.content_type } else { '' }

            $rec = [ordered]@{
                mid        = $mid
                cid        = [string]$m.cid
                content    = [string]$m.content
                sender_uid = $senderId
                sender_nick= [string]$m.sender_nick
                create_time= $createdAt
                update_time= if ($m.update_time) { [string]$m.update_time } else { $createdAt }
                msg_type   = if ($m.msg_type) { [string]$m.msg_type } else { '' }
                content_type = $ct
                at_open_ids  = [string]$m.at_open_ids
                is_single_conv = $m.is_single_conv
                received_at= [string]$m.received_at
                source     = $Source
                archived_at= [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            }
            $sw.WriteLine(($rec | ConvertTo-Json -Compress -Depth 6))
            [void]$Seen.Add($mid)
            $added++
        }
    }
    finally { $sw.Close() }
    return [pscustomobject]@{ Added = $added; Skipped = $skipped }
}

# ---------------------------------------------------------------- 会话列表
function Update-Conversations {
    $all = @()
    # latest_conversations 只给最近 N 个，多次放宽以覆盖更多
    foreach ($cnt in 50, 100, 200) {
        $r = Invoke-Tool -Tool 'latest_conversations' -Arguments @{ count = $cnt }
        if ($r -and $r.Count -gt $all.Count) { $all = $r }
        if ($r -and $r.Count -lt $cnt) { break }   # 已取全
    }
    if ($all.Count -gt 0) {
        $all | ConvertTo-Json -Depth 6 | Set-Content -Path $ConvFile -Encoding UTF8
        Write-Log "会话列表已更新：$($all.Count) 个会话"
    } else {
        Write-Log '会话列表获取为空' -Level 'WARN'
    }
    return ,$all
}

function Get-Conversations {
    if (Test-Path $ConvFile) {
        $c = Get-Content $ConvFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return ,@($c)
    }
    return ,@()
}

# ---------------------------------------------------------------- Fetch：全量拉取
function Invoke-Fetch {
    Write-Log '=== 开始全量拉取历史 ==='
    $pids = Get-McpReady
    Write-Log "MCP server pid = $pids"

    $convs = Get-Conversations
    if (-not $convs -or $convs.Count -eq 0) { $convs = Update-Conversations }

    $targets = @($convs)
    if ($Cid) { $targets = @($convs | Where-Object { $_.cid -eq $Cid }) }
    if ($targets.Count -eq 0) { Write-Log '没有可拉取的会话' -Level 'WARN'; return }

    $seen = Get-SeenIds
    Write-Log "库内已有 $($seen.Count) 条消息，本次将跳过重复"

    $grandAdded = 0
    foreach ($cv in $targets) {
        $cid = $cv.cid
        $title = if ($cv.title) { $cv.title } else { $cid }
        $cursor = '0'
        $page = 0
        $convAdded = 0
        Write-Log "-- 会话 [$title] ($cid)"

        while ($page -lt $MaxPages) {
            $page++
            $res = $null
            try {
                $res = Invoke-Tool -Tool 'query_messages' -Arguments @{ cid = $cid; count = $PreCount; cursor = $cursor }
            } catch {
                Write-Log "  第 $page 页请求异常: $($_.Exception.Message)" -Level 'WARN'
                break
            }
            if ($null -eq $res -or $null -eq $res.messages -or $res.messages.Count -eq 0) {
                Write-Log "  第 $page 页无数据，会话到底"
                break
            }
            $r = Add-Messages -Messages $res.messages -Seen $seen -Source 'query'
            $convAdded += $r.Added
            $grandAdded += $r.Added

            $next = if ($res.next_cursor) { [string]$res.next_cursor } else { '' }
            if ($page % 10 -eq 0 -or $r.Added -gt 0) {
                Write-Log ("  第 {0,3} 页: {1,3} 条(新 {2,3}) | cursor {3}" -f $page, $res.messages.Count, $r.Added, $next)
            }
            if (-not $next -or $next -eq $cursor) { break }   # 到底信号
            $cursor = $next
            Start-Sleep -Milliseconds $PageDelayMs
        }
        Write-Log "  会话完成：新增 $convAdded 条"
    }
    Write-Log "=== 全量拉取结束，本次新增 $grandAdded 条，库内共 $($seen.Count) 条 ==="
    Save-State -Extra @{ last_fetch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
}

# ---------------------------------------------------------------- Listen：实时监听
function Invoke-Listen {
    Write-Log '=== 启动实时监听（Ctrl+C 停止）==='
    $null = Get-McpReady
    $seen = Get-SeenIds
    Write-Log "库内已有 $($seen.Count) 条消息"

    $r = Invoke-Tool -Tool 'listen_messages' -Arguments @{ action = 'start' }
    Write-Log "监听器状态: $($r.status)"

    $pollCount = 0
    try {
        while ($true) {
            $pollCount++
            $res = $null
            try {
                $res = Invoke-Tool -Tool 'listen_messages' -Arguments @{ action = 'poll' }
            } catch {
                Write-Log "poll 异常: $($_.Exception.Message)" -Level 'WARN'
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            if ($res -and $res.messages -and $res.messages.Count -gt 0) {
                $add = Add-Messages -Messages $res.messages -Seen $seen -Source 'listen'
                foreach ($m in $res.messages) {
                    Write-Log ("  [新消息] $($m.sender_id) @ $($m.cid): $($m.content)") 'MSG'
                }
                Write-Log "已入库 $($add.Added) 条（跳过重复 $($add.Skipped) 条）"
            }
            if ($pollCount % 100 -eq 0) { Write-Log "监听中… 已 poll $pollCount 次，库内 $($seen.Count) 条" }
            Start-Sleep -Seconds $PollSeconds
        }
    }
    finally {
        $null = Invoke-Tool -Tool 'listen_messages' -Arguments @{ action = 'stop' }
        Write-Log '监听已停止'
        Save-State -Extra @{ last_listen = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    }
}

# ---------------------------------------------------------------- 状态
function Save-State {
    param([hashtable]$Extra = @{})
    $state = [ordered]@{
        updated_at   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        message_file = $MsgFile
        server_pid   = (Get-McpReady)
    }
    foreach ($k in $Extra.Keys) { $state[$k] = $Extra[$k] }
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8
}

# ---------------------------------------------------------------- Search / Stats
function Invoke-Search {
    if (-not $Keyword) { throw 'Search 需要 -Keyword 参数' }
    if (-not (Test-Path $MsgFile)) { Write-Host '尚无归档数据，先执行 -Action Fetch'; return }
    $hits = 0
    Write-Host "=== 检索关键词: $Keyword ==="
    foreach ($line in [System.IO.File]::ReadLines($MsgFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch [regex]::Escape($Keyword)) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $hits++
        $ts = $o.create_time
        $when = if ($ts -match '^\d+$') { ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$ts)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
        $nick = if ($o.sender_nick) { $o.sender_nick } else { $o.sender_uid }
        Write-Host ("[{0}] cid={1} from={2}" -f $when, $o.cid, $nick)
        Write-Host ("    {0}" -f $o.content)
    }
    Write-Host "=== 命中 $hits 条 ==="
}

function Invoke-Stats {
    if (-not (Test-Path $MsgFile)) { Write-Host '尚无归档数据'; return }
    $total = 0; $cidSet = @{}; $senderSet = @{}; $earliest = $null; $latest = $null
    foreach ($line in [System.IO.File]::ReadLines($MsgFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $total++
        if ($o.cid) { $cidSet[[string]$o.cid] = 1 }
        if ($o.sender_uid) { $senderSet[[string]$o.sender_uid] = 1 }
        $t = [string]$o.create_time
        if ($t -match '^\d+$') {
            $v = [long]$t
            if ($null -eq $earliest -or $v -lt $earliest) { $earliest = $v }
            if ($null -eq $latest   -or $v -gt $latest)   { $latest = $v }
        }
    }
    function Fmt($ms) { if ($ms) { ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' } }
    Write-Host '=== 归档统计 ==='
    Write-Host ("消息总数   : {0}" -f $total)
    Write-Host ("涉及会话   : {0}" -f $cidSet.Count)
    Write-Host ("涉及发送者 : {0}" -f $senderSet.Count)
    Write-Host ("最早消息   : {0}" -f (Fmt $earliest))
    Write-Host ("最新消息   : {0}" -f (Fmt $latest))
    Write-Host ("数据文件   : {0}" -f $MsgFile)
    if (Test-Path $MsgFile) {
        Write-Host ("文件大小   : {0:N0} bytes" -f (Get-Item $MsgFile).Length)
    }
    if (Test-Path $StateFile) {
        Write-Host '--- state.json ---'
        Get-Content $StateFile -Raw -Encoding UTF8
    }
}

# ---------------------------------------------------------------- 主流程
switch ($Action) {
    'Init' {
        if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
        if (-not (Test-Path $MsgFile)) { [System.IO.File]::WriteAllText($MsgFile, '', (New-Object Text.UTF8Encoding($false))) }
        $pidNow = Get-McpReady
        Write-Log "初始化完成。归档目录: $Root，MCP pid=$pidNow"
        $null = Update-Conversations
        Save-State
    }
    'Rescan' { $null = Get-McpReady; $null = Update-Conversations; Save-State }
    'Fetch'  { Invoke-Fetch }
    'Listen' { Invoke-Listen }
    'Search' { Invoke-Search }
    'Stats'  { Invoke-Stats }
}
