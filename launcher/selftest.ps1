<#
.SYNOPSIS
    端到端自检：起服务 → 起无头 Edge → 跑一遍真实命令 → 清理。

.DESCRIPTION
    用来确认「这套东西在你机器上确实是通的」。
    全部动作都在本脚本内完成，跑完自动收摊，不留后台进程。

    检查项：
      1. 桥接服务能起来
      2. 无头 Edge 能起来，且扩展被加载（这一步最容易失败，见 README 的坑 3）
      3. offscreen 轮询器能连上服务
      4. 命令能下发、能在页面里执行、结果能回传
      5. 截图能落盘
      6. 全程没有可见窗口

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File launcher\selftest.ps1
#>

[CmdletBinding()]
param(
    [int]$Port = 8811,
    [string]$ProfileName = ".profile-selftest"
)

$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $PSScriptRoot
$Ext = Join-Path $Root "extension"
$Profile = Join-Path $Root $ProfileName
$ServerDir = Join-Path $Root "server"
$Client = Join-Path $Root "examples\client.py"
$Token = "selftest-" + [Guid]::NewGuid().ToString("N").Substring(0, 12)
$OutPng = Join-Path $Root "examples\selftest.png"

function Log($m) { Write-Host ">>> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }

# ---------- 找 python / Edge ----------
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { throw "找不到 python" }
$pyw = Join-Path (Split-Path -Parent $py) "pythonw.exe"
if (-not (Test-Path $pyw)) { $pyw = $py }

$edge = $null
foreach ($c in @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe")) {
    if (Test-Path $c) { $edge = $c; break }
}
if (-not $edge) { throw "找不到 msedge.exe" }

# ---------- 准备 ----------
if (Test-Path $Profile) { Remove-Item $Profile -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $Profile -Force | Out-Null

# 自检用独立端口和独立令牌，不碰你平时那份配置
$cfgBackup = $null
$cfgFile = Join-Path $Ext "config.json"
if (Test-Path $cfgFile) { $cfgBackup = Get-Content $cfgFile -Raw }
@{ port = $Port; token = $Token } | ConvertTo-Json -Compress | Set-Content $cfgFile -Encoding UTF8 -NoNewline

$logFile = Join-Path $ServerDir "selftest.log"
Remove-Item $logFile -ErrorAction SilentlyContinue

Log "启动桥接服务（端口 $Port）"
$a = '"' + (Join-Path $ServerDir "bridge.py") + '" --port ' + $Port + ' --token ' + $Token + ' --log "' + $logFile + '"'
Start-Process -FilePath $pyw -ArgumentList $a -WorkingDirectory $ServerDir -WindowStyle Hidden
Start-Sleep -Seconds 2

Log "启动无头 Edge"
$edgeArgs = @(
    "--user-data-dir=`"$Profile`"",
    "--load-extension=`"$Ext`"",
    "--disable-extensions-except=`"$Ext`"",
    "--disable-features=DisableLoadExtensionCommandLineSwitch",
    "--headless=new",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-sync",
    "--mute-audio",
    "--window-size=1440,900",
    "about:blank"
) -join ' '
Start-Process -FilePath $edge -ArgumentList $edgeArgs -WindowStyle Hidden

# ---------- 1. 等扩展连上 ----------
Log "等待扩展连上（最多 15 秒）"
$hdr = @{ "X-Bridge-Token" = $Token }
$connected = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -Headers $hdr -TimeoutSec 2
        if ($h.instances.Count -gt 0) { $connected = $true; Ok "扩展已连上：$($h.instances -join ',')"; break }
    } catch { }
}
if (-not $connected) {
    Bad "扩展没连上"
    Write-Host ""
    Write-Host "  排查顺序：" -ForegroundColor Yellow
    Write-Host "   1) Edge 版本是否 >= 137？老版本不支持 --headless=new 里的扩展"
    Write-Host "   2) 看日志：$logFile"
    Write-Host "   3) 加 -Verbose 手动开可见窗口跑 launch_setup.ps1 看 edge://extensions"
    if (Test-Path $logFile) { Get-Content $logFile -Tail 15 }
    if ($cfgBackup) { Set-Content $cfgFile $cfgBackup -Encoding UTF8 -NoNewline }
    else { Remove-Item $cfgFile -Force -ErrorAction SilentlyContinue }
    exit 1
}

# ---------- 2. 跑命令 ----------
$env:BRIDGE_TOKEN = $Token

Log "ping"
$r = & $py $Client --port $Port --token $Token --json ping | ConvertFrom-Json
if ($r.pong) { Ok "浏览器有响应" } else { Bad "ping 无响应" }

Log "打开 https://example.com（后台标签页）"
$o = & $py $Client --port $Port --token $Token --json open "https://example.com" | ConvertFrom-Json
if ($o.ok) { Ok "tabId=$($o.tabId)" } else { Bad "打开失败" }

Log "等 body 出现"
$w = & $py $Client --port $Port --token $Token --json wait "body" --ms 15000 | ConvertFrom-Json
if ($w.found) { Ok "页面已渲染" } else { Bad "页面没加载出来" }

Log "读 document.title"
$t = & $py $Client --port $Port --token $Token --json eval "document.title" | ConvertFrom-Json
if ($t.value) { Ok "标题：$($t.value)" } else { Bad "取标题失败" }

Log "在页面里执行复杂 JS"
$c = & $py $Client --port $Port --token $Token --json eval "({links: document.querySelectorAll('a').length, len: document.body.innerText.length})" | ConvertFrom-Json
if ($c.value) { Ok "链接 $($c.value.links) 个，正文 $($c.value.len) 字" } else { Bad "执行失败" }

Log "页面里 await 一个 Promise"
$p = & $py $Client --port $Port --token $Token --json eval "new Promise(r => setTimeout(() => r('ok'), 200))" | ConvertFrom-Json
if ($p.value -eq "ok") { Ok "Promise 能被正确等待" } else { Bad "Promise 没等到" }

Log "截图"
$s = & $py $Client --port $Port --token $Token --json shot $OutPng | ConvertFrom-Json
if ($s.saved -and (Test-Path $OutPng)) { Ok "已保存 $OutPng（$([Math]::Round((Get-Item $OutPng).Length / 1024)) KB）" } else { Bad "截图失败" }

Log "关闭标签页"
& $py $Client --port $Port --token $Token close $o.tabId | Out-Null
Ok "已关闭"

# ---------- 3. 隐形检查 ----------
Log "检查是否真的没有可见窗口"
$mine = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Profile) }
$withWin = @($mine | Where-Object {
        $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
        $p -and $p.MainWindowHandle -ne 0
    })
Ok "本实例进程 $($mine.Count) 个，其中带主窗口的 $($withWin.Count) 个"
if ($withWin.Count -eq 0) { Ok "确认：全程无可见窗口" } else { Bad "有窗口露出来了" }

# ---------- 4. 清理 ----------
Log "清理"
foreach ($proc in $mine) { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
$conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
foreach ($c2 in $conn) {
    $pp = Get-Process -Id $c2.OwningProcess -ErrorAction SilentlyContinue
    if ($pp -and $pp.ProcessName -like "python*") { Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Milliseconds 500
Remove-Item $Profile -Recurse -Force -ErrorAction SilentlyContinue
# 恢复配置：原来有就还原，原来没有就删掉，别把自己的测试配置留在仓库里
if ($cfgBackup) {
    Set-Content $cfgFile $cfgBackup -Encoding UTF8 -NoNewline
} else {
    Remove-Item $cfgFile -Force -ErrorAction SilentlyContinue
}
Remove-Item $logFile -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "自检结束。" -ForegroundColor Green
