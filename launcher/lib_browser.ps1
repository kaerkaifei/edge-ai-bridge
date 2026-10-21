<#
.SYNOPSIS
    公共函数：找浏览器 / 探测插件是否真的加载了 / 问桥接服务 / 顺手把桥接拉起来。

.DESCRIPTION
    check_extension.ps1 和 install_extension.ps1 共用这一份逻辑。
    分成两个文件很容易各写一份，然后悄悄跑偏：检测说「没装」，
    安装却以为「装了」，最后人的时间全花在互相矛盾的两句话上。

    这里的大部分函数是只读的（看进程命令行、问桥接 /health）。唯一的例外是
    Enable-DeveloperMode / Get-ExtensionDisableReason：它们要读写浏览器 profile
    里的 Preferences —— 因为「开发者模式没开」会让命令行加载的扩展被静默禁用，
    不碰这个配置就没法把插件装进去。改动前会留 .bak-dev-mode 备份。
#>

# ---------- 路径 ----------

function ConvertTo-NormalizedPath([string]$Path) {
    if (-not $Path) { return "" }
    return ($Path -replace '/', '\').TrimEnd('\').ToLowerInvariant()
}

<#
    运行数据目录：令牌、日志、浏览器 profile 都放这里，刻意不放在代码目录。

    为什么分开：代码目录会被移动、重新 clone、备份、清理；而令牌和 profile 是
    「这台机器上的状态」，跟着代码走就会出现「换了目录 = 换了令牌 = 插件连不上」。
    27 MB 的目录里 26.6 MB 其实是 profile，搬家时最容易漏掉的也是它。
    可用环境变量 BRIDGE_RUNTIME_DIR 覆盖（便携化 / 换盘时用）。
#>
function Get-RuntimeDir {
    if ($env:BRIDGE_RUNTIME_DIR) { return $env:BRIDGE_RUNTIME_DIR }
    return (Join-Path $env:LOCALAPPDATA "EdgeAiBridge")
}

function Get-TokenFile { return (Join-Path (Get-RuntimeDir) "token.txt") }

# 0.2.0 及更早版本把令牌写在 server\token.txt，旧目录还在时继续读
function Get-LegacyTokenFile([string]$Root) { return (Join-Path $Root "server\token.txt") }

function Get-BridgeLogFile { return (Join-Path (Get-RuntimeDir) "bridge.log") }

function Get-DefaultProfileDir { return (Join-Path (Get-RuntimeDir) "profile") }

# ---------- 浏览器本体 ----------

function Find-BrowserExe([string]$Name) {
    $candidates = @()
    switch ($Name) {
        "edge" {
            $candidates = @(
                "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
            )
            $exeName = "msedge.exe"
        }
        "chrome" {
            $candidates = @(
                "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
            )
            $exeName = "chrome.exe"
        }
        default { return $null }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }

    # 装在非默认位置时问注册表（微软文档里登记过的启动路径）
    foreach ($rp in @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exeName",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exeName")) {
        try {
            $v = (Get-ItemProperty -Path $rp -ErrorAction Stop).'(default)'
            if ($v -and (Test-Path $v)) { return $v }
        } catch { }
    }
    return $null
}

function Get-BrowserDisplayName([string]$Name) {
    switch ($Name) {
        "edge" { return "Microsoft Edge" }
        "chrome" { return "Google Chrome" }
        default { return $Name }
    }
}

# 取某个浏览器 exe 对应的进程。按可执行文件路径过滤 ——
# 同一个 exe 名可能同时装着稳定版 / Beta / 企业版，杀错就是事故。
function Get-BrowserProcesses([string]$ExePath) {
    if (-not $ExePath) { return @() }

    $exeName = Split-Path -Leaf $ExePath
    $raw = @()
    try {
        $raw = @(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $exeName) -ErrorAction Stop)
    } catch {
        # CIM 查询失败时退回 Get-Process（拿不到命令行，只能按名字认）
        $base = [IO.Path]::GetFileNameWithoutExtension($exeName)
        $raw = @(Get-Process -Name $base -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ ProcessId = $_.Id; CommandLine = $null } })
    }

    $target = ConvertTo-NormalizedPath $ExePath
    $out = @()
    foreach ($p in $raw) {
        if ($p.CommandLine) {
            if ((ConvertTo-NormalizedPath $p.CommandLine).Contains($target)) { $out += $p }
        } else {
            # 没有命令行信息时不要假装它不存在，先算上，后面用「无法确认」提示
            $out += $p
        }
    }
    return $out
}

<#
    判断扩展是否真的被这个浏览器加载了。

    原理：--load-extension 这类开关只在浏览器「启动那一刻」生效，
    会原样留在浏览器主进程的命令行里。所以只要进程命令行里同时出现
    我们的扩展目录和 --load-extension / --disable-extensions-except，
    就说明这一次启动确实带了插件。

    这也解释了最常见的「我明明装了啊」：插件没被持久化进配置目录，
    下次从任务栏图标正常启动，命令行里没有那个开关，插件就不在。
#>
function Test-ExtensionLoaded([string]$ExtensionPath, $Processes) {
    $ext = ConvertTo-NormalizedPath $ExtensionPath
    if (-not $ext) { return $false }
    foreach ($p in @($Processes)) {
        if (-not $p.CommandLine) { continue }
        $cmd = ConvertTo-NormalizedPath $p.CommandLine
        if (-not $cmd.Contains($ext)) { continue }
        if ($cmd.Contains("--load-extension") -or $cmd.Contains("--disable-extensions-except")) {
            return $true
        }
    }
    return $false
}

# ---------- 能不能用命令行装扩展 ----------
<#
    品牌版 Google Chrome 从 137 起彻底禁止命令行加载解压扩展。实测 chrome.exe
    （154.0.8037.93）无论加不加 --disable-features=DisableLoadExtensionCommandLineSwitch
    还是 --enable-unsafe-extension-debugging，都会打印：

        WARNING:chrome\browser\extensions\extension_service.cc:423]
        --load-extension is not allowed in Google Chrome, ignoring.

    而默认 profile 下 --remote-debugging-port 也被拒（Chromium 136+ 安全限制，
    实测 /json/version 连不上），所以 Chrome 这边没法像 Edge 那样「一键重启装插件」。

    Chrome 的可行路径是手动装一次：chrome://extensions → 开发者模式 →
    加载已解压的扩展程序。手动装的解压扩展会持久保存在 profile 里，重启不丢，
    这跟 Edge 命令行的「一次性加载」正好相反。
#>
function Test-CanLoadExtensionFromCommandLine([string]$ExePath) {
    if (-not $ExePath) { return $false }
    $leaf = (Split-Path -Leaf $ExePath).ToLowerInvariant()
    # 目前只有 msedge.exe 实测可用（Edge 155 允许该开关）
    return ($leaf -eq "msedge.exe")
}

# ---------- 开发者模式（命令行装扩展的前提） ----------
<#
    ★ 2026-10-21 实测（Edge 155.0.4283.62）：命令行 --load-extension 加载的解压扩展，
    如果 profile 里「开发者模式」没开，浏览器会直接把它禁用，原因码：

        Secure Preferences → extensions.settings.<id>.disable_reasons = 16777216

    症状特别误导人：浏览器起来了、命令行里扩展路径也在、扩展目录完整，
    但桥接永远等不到心跳；client.py 里每个命令都等到 30 秒超时。
    对照实验（临时 profile）同样参数能装上，说明不是权限/路径问题。

    修法：趁浏览器完全关闭，把 Preferences 里的 extensions.ui.developer_mode
    写成 true，再启动 —— 实测插件立刻正常心跳。必须趁关闭时写：浏览器退出时
    会用自己的内存快照覆盖 Preferences，运行中改了等于没改（我第一次就栽在这）。

    代码里为什么用 python 改而不是 ConvertFrom-Json 往返：Preferences 是 260 KB
    的深层嵌套 JSON，PowerShell 5.1 的 ConvertTo-Json 有 -Depth 截断和整数精度
    问题，往返一次可能把用户的浏览器配置写坏。桥接本身也依赖 python，一致。
#>
function Get-BrowserUserDataDir([string]$Name) {
    switch ($Name) {
        "edge" { return (Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data") }
        "chrome" { return (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data") }
        default { return "" }
    }
}

<#
    拿「上一次用的那个 profile」。机器上可能同时有 Default / Profile 1 / Profile 2，
    浏览器启动时不带 --profile-directory 就用最后一次的那个。要改的正是它 ——
    改错一个目录就变成「设置了但没生效」。
#>
function Get-BrowserProfile([string]$Name) {
    $userData = Get-BrowserUserDataDir $Name
    if (-not $userData -or -not (Test-Path $userData)) { return $null }

    $dirName = "Default"
    $localState = Join-Path $userData "Local State"
    if (Test-Path $localState) {
        try {
            $j = Get-Content $localState -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.profile.last_used) { $dirName = $j.profile.last_used }
        } catch { }
    }
    $dir = Join-Path $userData $dirName
    return [pscustomobject]@{
        Browser     = $Name
        UserDataDir = $userData
        DirName     = $dirName
        Dir         = $dir
        Preferences = (Join-Path $dir "Preferences")
        SecurePrefs = (Join-Path $dir "Secure Preferences")
    }
}

function Get-DeveloperMode([string]$Name) {
    $p = Get-BrowserProfile $Name
    if (-not $p -or -not (Test-Path $p.Preferences)) { return $false }
    try {
        $j = Get-Content $p.Preferences -Raw -Encoding UTF8 | ConvertFrom-Json
        return [bool]$j.extensions.ui.developer_mode
    } catch { return $false }
}

<#
    把开发者模式写成 true（幂等）。返回 already / changed / failed:<原因>。
    要求浏览器已经关闭；调用方负责先关浏览器。
#>
function Enable-DeveloperMode([string]$Name) {
    $p = Get-BrowserProfile $Name
    if (-not $p) { return "failed:找不到 $Name 的用户配置目录" }
    if (-not (Test-Path $p.Preferences)) { return "failed:没有 Preferences（这个浏览器还没启动过？）" }
    if (Get-DeveloperMode $Name) { return "already" }

    $py = Find-PythonExe
    if (-not $py) { return "failed:找不到 python，没法安全改配置（也可以手动在扩展页打开开发者模式）" }

    Copy-Item $p.Preferences ($p.Preferences + ".bak-dev-mode") -Force -ErrorAction SilentlyContinue

    $patch = @'
import io, json, sys
path = sys.argv[1]
with io.open(path, encoding='utf-8') as f:
    data = json.load(f)
data.setdefault('extensions', {}).setdefault('ui', {})['developer_mode'] = True
with io.open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, separators=(',', ':'))
'@
    $out = & $py -c $patch $p.Preferences 2>&1
    if ($LASTEXITCODE -ne 0) { return "failed:$out" }

    if (Get-DeveloperMode $Name) { return "changed" }
    return "failed:写入后读回来还是 false"
}

<#
    扩展被浏览器禁用的原因码（0 = 没被禁用）。16777216 =
    DISABLE_UNSUPPORTED_DEVELOPER_EXTENSION —— 开发者模式没开。
    靠 Secure Preferences 里「path 等于我们扩展目录」的那条记录判断，
    换过目录的旧记录不会混淆（同一个扩展在不同路径下是不同 id）。
#>
function Get-ExtensionDisableReason([string]$Name, [string]$ExtensionPath) {
    $p = Get-BrowserProfile $Name
    if (-not $p -or -not (Test-Path $p.SecurePrefs)) { return 0 }
    $want = ConvertTo-NormalizedPath $ExtensionPath
    if (-not $want) { return 0 }
    try {
        $j = Get-Content $p.SecurePrefs -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $j.extensions.settings.PSObject.Properties) {
            $v = $prop.Value
            if (-not $v.path) { continue }
            if ((ConvertTo-NormalizedPath $v.path) -ne $want) { continue }
            if ($v.disable_reasons) { return [int]$v.disable_reasons }
            return 0
        }
    } catch { }
    return 0
}

<#
    /health 里哪些浏览器是真在线的：只看 age_ms 足够小的实例。
    桥接自己已经过滤掉 60 秒没心跳的，这里再收一道 15 秒的 —— 安装脚本
    被残影骗一次，代价是一个人盯着 30 秒超时想不出为什么。
#>
function Get-FreshBrowsers($Health, [int]$MaxAgeMs = 15000) {
    if (-not $Health) { return @() }
    $out = @()
    foreach ($d in @($Health.instances_detail)) {
        if (-not $d) { continue }
        if ($null -eq $d.age_ms) { $out += $d.browser; continue }
        if ([int]$d.age_ms -lt $MaxAgeMs) { $out += $d.browser }
    }
    return @($out | Sort-Object -Unique)
}

<#
    带插件启动的参数。刻意不放 --disable-extensions-except：
    那个开关会把用户自己装的其它扩展全禁用 —— 在专用 profile 里无所谓，
    但在「日常那个浏览器」里等于把 Adblock / 密码管理器一起关掉。
    Edge 不需要它也能加载 --load-extension 指定的扩展。
#>
function Get-ExtensionLaunchArgs([string]$ExtensionPath, [switch]$RestoreSession) {
    $args = @(
        "--load-extension=`"$ExtensionPath`"",
        # Chromium 137 起默认屏蔽 --load-extension（防恶意软件静默塞扩展），
        # 关掉这个特性开关才会真的加载（Edge 实测有效，Chrome 无效）。
        "--disable-features=DisableLoadExtensionCommandLineSwitch",
        "--no-first-run",
        "--no-default-browser-check"
    )
    if ($RestoreSession) { $args += "--restore-last-session" }
    return $args
}

<#
    优雅关闭浏览器：先给有窗口的进程发关闭消息（让浏览器自己保存会话），
    等它退出；超时才强制结束。
    强杀时也只按「exe 路径」筛出来的进程动手，绝不按进程名杀 ——
    机器上可能同时装着稳定版 / Beta / 企业版，按名字杀就是事故。
#>
function Close-BrowserProcesses([string]$ExePath, [int]$TimeoutSec = 15) {
    if (@(Get-BrowserProcesses $ExePath).Count -eq 0) { return $true }

    foreach ($p in @(Get-BrowserProcesses $ExePath)) {
        $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($gp -and $gp.MainWindowHandle -ne 0) {
            try { [void]$gp.CloseMainWindow() } catch { }
        }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-BrowserProcesses $ExePath).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 400
    }

    foreach ($p in @(Get-BrowserProcesses $ExePath)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-BrowserProcesses $ExePath).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return (@(Get-BrowserProcesses $ExePath).Count -eq 0)
}

# ---------- 决定「即将同步的是哪个浏览器」 ----------
<#
    规则：
      · 显式指定 -Browser edge/chrome 就用它
      · auto：优先挑「正在运行」的那个（登录态正在这个浏览器里，才谈得上同步），
        都没在跑就按 Edge → Chrome 的顺序挑已安装的
      · -ExePath 可以强制指定一个 exe（企业版 / 绿色版）
#>
function Get-SyncTarget([string]$Browser = "auto", [string]$ExePath = "") {
    if ($ExePath) {
        if (-not (Test-Path $ExePath)) { throw "指定的浏览器不存在：$ExePath" }
        $leaf = (Split-Path -Leaf $ExePath).ToLowerInvariant()
        $name = "chromium"
        if ($leaf -like "*msedge*") { $name = "edge" }
        elseif ($leaf -like "*chrome*") { $name = "chrome" }
        $procs = @(Get-BrowserProcesses $ExePath)
        return [pscustomobject]@{
            Name        = $name
            DisplayName = (Get-BrowserDisplayName $name)
            Exe         = $ExePath
            Processes   = $procs
            Running     = ($procs.Count -gt 0)
        }
    }

    $order = @()
    if ($Browser -and $Browser -ne "auto") { $order = @($Browser.ToLowerInvariant()) }
    else { $order = @("edge", "chrome") }

    $found = @()
    foreach ($name in $order) {
        $exe = Find-BrowserExe $name
        if (-not $exe) { continue }
        $found += [pscustomobject]@{
            Name        = $name
            DisplayName = (Get-BrowserDisplayName $name)
            Exe         = $exe
            Processes   = @(Get-BrowserProcesses $exe)
        }
    }
    if ($found.Count -eq 0) { return $null }

    foreach ($b in $found) {
        if ($b.Processes.Count -gt 0) {
            return [pscustomobject]@{
                Name = $b.Name; DisplayName = $b.DisplayName; Exe = $b.Exe
                Processes = $b.Processes; Running = $true
            }
        }
    }

    $first = $found[0]
    return [pscustomobject]@{
        Name = $first.Name; DisplayName = $first.DisplayName; Exe = $first.Exe
        Processes = @(); Running = $false
    }
}

# ---------- 端口 / 令牌 ----------

function Test-PortOpen([int]$Port, [int]$TimeoutMs = 400) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Find-FreePort([int]$Start, [int]$Count = 20) {
    for ($p = $Start; $p -lt ($Start + $Count); $p++) {
        if (-not (Test-PortOpen $p 120)) { return $p }
    }
    return 0
}

function Get-BridgeToken([string]$Root, [string]$Token) {
    if ($Token) { return $Token }
    if ($env:BRIDGE_TOKEN) { return $env:BRIDGE_TOKEN }
    foreach ($tf in @((Get-TokenFile), (Get-LegacyTokenFile $Root))) {
        if (Test-Path $tf) {
            $t = ((Get-Content $tf -Raw) -replace '\s', '')
            if ($t) { return $t }
        }
    }
    return ""
}

function Get-ExtensionConfig([string]$ExtensionPath) {
    $cfgFile = Join-Path $ExtensionPath "config.json"
    if (-not (Test-Path $cfgFile)) { return $null }
    try { return (Get-Content $cfgFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Set-ExtensionConfig([string]$ExtensionPath, [int]$Port, [string]$Token) {
    $cfgFile = Join-Path $ExtensionPath "config.json"
    $obj = [ordered]@{ port = $Port; token = $Token }
    # 不带 BOM 的 UTF-8：PS 5.1 的 -Encoding UTF8 会写 BOM，
    # Python json.load 用 utf-8 读带 BOM 的文件直接抛异常 ——
    # 客户端就会悄悄回落到 8800 端口，表现成「桥接明明活着，工具说连不上」。
    [System.IO.File]::WriteAllText($cfgFile, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    return $cfgFile
}

# ---------- 桥接服务 ----------

<#
    用 .NET HttpClient 而不是 Invoke-RestMethod，并且显式关掉代理。
    原因：这台机器上系统代理指向 127.0.0.1:17897，PowerShell 会把
    http://127.0.0.1:8800/health 也当成外网请求丢给代理，结果连不上
    一个明明在监听的本机端口（README 坑 9）。UseProxy = $false 最省心。
#>
function Invoke-BridgeJson([int]$Port, [string]$Token, [string]$Path, [int]$TimeoutSec = 3) {
    $client = $null
    try {
        # Windows PowerShell 5.1 里 System.Net.Http 不是默认加载的程序集，
        # 不显式加载会报 "Cannot find type [System.Net.Http.HttpClientHandler]"。
        try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $handler.AllowAutoRedirect = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "http://127.0.0.1:$Port$Path")
        if ($Token) { [void]$req.Headers.Add("X-Bridge-Token", $Token) }

        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $body; Error = "" }
    } catch {
        return [pscustomobject]@{ Status = 0; Body = ""; Error = $_.Exception.Message }
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Get-BridgeHealth([int]$Port, [string]$Token) {
    $r = Invoke-BridgeJson -Port $Port -Token $Token -Path "/health"
    if ($r.Status -ne 200) { return $null }
    try { return ($r.Body | ConvertFrom-Json) } catch { return $null }
}

function Find-PythonExe {
    foreach ($name in @("python", "python3")) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c -and $c.Source -and (Test-Path $c.Source)) { return $c.Source }
    }

    # PATH 里没 python 时，往常见安装位置找（含 uv 管理的解释器：
    # Windows 上 uv 默认装到 %APPDATA%\uv\python\，不是 LOCALAPPDATA）
    $patterns = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python*\python.exe"),
        (Join-Path $env:APPDATA "uv\python\cpython-*\python.exe"),
        (Join-Path $env:LOCALAPPDATA "uv\python\cpython-*\python.exe"),
        "$env:ProgramFiles\Python*\python.exe",
        "C:\Python*\python.exe"
    )
    foreach ($pat in $patterns) {
        $hit = @(Get-ChildItem -Path $pat -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        if ($hit.Count -gt 0) { return $hit[0].FullName }
    }

    # 最后试 py 启动器（它可能指向一个可用版本，也可能指向坏掉的版本）
    $py = Get-Command "py" -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $out = & $py.Source -3 -c "import sys; print(sys.executable)" 2>$null
            $exe = ([string]$out).Trim()
            if ($exe -and (Test-Path $exe)) { return $exe }
        } catch { }
    }
    return $null
}

function Start-BridgeService([int]$Port, [string]$Token, [string]$ServerDir) {
    $py = Find-PythonExe
    if (-not $py) { throw "找不到 python（需要 >= 3.8）。装一个，或把它的目录加进 PATH 后重试。" }

    $pyw = Join-Path (Split-Path -Parent $py) "pythonw.exe"
    if (-not (Test-Path $pyw)) { $pyw = $py }

    $runtime = Get-RuntimeDir
    if (-not (Test-Path $runtime)) { New-Item -ItemType Directory -Path $runtime -Force | Out-Null }
    $logFile = Join-Path $runtime "bridge.log"
    $argList = @((Join-Path $ServerDir "bridge.py"), "--port", "$Port", "--log", $logFile)
    if ($Token) { $argList += @("--token", $Token) }
    $quoted = ($argList | ForEach-Object {
            if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
        }) -join ' '

    # 不用 -RedirectStandardOutput：http_proxy / HTTP_PROXY 同时存在时它会抛
    # 「字典键重复」的 ArgumentException（README 坑 4），让 bridge 自己写日志最稳。
    Start-Process -FilePath $pyw -ArgumentList $quoted -WorkingDirectory $ServerDir -WindowStyle Hidden | Out-Null

    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortOpen $Port 200) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return (Test-PortOpen $Port 200)
}

# ---------- 安装状态 ----------

function Get-InstallStatePath {
    $dir = Get-RuntimeDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir "install-state.json")
}

function Save-InstallState($State) {
    $path = Get-InstallStatePath
    [System.IO.File]::WriteAllText($path, (($State | ConvertTo-Json -Depth 5)), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Get-InstallState {
    $path = Get-InstallStatePath
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch { return $null }
}
