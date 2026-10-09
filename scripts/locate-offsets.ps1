<#
.SYNOPSIS
  偏移定位：为一个新的钉钉版本重新定位 MCP 启动相关的关键地址。

.DESCRIPTION
  封装三个探索式探针，自动完成偏移定位：

    探针18  在 MainFrame.dll 内找 MCP 字符串，并扫描代码段找 RIP-relative 引用
    探针19  用 int3 填充识别函数边界，并找 call 指令定位调用点
    探针20  dump 调用点附近字节，识别 test / jz / mov ecx / call 模式

  输出为可直接填入 dtinject21.cpp 的常量。

  原理：MCP 启动逻辑形如

      call <flag查询>          ; 读 general.enable_mcp_server
      test bl, bl
      jz   <跳过>              ; 关闭时不进入启动
      mov  ecx, <端口>          ; 端口常量
      call <启动例程>

  把 jz 改成 nop nop，再调用启动例程，即可绕过开关。

.PARAMETER MainFrameDll
  MainFrame.dll 的完整路径（安装目录下）

.PARAMETER ProcessName
  目标进程名，默认 CMSDING

.EXAMPLE
  .\locate-offsets.ps1 -MainFrameDll 'C:\Program Files (x86)\CMSDING\main\current\MainFrame.dll'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MainFrameDll,
    [string]$ProcessName = 'CMSDING',
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\build'),
    [string]$LogDir = (Join-Path $PSScriptRoot '..\logs')
)

$ErrorActionPreference = 'Stop'

function Find-MainPid {
    param([string]$Name)
    $cands = Get-CimInstance Win32_Process -Filter "Name='$Name.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -notmatch '--type=' }
    foreach ($c in $cands) {
        $hasFrame = $false
        try {
            $hasFrame = [bool]((Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue).Modules |
                               Where-Object { $_.ModuleName -eq 'MainFrame.dll' })
        } catch { }
        if ($hasFrame) { return $c.ProcessId }
    }
    return $null
}

if (-not (Test-Path $MainFrameDll)) { throw "找不到 MainFrame.dll: $MainFrameDll" }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# --- 1. 先做静态探测：确认该版本是否含 MCP ---
Write-Host '=== 步骤 0：静态确认 MCP 是否存在 ==='
$bytes = [System.IO.File]::ReadAllBytes($MainFrameDll)
$ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
$probes = @(
    'enable_mcp_server',
    'DingTalk Integrated MCP Server',
    'DingTalkMcpServer started successfully on port ',
    'SendMessageTool registered successfully'
)
$allFound = $true
foreach ($p in $probes) {
    $i = $ascii.IndexOf($p)
    if ($i -ge 0) {
        Write-Host ("  [OK]   {0,-46} fileOffset=0x{1:X}" -f $p, $i)
    } else {
        Write-Host ("  [MISS] {0}" -f $p) -ForegroundColor Yellow
        $allFound = $false
    }
}
$vi = (Get-Item $MainFrameDll).VersionInfo
Write-Host ("  MainFrame.dll 版本: {0}" -f $vi.FileVersion)

if (-not $allFound) {
    Write-Host ''
    Write-Host '该版本缺少 MCP 相关字符串，说明钉钉基线早于 MCP 引入版本，无法启用。' -ForegroundColor Red
    exit 2
}

# --- 2. 运行探针（需注入目标进程） ---
Write-Host ''
Write-Host '=== 步骤 1：注入探针定位引用 ==='
$pidTarget = Find-MainPid -Name $ProcessName
if (-not $pidTarget) {
    Write-Host "未找到加载了 MainFrame.dll 的 $ProcessName 主进程。请先启动客户端。" -ForegroundColor Red
    exit 3
}
Write-Host "目标主进程 pid = $pidTarget"

$injector = Join-Path $PSScriptRoot 'inject.ps1'
if (-not (Test-Path $injector)) { throw "找不到注入器: $injector" }

foreach ($probe in 18, 19, 20) {
    $dll = Join-Path $BuildDir "dtinject$probe.dll"
    if (-not (Test-Path $dll)) {
        Write-Host "  跳过探针 $probe（未编译：$dll）" -ForegroundColor Yellow
        continue
    }
    Write-Host ""
    Write-Host "--- 运行探针 $probe ---"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $injector -TargetPid $pidTarget -DllPath $dll 2>&1 |
        Select-Object -Last 2 | ForEach-Object { Write-Host "   $_" }
    Start-Sleep -Seconds 8

    # 收集探针日志
    $probeLog = [System.IO.Path]::ChangeExtension($dll, '.log')
    if (Test-Path $probeLog) {
        Copy-Item $probeLog (Join-Path $LogDir "probe$probe.log") -Force
        Write-Host "   日志已存: $(Join-Path $LogDir "probe$probe.log")"
    }
}

Write-Host ''
Write-Host '=== 步骤 2：从探针日志提取偏移 ==='
$p20 = Join-Path $LogDir 'probe20.log'
if (Test-Path $p20) {
    Write-Host '--- probe20 结果（flag 检查点与启动例程）---'
    Get-Content $p20 | Where-Object { $_ -match 'call at|likely entry|dump module offsets' } |
        Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host '判读方法：' -ForegroundColor Cyan
    Write-Host '  1) 在 dump 中找到形如 E8 xx xx xx xx（call）、84 DB（test bl,bl）、74 xx（jz）的序列'
    Write-Host '  2) 该 jz 的地址 + 后续 mov ecx 的立即数即端口常量'
    Write-Host '  3) 该序列中 call 的目标地址即“启动例程”偏移'
    Write-Host '  4) 把 "patch 点" 与 "启动例程" 两个偏移填入 dtinject21.cpp 顶部常量'
} else {
    Write-Host "未找到 $p20，请确认探针已运行" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== 步骤 3：核对 dtinject21.cpp 中的常量 ==='
$src21 = Join-Path $PSScriptRoot 'dtinject21.cpp'
if (Test-Path $src21) {
    Get-Content $src21 | Select-String -Pattern 'kPatchOffset|kStartRoutineOffset|kPort' |
        Select-Object -First 6 | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
}
Write-Host ''
Write-Host '完成。若偏移与目标版本不符，请按上述判读结果修改 dtinject21.cpp 后重新编译。' -ForegroundColor Green
