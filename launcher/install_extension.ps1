<#
.SYNOPSIS
    一键给「即将同步的浏览器」装上 Edge AI Bridge 扩展，并当场验证它连上了桥接。

.DESCRIPTION
    支持两种浏览器，路径不一样，原因写清楚：

    Microsoft Edge —— 可以真的「一键」：
      1. 确认桥接服务在跑，把端口 + 令牌写进 extension\config.json
      2. 检查目标浏览器是不是已经带着插件在跑了 —— 是的话就直接结束
      3. 没装：先礼貌地关掉浏览器（让它自己保存会话），再带 --load-extension 启动，
         加上 --restore-last-session，标签页会原样回来
      4. 轮询 /health，确认「这个浏览器」的心跳真的出现在桥接里
      5. 记下安装状态，并在桌面建一个「带插件启动」的快捷方式

    Google Chrome —— 只能「半自动」，且只需手动一次：
      品牌版 Chrome 从 137 起直接忽略 --load-extension（实测日志：
      --load-extension is not allowed in Google Chrome, ignoring.），
      默认 profile 下 CDP 调试端口也被拒，没法像 Edge 那样重启装。
      脚本退化为：检测 → 说明 → 复制扩展目录到剪贴板 → 打开 chrome://extensions。
      手动装的解压扩展会持久保存，装完以后正常启动浏览器插件也在（不需要快捷方式）。

    为什么不把 --user-data-dir 指到独立 profile：
      那样确实更干净，但你日常浏览器的登录态、书签、扩展都不会跟过来，
      「同步浏览器状态」这个目的就落空了。这里刻意复用默认 profile，
      代价是 Edge 那条路以后要从快捷方式启动；Chrome 那条路没有这个代价。

    Firefox 不支持：扩展用的是 Chromium 的 MV3 / offscreen API。

.PARAMETER Browser
    auto（默认）/ edge / chrome。

.PARAMETER Port
    桥接端口。0 = 自动：先读 extension\config.json，再退回 8800；
    如果那个端口被别的服务占着且令牌对不上，自动换一个空闲端口。

.PARAMETER Token
    桥接令牌。空 = 读 server\token.txt 或环境变量 BRIDGE_TOKEN。

.PARAMETER ExePath
    强制指定浏览器 exe（企业版 / 绿色版 / 非标准安装位置）。

.PARAMETER Yes
    不询问，直接安装（脚本化 / 无人值守时用）。

.PARAMETER DryRun
    只打印打算做什么，不动浏览器。

.PARAMETER NoShortcut
    不创建桌面快捷方式。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\install_extension.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\install_extension.ps1 -Browser chrome -Yes
#>

[CmdletBinding()]
param(
    [ValidateSet("auto", "edge", "chrome")]
    [string]$Browser = "auto",
    [int]$Port = 0,
    [string]$Token = "",
    [string]$ExtensionPath = "",
    [string]$ExePath = "",
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$NoShortcut
)

$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib_browser.ps1")

if (-not $ExtensionPath) { $ExtensionPath = Join-Path $Root "extension" }
$ServerDir = Join-Path $Root "server"
$ClientPy = Join-Path $Root "examples\client.py"

function Step([string]$m) { Write-Host "[install] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }
function Bad([string]$m) { Write-Host "  [失败] $m" -ForegroundColor Red }

# ---------- 1. 目标浏览器 ----------
if (-not (Test-Path (Join-Path $ExtensionPath "manifest.json"))) {
    Bad "扩展目录不完整：$ExtensionPath"
    exit 1
}

$target = $null
try { $target = Get-SyncTarget -Browser $Browser -ExePath $ExePath } catch {
    Bad $_.Exception.Message
    exit 1
}
if (-not $target) {
    Bad "没找到受支持的浏览器（Microsoft Edge / Google Chrome）。"
    Write-Host "        Firefox 不支持：扩展用的是 Chromium 的 MV3 API。" -ForegroundColor Yellow
    exit 1
}

Step "目标浏览器：$($target.DisplayName)"
Write-Host "        $($target.Exe)"
if ($target.Running) { Write-Host "        当前正在运行（$(@($target.Processes).Count) 个进程）" }

# ---------- 2. 端口 / 令牌 ----------
$token = Get-BridgeToken -Root $Root -Token $Token

if (-not $Port) {
    $cfg = Get-ExtensionConfig -ExtensionPath $ExtensionPath
    if ($cfg -and $cfg.port) { $Port = [int]$cfg.port }
}
if (-not $Port) { $Port = 8800 }

if (Test-PortOpen $Port 250) {
    $h = Get-BridgeHealth -Port $Port -Token $token
    if (-not $h) {
        $free = Find-FreePort ($Port + 1)
        if (-not $free) { Bad "端口 $Port 被占用且对不上令牌，也找不到空闲端口。用 -Port 指定一个。" ; exit 1 }
        Warn "端口 $Port 上跑着别的服务（令牌对不上），改用 $free。"
        $Port = $free
    }
}

# ---------- 3. 桥接服务 ----------
Step "确认桥接服务（127.0.0.1:$Port）"
if (Test-PortOpen $Port 250) {
    Ok "已在运行，复用"
} else {
    if ($DryRun) {
        Ok "会在后台启动 bridge.py --port $Port（dry-run 不实际启动）"
    } else {
        try {
            if (-not (Start-BridgeService -Port $Port -Token $token -ServerDir $ServerDir)) {
                Bad "桥接服务没起来，看日志：$(Join-Path $ServerDir 'bridge.log')"
                exit 1
            }
        } catch {
            Bad $_.Exception.Message
            exit 1
        }
        Ok "已后台启动（日志 server\bridge.log）"
    }
}

# ---------- 4. 写扩展配置 ----------
# 扩展是解压加载的，读的就是 extension\config.json 这个文件；
# 端口/令牌对不上时它不会报错，只会安静地发不出心跳。
if ($DryRun) {
    Ok "会写入 extension\config.json：port=$Port, token=$([bool]$token)"
} else {
    $cfgPath = Set-ExtensionConfig -ExtensionPath $ExtensionPath -Port $Port -Token $token
    Ok "扩展配置已写入：$cfgPath"
    if ($env:http_proxy -or $env:HTTP_PROXY) {
        # 提醒一句：桥接自己是 127.0.0.1，但用户用 client.py 时可能被代理劫持
        Warn "检测到系统代理（$($env:http_proxy)$($env:HTTP_PROXY)），client.py 已内置绕过；自己写脚本记得也绕。"
    }
}

# ---------- 5. 现在到底装没装 ----------
$loaded = Test-ExtensionLoaded -ExtensionPath $ExtensionPath -Processes $target.Processes
$health = Get-BridgeHealth -Port $Port -Token $token
$browsersNow = @()
if ($health -and $health.browsers) { $browsersNow = @($health.browsers | Where-Object { $_ }) }
$connected = ($browsersNow -contains $target.Name)

if ($loaded -and $connected) {
    Ok "$($target.DisplayName) 已经带着插件在跑，桥接也能看到心跳。"
    Write-Host ""
    Write-Host "不需要重复安装。想验证一下：" -ForegroundColor Green
    Write-Host "  python examples\client.py ping"
    exit 0
}
if (-not $loaded -and $connected) {
    Ok "$($target.DisplayName) 心跳在桥接里，功能已经可用。"
    exit 0
}

# ---------- 5.5 品牌版 Chrome：命令行装不了，走手动一次性安装 ----------
# Chrome 137+ 会直接忽略 --load-extension（日志原文下面会打出来），
# 默认 profile 下调试端口也被拒，所以没有「一键重启装插件」这条路。
# 好处是手动装一次就持久保存，以后正常启动浏览器插件也在，不用快捷方式。
if (-not (Test-CanLoadExtensionFromCommandLine $target.Exe)) {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Yellow
    Write-Host " $($target.DisplayName) 检测到没装插件，但它不支持命令行自动安装" -ForegroundColor Yellow
    Write-Host "==============================================================" -ForegroundColor Yellow
    Write-Host " Chrome 从 137 起会忽略 --load-extension，实测日志原文："
    Write-Host "   WARNING:chrome\browser\extensions\extension_service.cc:423]" -ForegroundColor DarkGray
    Write-Host "   --load-extension is not allowed in Google Chrome, ignoring." -ForegroundColor DarkGray
    Write-Host " 默认 profile 下 CDP 调试端口同样被拒，所以这里给不了「一键」，但只需手动一次。"
    Write-Host ""
    Write-Host " 手动安装（约 20 秒，装完持久保存，重启浏览器不丢）：" -ForegroundColor Cyan
    Write-Host "   1) 地址栏打开：chrome://extensions"
    Write-Host "   2) 右上角打开「开发者模式」"
    Write-Host "   3) 点「加载已解压的扩展程序」，选这个目录："
    Write-Host "      $ExtensionPath"
    Write-Host "   4) 回到这里重新检查：powershell -ExecutionPolicy Bypass -File launcher\check_extension.ps1 -Browser $($target.Name)"
    Write-Host ""

    if ($DryRun) {
        Ok "dry-run：以上步骤没有实际执行。"
        exit 4
    }

    try { Set-Clipboard -Value $ExtensionPath; Ok "扩展目录已复制到剪贴板，第 3 步直接粘贴即可" } catch { }

    Step "打开 chrome://extensions 方便你操作"
    try {
        Start-Process -FilePath $target.Exe -ArgumentList "chrome://extensions/" | Out-Null
    } catch {
        Warn "没能自动打开扩展页，手动在地址栏输入 chrome://extensions 即可。"
    }

    $state = [ordered]@{
        browser       = $target.Name
        displayName   = $target.DisplayName
        exe           = $target.Exe
        extensionPath = $ExtensionPath
        port          = $Port
        checkedAt     = (Get-Date).ToString("o")
        mode          = "manual-unpacked"
        installed     = $false
        note          = "Chrome 品牌版禁止命令行加载扩展；需在 chrome://extensions 手动装一次，装完持久保存。"
    }
    try {
        $statePath = Save-InstallState $state
        Ok "安装记录：$statePath"
    } catch { Warn "写安装记录失败：$($_.Exception.Message)" }

    exit 4
}

# ---------- 6. 提醒 + 询问 ----------
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host " 检测到 $($target.DisplayName) 没有加载 Edge AI Bridge 扩展" -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host " 现在这个状态，AI 发的命令不会有人执行（没有插件在浏览器里接手）。"
Write-Host ""
Write-Host " 一键安装会做这些："
Write-Host "   1) 关闭 $($target.DisplayName)（让它自己保存会话，最多等 15 秒）"
Write-Host "   2) 带 --load-extension 重新启动它，并加 --restore-last-session 把标签页恢复"
Write-Host "   3) 轮询桥接 /health，确认这个浏览器的心跳真的出现了"
Write-Host "   4) 在桌面建「带插件启动」的快捷方式（以后从它启动，插件才不会丢）"
Write-Host ""
if (-not $loaded -and -not $connected -and $target.Running) {
    Warn "浏览器正在开着，安装过程中它会关掉再重开一次。"
}
Write-Host ""

if ($DryRun) {
    Ok "dry-run：以上动作不会真的执行。"
    exit 0
}

if (-not $Yes) {
    $answer = Read-Host "要现在安装吗？[Y/n]"
    if ($answer -and $answer.Trim().ToLowerInvariant().StartsWith("n")) {
        Write-Host "已取消。稍后可以再跑一次，或双击 安装插件.cmd。" -ForegroundColor Yellow
        exit 3
    }
}

# ---------- 7. 优雅关闭浏览器 ----------
if ($target.Running) {
    Step "关闭 $($target.DisplayName)（先让它自己保存会话）"
    if (-not (Close-BrowserProcesses $target.Exe 15)) {
        Bad "关不掉 $($target.DisplayName)，可能被其它进程占着。手动完全退出后再试。"
        exit 1
    }
    Ok "浏览器已关闭"
}

# ---------- 8. 带插件重新启动 ----------
# 注意：这里刻意不传 --user-data-dir —— 复用默认 profile，登录态才会跟着走。
# 也不传 --disable-extensions-except：那会把用户自己的其它扩展全禁用。
$launchArgs = Get-ExtensionLaunchArgs -ExtensionPath $ExtensionPath -RestoreSession

Step "带插件启动 $($target.DisplayName)"
try {
    Start-Process -FilePath $target.Exe -ArgumentList $launchArgs | Out-Null
} catch {
    Bad "启动失败：$($_.Exception.Message)"
    exit 1
}

Step "等待插件连上桥接（最多 25 秒）"
$ok = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $h = Get-BridgeHealth -Port $Port -Token $token
    if (-not $h) { continue }
    $bs = @($h.browsers | Where-Object { $_ })
    if ($bs -contains $target.Name) { $ok = $true; break }
}

if (-not $ok) {
    Bad "等了 25 秒，桥接里还是没有 $($target.DisplayName) 的心跳。"
    Write-Host ""
    Write-Host " 排查顺序：" -ForegroundColor Yellow
    Write-Host "   1) 在浏览器地址栏打开 $($target.Name)://extensions ，看「Edge AI Bridge」在不在、有没有被禁用"
    Write-Host "      （不在的话：打开「开发人员模式」→「加载解压缩的扩展」→ 选 $ExtensionPath）"
    Write-Host "   2) 看桥接日志：$(Join-Path $ServerDir 'bridge.log')"
    Write-Host "   3) 确认 extension\config.json 里是 port=$Port"
    Write-Host "   4) 浏览器版本需要 >= 137；老版本 --load-extension 不支持"
    Write-Host "   5) 再跑一次检查：powershell -ExecutionPolicy Bypass -File launcher\check_extension.ps1"
    exit 1
}
Ok "插件已连上桥接"

# ---------- 9. 端到端冒烟（可选，能跑就跑） ----------
$py = Find-PythonExe
if ($py -and (Test-Path $ClientPy)) {
    Step "用 client.py 做一次 ping（证明命令真的有人接手）"
    $out = ""
    try {
        $out = & $py $ClientPy --port $Port --token $token --json ping 2>$null | Out-String
        $ping = $null
        try { $ping = $out | ConvertFrom-Json } catch { }
        if ($ping -and $ping.pong) { Ok "ping 通了（$($ping.pong)）" } else { Warn "ping 没有返回 pong：$($out.Trim())" }
    } catch {
        Warn "ping 命令没跑起来：$($_.Exception.Message)"
    }
}

# ---------- 10. 记录 + 快捷方式 ----------
$state = [ordered]@{
    browser       = $target.Name
    displayName   = $target.DisplayName
    exe           = $target.Exe
    extensionPath = $ExtensionPath
    port          = $Port
    installedAt   = (Get-Date).ToString("o")
    mode          = "load-extension-command-line"
    note          = "插件不会被持久化；下次启动浏览器请用「带插件启动」的快捷方式，否则插件又会消失。"
}
try {
    $statePath = Save-InstallState $state
    Ok "安装记录：$statePath"
} catch { Warn "写安装记录失败：$($_.Exception.Message)" }

$shortcutPath = $null
if (-not $NoShortcut) {
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $shortcutPath = Join-Path $desktop ("启动 {0}（带 AI 插件）.lnk" -f $target.DisplayName)
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($shortcutPath)
        $sc.TargetPath = $target.Exe
        $sc.Arguments = ($launchArgs -join ' ')
        $sc.WorkingDirectory = Split-Path -Parent $target.Exe
        $sc.Description = "带 Edge AI Bridge 扩展启动 $($target.DisplayName)，供 AI 接管"
        $sc.Save()
        Ok "桌面快捷方式：$shortcutPath"
    } catch {
        Warn "建快捷方式失败（不影响使用）：$($_.Exception.Message)"
    }
}

# ---------- 11. 收尾说明 ----------
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host " 安装完成" -ForegroundColor Green
Write-Host "   浏览器   : $($target.DisplayName)"
Write-Host "   扩展目录 : $ExtensionPath"
Write-Host "   桥接服务 : http://127.0.0.1:$Port"
if ($shortcutPath) { Write-Host "   桌面快捷 : $(Split-Path -Leaf $shortcutPath)" }
Write-Host ""
Write-Host " 试一下：" -ForegroundColor Green
Write-Host "   python examples\client.py ping"
Write-Host "   python examples\client.py open https://example.com"
Write-Host "   python examples\client.py text"
Write-Host ""
Write-Host " 注意：插件的加载开关只在那次启动里有效。" -ForegroundColor Yellow
if ($shortcutPath) {
    Write-Host "       以后请从桌面的「$(Split-Path -Leaf $shortcutPath)」启动浏览器，" -ForegroundColor Yellow
    Write-Host "       从任务栏/开始菜单正常启动的话，插件会再次缺席。" -ForegroundColor Yellow
}
Write-Host "==============================================================" -ForegroundColor Green
exit 0
