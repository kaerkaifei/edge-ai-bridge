<#
.SYNOPSIS
    带插件启动你日常用的浏览器（桌面快捷方式指向的就是它）。

.DESCRIPTION
    和正常启动浏览器相比，只多了一个开关：

        --load-extension=<仓库>\extension

    没有独立 profile、没有独立窗口、没有无头模式 —— 用的还是你原来的
    登录态、书签、扩展。装上插件之后，AI 才能接管你平时真的在用的那个浏览器。

    为什么要单独一个脚本，而不是让你每次手打：
      --load-extension 只在启动那一刻生效，且不会被记住。
      从任务栏 / 开始菜单正常启动，插件不会出现；从这个脚本启动它才在。
      桌面快捷方式就是指向这里（或直接用同样的参数指向 exe）。

    Chrome 例外：品牌版 Chrome 从 137 起忽略 --load-extension
    （日志原文：--load-extension is not allowed in Google Chrome, ignoring.），
    默认 profile 下 CDP 调试端口也被拒，所以 Chrome 只能手动装一次；
    手动装的解压扩展会持久保存，装完之后正常启动也在。

.PARAMETER Browser
    auto（默认）/ edge / chrome。

.PARAMETER Url
    启动后顺带打开的地址，可空。

.PARAMETER Port
    桥接端口。0 = 读 extension\config.json，再退回 8800。

.PARAMETER NoBridge
    不拉起桥接服务（你已经用 start.cmd 起过了）。

.PARAMETER NoRestoreSession
    不恢复上次的标签页。

.PARAMETER Yes
    浏览器正在运行但没带插件时，不询问，直接关掉重开。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\launch_with_extension.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\launch_with_extension.ps1 -Browser chrome -Url https://example.com
#>

[CmdletBinding()]
param(
    [ValidateSet("auto", "edge", "chrome")]
    [string]$Browser = "auto",
    [string]$Url = "",
    [string]$ExtensionPath = "",
    [string]$ExePath = "",
    [int]$Port = 0,
    [string]$Token = "",
    [switch]$NoRestoreSession,
    [switch]$NoBridge,
    [switch]$Yes
)

$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib_browser.ps1")

if (-not $ExtensionPath) { $ExtensionPath = Join-Path $Root "extension" }
$ServerDir = Join-Path $Root "server"

function Step([string]$m) { Write-Host "[launch] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }

if (-not (Test-Path (Join-Path $ExtensionPath "manifest.json"))) {
    Write-Host "扩展目录不完整：$ExtensionPath" -ForegroundColor Red
    exit 1
}

$target = Get-SyncTarget -Browser $Browser -ExePath $ExePath
if (-not $target) {
    Write-Host "没找到受支持的浏览器（Microsoft Edge / Google Chrome）。" -ForegroundColor Red
    exit 1
}

$token = Get-BridgeToken -Root $Root -Token $Token
if (-not $Port) {
    $cfg = Get-ExtensionConfig -ExtensionPath $ExtensionPath
    if ($cfg -and $cfg.port) { $Port = [int]$cfg.port }
}
if (-not $Port) { $Port = 8800 }

if (-not $NoBridge -and -not (Test-PortOpen $Port 250)) {
    Step "桥接服务没在跑，后台拉起（127.0.0.1:$Port）"
    try {
        $null = Start-BridgeService -Port $Port -Token $token -ServerDir $ServerDir
    } catch {
        Warn "桥接没起来：$($_.Exception.Message)。浏览器照样启动，只是 AI 暂时发不出命令。"
    }
}

# 端口/令牌对齐：扩展读的是这个文件，对不上就安静地不发心跳
$null = Set-ExtensionConfig -ExtensionPath $ExtensionPath -Port $Port -Token $token

# ---------- 先看现在到底什么状态 ----------
$loaded = Test-ExtensionLoaded -ExtensionPath $ExtensionPath -Processes @($target.Processes)
$health = Get-BridgeHealth -Port $Port -Token $token
$connected = $false
if ($health) { $connected = (@($health.browsers) -contains $target.Name) }

if ($connected -and -not $target.Running) {
    # /health 里的实例有 30 秒左右的「还活着」窗口，进程已经没了但记录还在
    $connected = $false
}

if ($connected) {
    Ok "$($target.DisplayName) 已经带着插件在跑，桥接也能看到它的心跳。"
    Write-Host "       不用再启动一次。"
    exit 0
}

# ---------- 品牌版 Chrome：命令行装不了，只能手动 ----------
if (-not (Test-CanLoadExtensionFromCommandLine $target.Exe)) {
    Step "$($target.DisplayName) 不能用命令行自动加载扩展（品牌版限制）"
    Write-Host ""
    Write-Host "  Chrome 从 137 起会忽略 --load-extension，实测日志原文：" -ForegroundColor Yellow
    Write-Host "    WARNING:chrome\browser\extensions\extension_service.cc:423]" -ForegroundColor DarkGray
    Write-Host "    --load-extension is not allowed in Google Chrome, ignoring." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  请手动装一次（只需一次，装完会持久保存，以后正常启动也在）：" -ForegroundColor Cyan
    Write-Host "    1) 地址栏打开 chrome://extensions"
    Write-Host "    2) 右上角打开「开发者模式」"
    Write-Host "    3) 点「加载已解压的扩展程序」，选这个目录："
    Write-Host "       $ExtensionPath"
    try { Set-Clipboard -Value $ExtensionPath; Write-Host "       （路径已复制到剪贴板）" } catch { }
    Write-Host ""
    Write-Host "  装完验证：" -ForegroundColor Cyan
    Write-Host "    powershell -ExecutionPolicy Bypass -File launcher\check_extension.ps1 -Browser $($target.Name)"
    Write-Host ""
    if ($target.Running) {
        Write-Host "  浏览器现在开着：直接在地址栏输入 chrome://extensions 就能手动装。" -ForegroundColor Yellow
    } else {
        Step "顺手把浏览器打开，方便你手动装"
        try {
            if ($Url) { Start-Process -FilePath $target.Exe -ArgumentList $Url | Out-Null }
            else { Start-Process -FilePath $target.Exe | Out-Null }
        } catch { }
    }
    exit 4
}

# ---------- Edge：已经在跑但没带插件 → 必须重启，开关只在启动那刻生效 ----------
if ($target.Running -and -not $loaded) {
    Warn "$($target.DisplayName) 正在运行，但这次启动没带插件（命令行里没有 --load-extension）。"
    Write-Host "       需要关掉它再重开一次；会加 --restore-last-session，标签页会回来。"
    $go = $Yes
    if (-not $go) {
        $answer = Read-Host "       现在关掉重开吗？[Y/n]"
        if ($answer -and $answer.Trim().ToLowerInvariant().StartsWith("n")) {
            Write-Host "已取消。" -ForegroundColor Yellow
            exit 3
        }
    }
    Step "关闭 $($target.DisplayName)"
    if (-not (Close-BrowserProcesses $target.Exe 15)) {
        Write-Host "关不掉，可能被其它进程占着。请手动完全退出后再试。" -ForegroundColor Red
        exit 1
    }
    Ok "已关闭"
}

# ---------- 启动 ----------
$launchArgs = Get-ExtensionLaunchArgs -ExtensionPath $ExtensionPath -RestoreSession:(-not $NoRestoreSession)
if ($Url) { $launchArgs += $Url }

Step "启动 $($target.DisplayName)（带插件）"
try {
    Start-Process -FilePath $target.Exe -ArgumentList $launchArgs | Out-Null
} catch {
    Write-Host "启动失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Step "等待插件连上桥接（最多 25 秒）"
$deadline = (Get-Date).AddSeconds(25)
$ok = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $h = Get-BridgeHealth -Port $Port -Token $token
    if ($h -and (@($h.browsers) -contains $target.Name)) { $ok = $true; break }
}

if (-not $ok) {
    Write-Host "等了 25 秒，桥接里还是没看到 $($target.DisplayName) 的心跳。" -ForegroundColor Red
    Write-Host "  排查：powershell -ExecutionPolicy Bypass -File launcher\check_extension.ps1"
    Write-Host "  日志：$(Join-Path $ServerDir 'bridge.log')"
    exit 1
}

Ok "插件已连上桥接：http://127.0.0.1:$Port"
Write-Host ""
Write-Host "提示：插件只跟着这一次启动走。" -ForegroundColor Yellow
Write-Host "      从任务栏正常启动的话插件会缺席，到时候再跑一次本脚本即可。" -ForegroundColor Yellow
exit 0
