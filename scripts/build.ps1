<#
.SYNOPSIS
  一键编译全部注入探针。

.DESCRIPTION
  用 MSVC (cl.exe) 编译 scripts/ 下的 C++ 探针，输出到 build/。
  需要已安装 Visual Studio（含 C++ 工具链）。

.EXAMPLE
  .\build.ps1
  .\build.ps1 -OutDir D:\build
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\build')
)

$ErrorActionPreference = 'Stop'

function Find-Vcvars {
    $candidates = @(
        'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat',
        'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat',
        'C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
        'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Auxiliary\Build\vcvars64.bat'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    # fallback: search
    $found = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio','C:\Program Files (x86)\Microsoft Visual Studio' `
                -Recurse -Filter 'vcvars64.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

$vcvars = Find-Vcvars
if (-not $vcvars) {
    Write-Host '未找到 vcvars64.bat。请安装 Visual Studio 的「使用 C++ 的桌面开发」工作负载。' -ForegroundColor Red
    exit 1
}
Write-Host "使用工具链: $vcvars"

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path $OutDir).Path

$sources = Get-ChildItem $PSScriptRoot -Filter '*.cpp' | Sort-Object Name
if ($sources.Count -eq 0) { Write-Host '未找到 .cpp 源文件'; exit 1 }

$failed = @()
foreach ($cpp in $sources) {
    $out = Join-Path $OutDir ($cpp.BaseName + '.dll')
    Write-Host ""
    Write-Host "=== 编译 $($cpp.Name) -> $(Split-Path $out -Leaf) ==="
    $cmd = "`"$vcvars`" >nul 2>&1 && cd /d `"$($cpp.DirectoryName)`" && cl /nologo /LD /O2 /EHa `"$($cpp.Name)`" /link /DLL /OUT:`"$out`" ws2_32.lib"
    $log = cmd /c $cmd 2>&1
    $log | Select-Object -Last 3 | ForEach-Object { Write-Host "   $_" }
    if (Test-Path $out) {
        Write-Host "   OK -> $out" -ForegroundColor Green
    } else {
        Write-Host "   编译失败" -ForegroundColor Red
        $failed += $cpp.Name
    }
}

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "全部编译成功，输出目录: $OutDir" -ForegroundColor Green
} else {
    Write-Host "以下源文件编译失败: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
