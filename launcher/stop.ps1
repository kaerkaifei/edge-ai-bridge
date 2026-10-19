<#
.SYNOPSIS
    关掉由 launch_hidden.ps1 拉起来的那个 Edge 实例（以及可选的桥接服务）。

.DESCRIPTION
    只按 user-data-dir 精确匹配进程命令行，绝不碰你日常使用的 Edge。
    这一点很重要：按进程名杀 msedge.exe 会把你正在用的浏览器一起干掉。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\stop.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\stop.ps1 -StopBridge
#>

[CmdletBinding()]
param(
    [string]$ProfileDir = "",
    [switch]$StopBridge,
    [int]$Port = 8800
)

$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $PSScriptRoot
if (-not $ProfileDir) { $ProfileDir = Join-Path $Root ".profile" }

$profileFull = [System.IO.Path]::GetFullPath($ProfileDir)

Write-Host "[bridge] 目标 profile: $profileFull" -ForegroundColor Cyan

# 按命令行匹配：只要命令行里出现这个 profile 目录，就是我们拉起来的实例
$targets = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profileFull) }

if (-not $targets) {
    Write-Host "[bridge] 没有找到匹配的 Edge 进程。" -ForegroundColor Yellow
} else {
    Write-Host "[bridge] 找到 $($targets.Count) 个进程，正在结束..." -ForegroundColor Cyan
    foreach ($p in $targets) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        } catch {
            Write-Host "  PID $($p.ProcessId) 结束失败：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Start-Sleep -Milliseconds 600
}

# 清掉 PID 文件
$pidFile = Join-Path $profileFull "bridge-edge.pid"
if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }

if ($StopBridge) {
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conns) {
        foreach ($c in $conns) {
            $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like "python*") {
                Write-Host "[bridge] 停止桥接服务 PID $($proc.Id)" -ForegroundColor Cyan
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Host "[bridge] 端口 $Port 上没有监听进程。" -ForegroundColor Yellow
    }
}

Write-Host "[bridge] 完成。" -ForegroundColor Green
