<#
.SYNOPSIS
    以「隐形」方式启动一个受 AI 控制的 Edge 实例。

.DESCRIPTION
    做的事情，按顺序：
      1. 找到 msedge.exe
      2. 确认本地桥接服务在跑（不在跑就后台拉起，窗口隐藏）
      3. 把 端口 + 令牌 写进 extension/config.json
      4. 用 --headless=new 启动一个独立的 Edge（独立 user-data-dir，不碰你日常的 Edge）
      5. 记下 PID，方便 stop.ps1 收拾

    默认完全无窗口：--headless=new。
    如果某些场景下扩展在无头模式不工作（老版本 Edge、需要真实 GPU 的页面），
    加 -NoHeadless 会退化成「窗口挪到屏幕外 + 最小化」的伪隐形方案。

.PARAMETER Port
    桥接服务端口，默认 8800。

.PARAMETER NoHeadless
    不用无头模式，改为把窗口挪到虚拟屏幕外（-32000,-32000）。
    进程仍在任务栏，但不会弹到你面前。

.PARAMETER Visible
    正常显示窗口，用于调试 / 首次人工确认扩展是否加载成功。

.PARAMETER Token
    手动指定令牌；不传则自动从运行数据目录的 token.txt 读取（旧版在 server\token.txt）。

.PARAMETER ExtensionPath
    扩展目录，默认仓库下的 extension/。

.PARAMETER ProfileDir
    浏览器用户数据目录，默认 %LOCALAPPDATA%\EdgeAiBridge\profile（可用 BRIDGE_RUNTIME_DIR 改）。
    必须独立，否则会和你日常用的 Edge 抢锁、并且可能污染你的真实配置。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\launch_hidden.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\launch_hidden.ps1 -Visible
#>

[CmdletBinding()]
param(
    [int]$Port = 8800,
    [string]$Token = "",
    [string]$ExtensionPath = "",
    [string]$ProfileDir = "",
    [string]$EdgePath = "",
    [string]$StartUrl = "about:blank",
    [int]$DebugPort = 0,
    [int]$Width = 1440,
    [int]$Height = 900,
    [switch]$NoHeadless,
    [switch]$Visible,
    [switch]$SkipBridge
)

$ErrorActionPreference = "Stop"

# ---------- 路径解析 ----------

$Root = Split-Path -Parent $PSScriptRoot          # 仓库根目录
# 运行数据（令牌 / 日志 / profile）默认放用户级目录，不跟代码走：
# 代码目录随时可能被移动或重新 clone，而令牌和浏览器 profile 是本机状态，
# 跟着代码走就会出现「换了目录 = 换了令牌 = 插件连不上」。
$RuntimeDir = if ($env:BRIDGE_RUNTIME_DIR) { $env:BRIDGE_RUNTIME_DIR } else { Join-Path $env:LOCALAPPDATA "EdgeAiBridge" }
$LegacyTokenFile = Join-Path $Root "server\token.txt"
if (-not $ExtensionPath) { $ExtensionPath = Join-Path $Root "extension" }
if (-not $ProfileDir)    { $ProfileDir    = Join-Path $RuntimeDir "profile" }
$ServerDir = Join-Path $Root "server"
$TokenFile = if (Test-Path (Join-Path $RuntimeDir "token.txt")) { Join-Path $RuntimeDir "token.txt" } else { $LegacyTokenFile }
$ConfigFile = Join-Path $ExtensionPath "config.json"
$PidFile = Join-Path $ProfileDir "bridge-edge.pid"

function Write-Step($msg) { Write-Host "[bridge] $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "[bridge] $msg" -ForegroundColor Yellow }

# ---------- 找 Edge ----------

function Find-Edge {
    if ($EdgePath -and (Test-Path $EdgePath)) { return $EdgePath }

    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }

    # 再问注册表
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
    )
    foreach ($rp in $regPaths) {
        try {
            $v = (Get-ItemProperty -Path $rp -ErrorAction Stop).'(default)'
            if ($v -and (Test-Path $v)) { return $v }
        } catch { }
    }

    throw "找不到 msedge.exe，请用 -EdgePath 手动指定。"
}

# ---------- 端口探测 ----------

function Test-PortOpen([int]$p, [int]$timeoutMs = 400) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect("127.0.0.1", $p, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ---------- 找 Python ----------

function Find-Python {
    foreach ($name in @("python", "python3", "py")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "找不到 python，请装一个（>=3.8）或把它加进 PATH。"
}

# pythonw.exe 不会创建控制台窗口，比 python.exe + -WindowStyle Hidden 更干净
function Get-PythonW([string]$pythonExe) {
    $dir = Split-Path -Parent $pythonExe
    $w = Join-Path $dir "pythonw.exe"
    if (Test-Path $w) { return $w }
    return $pythonExe
}

# ---------- 1. 确保桥接服务在跑 ----------

$edge = Find-Edge
Write-Step "Edge: $edge"

if (-not $SkipBridge) {
    if (Test-PortOpen $Port) {
        Write-Step "桥接服务已在 127.0.0.1:$Port 运行，复用。"
    } else {
        $python = Find-Python
        $pythonw = Get-PythonW $python
        $logOut = Join-Path $RuntimeDir "bridge.log"
        if (-not (Test-Path $RuntimeDir)) { New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null }
        Write-Step "桥接服务未启动，后台拉起（无窗口）..."

        # 注意：这里刻意不用 -RedirectStandardOutput。
        # 系统里同时存在 http_proxy / HTTP_PROXY 时，Start-Process 的重定向
        # 会抛 "字典键重复" 的 ArgumentException，改用 --log 让进程自己写文件。
        $argList = @((Join-Path $ServerDir "bridge.py"), "--port", "$Port", "--log", $logOut)
        if ($Token) { $argList += @("--token", $Token) }

        $quoted = ($argList | ForEach-Object {
            if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
        }) -join ' '

        Start-Process -FilePath $pythonw `
            -ArgumentList $quoted `
            -WorkingDirectory $ServerDir `
            -WindowStyle Hidden | Out-Null

        # 最多等 8 秒
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline) {
            if (Test-PortOpen $Port 200) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not (Test-PortOpen $Port 200)) {
            throw "桥接服务没起来，看日志：$logOut"
        }
        Write-Step "桥接服务已就绪（日志 $logOut）"
    }
}

# ---------- 2. 拿令牌 ----------

if (-not $Token) {
    if (Test-Path $TokenFile) {
        $Token = (Get-Content $TokenFile -Raw).Trim()
    }
}
if (-not $Token) {
    Write-Warn2 "没有令牌（$TokenFile 为空）。如果你的 bridge 用了 --no-token，这是正常的。"
}

# ---------- 3. 写 config.json，让扩展一启动就拿到配置 ----------

$cfgObj = [ordered]@{ port = $Port; token = $Token }
$cfgObj | ConvertTo-Json -Compress | Set-Content -Path $ConfigFile -Encoding UTF8 -NoNewline
Write-Step "已写入扩展配置：$ConfigFile"

# ---------- 4. 准备 profile ----------

if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
}

# ---------- 5. 拼命令行 ----------

$edgeArgs = @(
    "--user-data-dir=`"$ProfileDir`"",
    "--load-extension=`"$ExtensionPath`"",
    "--disable-extensions-except=`"$ExtensionPath`"",
    # ↓↓↓ 这一行是整个项目能不能跑起来的关键 ↓↓↓
    # Chromium 137 起，出于安全考虑默认屏蔽了 --load-extension 命令行开关
    # （恶意程序曾用它静默塞扩展）。屏蔽逻辑挂在 DisableLoadExtensionCommandLineSwitch
    # 这个 feature 上，把它关掉，--load-extension 就恢复可用。
    # 不加这一行：扩展不会报错，但根本不会加载，edge://extensions 里也看不到，
    # 表现是「浏览器起来了，但什么反应都没有」——非常容易误判成网络问题。
    "--disable-features=DisableLoadExtensionCommandLineSwitch,Translate,MediaRouter,OptimizationHints",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-sync",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-client-side-phishing-detection",
    "--disable-default-apps",
    "--metrics-recording-only",
    "--mute-audio",
    "--window-size=$Width,$Height",
    "--force-device-scale-factor=1"
)

if ($NoHeadless) {
    # 伪隐形：挪到虚拟屏幕之外。屏幕坐标空间通常不会超过 ±16384，
    # 但 Windows 允许更远的坐标，-32000 一定在可视区外。
    $edgeArgs += "--window-position=-32000,-32000"
    Write-Step "模式：窗口外移（进程存在但不可见，任务栏仍可见）"
} elseif ($Visible) {
    Write-Step "模式：可见窗口（调试用）"
} else {
    $edgeArgs += "--headless=new"
    $edgeArgs += "--disable-gpu"
    Write-Step "模式：无头（完全无窗口）"
}

if ($DebugPort -gt 0) {
    $edgeArgs += "--remote-debugging-port=$DebugPort"
    Write-Step "已开启 CDP 调试端口：$DebugPort"
}

$edgeArgs += $StartUrl

# ---------- 6. 启动 ----------

Write-Step "启动 Edge ..."
$proc = Start-Process -FilePath $edge `
    -ArgumentList $edgeArgs `
    -WindowStyle Hidden `
    -PassThru

$proc.Id | Set-Content -Path $PidFile -Encoding ASCII
Write-Step "PID $($proc.Id) 已记录到 $PidFile"

# 顺带把 profile 目录里可能残留的「恢复会话」弹窗关掉
$prefFile = Join-Path $ProfileDir "Default\Preferences"
if (Test-Path $prefFile) {
    try {
        $pref = Get-Content $prefFile -Raw | ConvertFrom-Json
        if ($pref.profile) {
            $pref.profile.exit_type = "Normal"
            $pref.profile.exited_cleanly = $true
        }
        $pref | ConvertTo-Json -Depth 20 -Compress | Set-Content -Path $prefFile -Encoding UTF8
    } catch { }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host " 就绪" -ForegroundColor Green
Write-Host "   桥接服务 : http://127.0.0.1:$Port"
Write-Host "   令牌     : $(if ($Token) { $Token } else { '(未启用)' })"
Write-Host "   用户数据 : $ProfileDir"
Write-Host "   PID      : $($proc.Id)"
Write-Host ""
Write-Host " 试一下：" -ForegroundColor Green
Write-Host "   python examples\client.py ping"
Write-Host "   python examples\client.py open https://example.com"
Write-Host "   python examples\client.py text"
Write-Host "==============================================================" -ForegroundColor Green
