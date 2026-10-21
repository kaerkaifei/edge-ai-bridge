<#
.SYNOPSIS
    检查「即将同步的那个浏览器」到底有没有加载 Edge AI Bridge 扩展。

.DESCRIPTION
    为什么需要这个检查：
      桥接服务在跑，不等于你要同步的浏览器装了插件。三种错位的表现一模一样
      ——「AI 发了命令，没有执行」：
        1. 插件只装在 Chrome，而你要同步的是 Edge；
        2. 浏览器开着，但这次是正常启动的，带插件的那次启动早结束了；
        3. 插件加载了，但端口 / 令牌和桥接服务对不上，心跳发不出去。
      光看「有没有实例在线」判断不了 1 和 2，因为实例可能来自另一个浏览器。
      所以这里同时看两件事：进程命令行里有没有 --load-extension，
      以及桥接 /health 里有没有「这个浏览器」的心跳。

    本脚本只读，不动浏览器、不动配置。

    退出码：
      0 = 已就绪（插件已加载，且桥接里能看到这个浏览器）
      1 = 环境不对（找不到浏览器 / 扩展目录不完整）
      2 = 插件没装或没加载 → 跑 install_extension.ps1 一键安装

.PARAMETER Browser
    auto（默认，优先挑正在运行的那个）/ edge / chrome。

.PARAMETER Port
    桥接端口。0 = 先读 extension/config.json，再退回 8800。

.PARAMETER Token
    桥接令牌。空 = 读运行数据目录的 token.txt（旧版在 server\token.txt）或环境变量 BRIDGE_TOKEN。

.PARAMETER ExePath
    强制指定浏览器 exe（企业版 / 绿色版 / 非标准安装位置）。

.PARAMETER Json
    输出机器可读的 JSON（给其它脚本用）。

.PARAMETER Quiet
    不打印内容，只看退出码。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\check_extension.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\check_extension.ps1 -Browser chrome -Json
#>

[CmdletBinding()]
param(
    [ValidateSet("auto", "edge", "chrome")]
    [string]$Browser = "auto",
    [int]$Port = 0,
    [string]$Token = "",
    [string]$ExtensionPath = "",
    [string]$ExePath = "",
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib_browser.ps1")

if (-not $ExtensionPath) { $ExtensionPath = Join-Path $Root "extension" }

function Say([string]$m) { if (-not $Quiet -and -not $Json) { Write-Host $m } }
function SayOk([string]$m) { if (-not $Quiet -and -not $Json) { Write-Host "  [OK]   $m" -ForegroundColor Green } }
function SayWarn([string]$m) { if (-not $Quiet -and -not $Json) { Write-Host "  [注意] $m" -ForegroundColor Yellow } }
function SayBad([string]$m) { if (-not $Quiet -and -not $Json) { Write-Host "  [缺口] $m" -ForegroundColor Red } }

$result = [ordered]@{
    state           = "error"
    exitCode        = 1
    browser         = $null
    displayName     = $null
    exe             = $null
    running         = $false
    processCount    = 0
    extensionPath   = $ExtensionPath
    extensionLoaded = $false
    bridge          = $null
    hints           = @()
}

if (-not (Test-Path (Join-Path $ExtensionPath "manifest.json"))) {
    $result.state = "error"
    $result.hints = @("扩展目录不完整：$ExtensionPath")
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { SayBad "扩展目录不完整：$ExtensionPath"; Say "  仓库可能没解压完整。" }
    exit 1
}

$target = $null
try {
    $target = Get-SyncTarget -Browser $Browser -ExePath $ExePath
} catch {
    $result.hints = @($_.Exception.Message)
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { SayBad $_.Exception.Message }
    exit 1
}

if (-not $target) {
    $result.hints = @("没有找到受支持的浏览器（Microsoft Edge / Google Chrome）")
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else {
        Say "没有找到受支持的浏览器。"
        Say "  Firefox 不在支持范围内：扩展用的全是 Chromium 的 MV3 API。"
        Say "  如果用绿色版/企业版，可以用 -ExePath 指定 msedge.exe 或 chrome.exe。"
    }
    exit 1
}

# ---------- 端口与令牌 ----------
if (-not $Port) {
    $cfg = Get-ExtensionConfig -ExtensionPath $ExtensionPath
    if ($cfg -and $cfg.port) { $Port = [int]$cfg.port }
}
if (-not $Port) { $Port = 8800 }
$Token = Get-BridgeToken -Root $Root -Token $Token

# ---------- 探测 ----------
$loaded = Test-ExtensionLoaded -ExtensionPath $ExtensionPath -Processes $target.Processes
$portOpen = Test-PortOpen $Port 250
$health = $null
if ($portOpen) { $health = Get-BridgeHealth -Port $Port -Token $Token }

$onlineBrowsers = @()
$instances = @()
if ($health) {
    # 自己按 age_ms 过滤，不直接信 /health 顶层的 browsers —— 万一连的是没升级的
    # 旧桥接，那里面会混着几小时前的残影（0.2.1 的教训：残影会让安装脚本假成功）。
    $onlineBrowsers = @(Get-FreshBrowsers $health 60000)
    $instances = @($health.instances_detail | Where-Object { $null -eq $_.age_ms -or [int]$_.age_ms -lt 60000 })
}
$connected = ($onlineBrowsers -contains $target.Name)
$anyInstance = ($instances.Count -gt 0)

$result.browser = $target.Name
$result.displayName = $target.DisplayName
$result.exe = $target.Exe
$result.running = $target.Running
$result.processCount = @($target.Processes).Count
$result.extensionLoaded = $loaded
$result.canAutoLoad = (Test-CanLoadExtensionFromCommandLine $target.Exe)
$result.bridge = [ordered]@{
    port       = $Port
    up         = $portOpen
    authorized = ($null -ne $health)
    browsers   = $onlineBrowsers
    instances  = $instances
}

# ---------- 判定 ----------
$state = "missing"
$code = 2
$hints = New-Object System.Collections.ArrayList

if ($loaded -and $connected) {
    $state = "ready"; $code = 0
} elseif ($loaded -and -not $connected) {
    if (-not $portOpen) {
        $state = "bridge-down"; $code = 1
        [void]$hints.Add("插件已加载，但桥接服务没在 127.0.0.1:$Port 监听。")
        [void]$hints.Add("跑一下 start.cmd，或：powershell -ExecutionPolicy Bypass -File launcher\launch_hidden.ps1")
    } elseif (-not $health) {
        $state = "auth-failed"; $code = 1
        [void]$hints.Add("端口 $Port 在监听，但用当前令牌换不到 /health —— 可能是别的服务占着这个端口，或令牌不对。")
        [void]$hints.Add("确认 token.txt 和扩展里的 config.json 是同一份；端口冲突时用 -Port 换一个。")
    } elseif ($anyInstance -and -not $connected) {
        $state = "other-browser-online"; $code = 1
        [void]$hints.Add("桥接在线的是：$($onlineBrowsers -join ', ')；$($target.DisplayName) 本身没连上。")
        [void]$hints.Add("插件可能只装在另一个浏览器里（或者装在另一个 profile 里）。")
    } else {
        $state = "no-heartbeat"; $code = 1
        # 「命令行带了 --load-extension」和「扩展真的生效」是两回事：
        # 0.2.1 实测，profile 里开发者模式没开时浏览器会把解压扩展静默禁用，
        # 命令行里参数还在，心跳就是不会有。先看一眼禁用原因。
        $reason = Get-ExtensionDisableReason $target.Name $ExtensionPath
        if ($reason -ne 0) {
            [void]$hints.Add("扩展被浏览器禁用了（disable_reasons=$reason）。")
            [void]$hints.Add("  最常见原因：$($target.Name)://extensions 里的「开发人员模式」没开。")
            [void]$hints.Add("  修复：powershell -ExecutionPolicy Bypass -File launcher\install_extension.ps1 -Browser $($target.Name)")
        } else {
            [void]$hints.Add("插件已加载，但一次心跳都没发出来。常见原因：")
            [void]$hints.Add("  · extension\config.json 里的端口/令牌和桥接服务对不上")
            [void]$hints.Add("  · 扩展在 $($target.Name)://extensions 里被禁用或报错")
            [void]$hints.Add("  · 无头模式下扩展没起来（老版本浏览器不支持）")
        }
    }
} elseif (-not $loaded -and $connected) {
    # 心跳在，说明它确实加载了；只是进程命令行看不出来（开机自启、启动器包装等情况）
    $state = "ready-partial"; $code = 0
    [void]$hints.Add("桥接能看到 $($target.DisplayName) 的心跳，但进程命令行里没找到 --load-extension。")
    [void]$hints.Add("功能上没问题，只是下次从图标直接启动时插件可能不会加载。")
} else {
    $state = "missing"; $code = 2
    $instState = Get-InstallState
    if ($instState -and $instState.browser -eq $target.Name) {
        $when = if ($instState.installedAt) { $instState.installedAt } elseif ($instState.checkedAt) { $instState.checkedAt } else { '之前' }
        if ($instState.mode -eq 'manual-unpacked') {
            [void]$hints.Add("上次（$when）准备过手动安装，但 chrome://extensions 里还没加载这个扩展。")
        } elseif ($instState.installed -eq $true) {
            [void]$hints.Add("上次安装过（$when），但这次浏览器是正常启动的，插件没跟上来。")
        } else {
            [void]$hints.Add("上次（$when）跑过安装脚本，但插件没跟上来。")
        }
    }
    [void]$hints.Add("$($target.DisplayName) 这次启动没有加载插件。")
    if (-not (Test-CanLoadExtensionFromCommandLine $target.Exe)) {
        # Chrome 品牌版：命令行加载被硬禁，只能手动装一次（装完持久保存）
        [void]$hints.Add("Chrome 品牌版不支持命令行加载扩展（--load-extension 会被忽略），需要手动装一次：")
        [void]$hints.Add("  1) 地址栏打开 chrome://extensions")
        [void]$hints.Add("  2) 右上角打开「开发者模式」")
        [void]$hints.Add("  3) 「加载已解压的扩展程序」→ 选 $ExtensionPath")
        [void]$hints.Add("装一次就持久保存，以后正常启动浏览器插件也在。")
        [void]$hints.Add("辅助安装：powershell -ExecutionPolicy Bypass -File launcher\install_extension.ps1 -Browser $($target.Name)")
    } else {
        [void]$hints.Add("一键安装：")
        [void]$hints.Add("  powershell -ExecutionPolicy Bypass -File launcher\install_extension.ps1")
        [void]$hints.Add("  （或者直接双击仓库根目录的 安装插件.cmd）")
    }
}

$result.state = $state
$result.exitCode = $code
$result.hints = @($hints)

# ---------- 输出 ----------
if ($Json) {
    $result | ConvertTo-Json -Depth 6
    exit $code
}

Say ""
Say "[check] 即将同步的浏览器：$($target.DisplayName)"
Say "        $($target.Exe)"
if ($target.Running) { Say "        正在运行（$($result.processCount) 个进程）" } else { Say "        当前没在运行" }
Say ""
if ($portOpen) {
    if ($health) { Say "[check] 桥接服务：127.0.0.1:$Port —— 在位（版本 $($health.version)）" }
    else { Say "[check] 桥接服务：127.0.0.1:$Port —— 端口在监听，但令牌对不上" }
} else {
    Say "[check] 桥接服务：127.0.0.1:$Port —— 没起"
}
if ($anyInstance) {
    $desc = @($instances | ForEach-Object { "{0}（{1}）" -f $_.iid, $_.browser }) -join "、"
    Say "[check] 在线实例：$desc"
} else {
    Say "[check] 在线实例：无"
}
Say ""

switch ($state) {
    "ready" {
        SayOk "$($target.DisplayName) 已加载插件，桥接也能看到它的心跳。"
        SayOk "可以用 client.py 发命令了。"
    }
    "ready-partial" {
        SayOk "$($target.DisplayName) 的心跳在桥接里，功能可用。"
    }
    "missing" {
        SayBad "$($target.DisplayName) 没有加载 Edge AI Bridge 扩展"
    }
    "bridge-down" {
        SayBad "插件加载了，但桥接服务没起来"
    }
    "auth-failed" {
        SayBad "桥接端口在，但令牌/服务对不上"
    }
    "other-browser-online" {
        SayBad "$($target.DisplayName) 没连上（在线的是 $($onlineBrowsers -join ', ')）"
    }
    "no-heartbeat" {
        SayBad "插件加载了，但心跳发不出来"
    }
}
if ($state -ne "ready") {
    foreach ($h in $hints) { Say "        $h" }
}
Say ""
exit $code
