<#
.SYNOPSIS
    一次性「安装确认」：开一个可见的 Edge，让你亲眼看到扩展加载成功。

.DESCRIPTION
    什么时候需要它：
      · 第一次用，想确认扩展真的被装进去了
      · 你的 Edge 版本较老，--headless=new 下扩展不工作，需要手动拖进 edge://extensions
      · 想看看扩展弹窗里的心跳状态

    跑完之后这个 profile 里就已经装好扩展了，之后 launch_hidden.ps1
    用同一个 profile 启动，扩展会被自动恢复，不用再确认一次。
#>

[CmdletBinding()]
param(
    [int]$Port = 8800,
    [string]$ExtensionPath = "",
    [string]$ProfileDir = "",
    [string]$EdgePath = ""
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
# 运行数据（令牌 / profile）在用户级目录，不在仓库里 —— 与 launch_hidden.ps1 一致
$RuntimeDir = if ($env:BRIDGE_RUNTIME_DIR) { $env:BRIDGE_RUNTIME_DIR } else { Join-Path $env:LOCALAPPDATA "EdgeAiBridge" }
if (-not $ExtensionPath) { $ExtensionPath = Join-Path $Root "extension" }
if (-not $ProfileDir)    { $ProfileDir    = Join-Path $RuntimeDir "profile" }

$ServerDir = Join-Path $Root "server"
$TokenFile = if (Test-Path (Join-Path $RuntimeDir "token.txt")) { Join-Path $RuntimeDir "token.txt" } else { Join-Path $ServerDir "token.txt" }
$ConfigFile = Join-Path $ExtensionPath "config.json"

function Write-Step($msg) { Write-Host "[setup] $msg" -ForegroundColor Cyan }

# 找 Edge
if (-not $EdgePath) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { $EdgePath = $c; break }
    }
}
if (-not $EdgePath -or -not (Test-Path $EdgePath)) {
    throw "找不到 msedge.exe，请用 -EdgePath 指定。"
}

# 令牌
$token = ""
if (Test-Path $TokenFile) { $token = (Get-Content $TokenFile -Raw).Trim() }

# 写配置
$cfg = [ordered]@{ port = $Port; token = $token }
$cfg | ConvertTo-Json -Compress | Set-Content -Path $ConfigFile -Encoding UTF8 -NoNewline
Write-Step "扩展配置已写入：$ConfigFile"

# 建 profile
if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
}

$edgeArgs = @(
    "--user-data-dir=`"$ProfileDir`"",
    "--load-extension=`"$ExtensionPath`"",
    "--no-first-run",
    "--no-default-browser-check",
    "edge://extensions/"
)

Write-Step "打开可见 Edge（扩展应已自动加载）..."
Start-Process -FilePath $EdgePath -ArgumentList $edgeArgs | Out-Null

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host " 接下来请人工确认三件事：" -ForegroundColor Green
Write-Host ""
Write-Host " 1. edge://extensions 里能看到 `"Edge AI Bridge`"，且已启用"
Write-Host "    （如果没自动出现：打开右上角「开发人员模式」→"
Write-Host "      「加载解压缩的扩展」→ 选这个目录："
Write-Host "      $ExtensionPath ）"
Write-Host ""
Write-Host " 2. 点扩展图标 → 弹窗里 端口=$Port，令牌=$(if ($token) { '已填' } else { '空' })"
Write-Host "    → 点「保存」→ 点「测试连接」，应显示绿色圆点"
Write-Host ""
Write-Host " 3. 关闭这个窗口，然后运行："
Write-Host "      powershell -ExecutionPolicy Bypass -File launcher\launch_hidden.ps1"
Write-Host "    之后它就以无头模式跑了，不会再有任何窗口。"
Write-Host "==============================================================" -ForegroundColor Green
