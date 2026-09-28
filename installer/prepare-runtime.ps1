<#
.SYNOPSIS
    备料：组装安装器用的【私有 Python 运行时】（installer\runtime\python）。

.DESCRIPTION
    为什么要内置一份 Python：桥接 lxai_bridge.py 是 Python 脚本，第三方依赖是
    websockets。此前只能让用户自己装 Python 并 `pip install websockets` ——
    既要求用户懂这些，又会把依赖装进用户的全局环境。内置一份私有运行时后：
      * 用户装完 App 就能用远程遥控，不需要任何额外步骤；
      * 依赖只落在 {app}\python 里，不污染用户的 Python；
      * 不同用户的 Python 版本差异不再影响桥接行为。

    做法（三步，全部幂等）：
      1. 下载 Python embeddable 包并解压到 runtime\python；
      2. 打开 python3xx._pth 里的 `import site`（embeddable 默认关闭，
         不打开就 import 不到 site-packages 里的 websockets）；
      3. 取 websockets 的 wheel 并解压进 Lib\site-packages
         （纯解压，不用 pip —— embeddable 里没有 pip）。

.PARAMETER Force
    即使已备料完成也重新做一遍。

.EXAMPLE
    pwsh -File prepare-runtime.ps1
    pwsh -File prepare-runtime.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ── 版本与路径 ────────────────────────────────────────────────────────────────
# Python 3.13 系：成熟稳定，且 websockets 17.x 有对应的 cp313 wheel。
$PyVersion    = '3.13.15'
$PyZipName    = "python-$PyVersion-embed-amd64.zip"
$PyUrl        = "https://www.python.org/ftp/python/$PyVersion/$PyZipName"
$WebsocketsReq = 'websockets'      # 不锁死版本：取当前 PyPI 最新

$Root      = $PSScriptRoot
$CacheDir  = Join-Path $Root 'cache'
$RuntimePy = Join-Path $Root 'runtime\python'
$SitePkgs  = Join-Path $RuntimePy 'Lib\site-packages'

foreach ($d in @($CacheDir, $RuntimePy, $SitePkgs)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# ── 幂等检查：已备料且导入自检通过就直接返回 ───────────────────────────────────
$pyExe = Join-Path $RuntimePy 'python.exe'
if (-not $Force -and (Test-Path -LiteralPath $pyExe)) {
    $probe = & $pyExe -c "import websockets;print(websockets.__version__)" 2>&1
    if ($LASTEXITCODE -eq 0 -and $probe -match '^\d') {
        Write-Step "私有运行时已就绪（Python $PyVersion / websockets $probe），跳过。加 -Force 可强制重做。"
        exit 0
    }
    Write-Warn '已有运行时但自检未通过，重新组装…'
}

# ── 1) Python embeddable ─────────────────────────────────────────────────────
Write-Step "准备 Python $PyVersion embeddable"
$pyZip = Join-Path $CacheDir $PyZipName
if (-not (Test-Path -LiteralPath $pyZip)) {
    Write-Host "    下载 $PyUrl"
    Invoke-WebRequest -Uri $PyUrl -OutFile $pyZip -TimeoutSec 600
}
Write-Ok ("包 {0:N2} MB" -f ((Get-Item -LiteralPath $pyZip).Length / 1MB))

if (Test-Path -LiteralPath $RuntimePy) { Remove-Item -LiteralPath $RuntimePy -Recurse -Force }
New-Item -ItemType Directory -Path $RuntimePy -Force | Out-Null
Expand-Archive -Path $pyZip -DestinationPath $RuntimePy -Force
New-Item -ItemType Directory -Path $SitePkgs -Force | Out-Null
Write-Ok ("解压完成，{0} 个文件" -f @(Get-ChildItem -LiteralPath $RuntimePy -File).Count)

# ── 2) 打开 site（否则 import 不到 site-packages）────────────────────────────
Write-Step '开启 site-packages（embeddable 默认关闭）'
$pth = Get-ChildItem -LiteralPath $RuntimePy -Filter 'python3*._pth' | Select-Object -First 1
if (-not $pth) { throw "未找到 python3xx._pth，无法开启 site-packages" }
$lines = Get-Content -LiteralPath $pth.FullName
$patched = $lines | ForEach-Object { if ($_ -match '^\s*#\s*import site\s*$') { 'import site' } else { $_ } }
if ($patched -notcontains 'import site') { $patched += 'import site' }
[IO.File]::WriteAllLines($pth.FullName, $patched, (New-Object Text.UTF8Encoding($false)))
Write-Ok "$($pth.Name): $($patched -join ' | ')"

# ── 3) websockets（解压 wheel，不用 pip）─────────────────────────────────────
Write-Step "取 $WebsocketsReq 的 wheel"
# 用本机 Python 下载：它只是替我们取包，最终运行时与它无关
$hostPy = $null
foreach ($cand in @('python', 'py')) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $hostPy = $cmd.Source; break }
}
if (-not $hostPy) { throw '本机没有可用的 Python 来下载 wheel；请先安装 Python 或手动把 wheel 放进 cache\' }

# 目标运行时的版本/平台特征，避免下到不匹配的 wheel
$pyTag = 'cp' + ($PyVersion -replace '^(\d+)\.(\d+).*', '$1$2')
& $hostPy -m pip download $WebsocketsReq --no-deps --only-binary=:all: `
    --python-version ($PyVersion -replace '^(\d+\.\d+).*', '$1') `
    --platform win_amd64 --implementation cp -d $CacheDir 2>&1 |
    Select-Object -Last 2 | ForEach-Object { Write-Host "    $_" }

$whl = Get-ChildItem -LiteralPath $CacheDir -Filter "$WebsocketsReq-*.whl" |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $whl) { throw "没取到 $WebsocketsReq 的 wheel" }
Write-Ok $whl.Name

# Expand-Archive 只认 .zip，先复制一份
$tmpZip = Join-Path $CacheDir "_wheel_tmp.zip"
Copy-Item -LiteralPath $whl.FullName -Destination $tmpZip -Force
Expand-Archive -Path $tmpZip -DestinationPath $SitePkgs -Force
Remove-Item -LiteralPath $tmpZip -Force
Write-Ok '已解压到 Lib\site-packages'

# ── 4) 自检 ──────────────────────────────────────────────────────────────────
Write-Step '自检私有运行时'
& $pyExe -c "import websockets;print('websockets', websockets.__version__)" | ForEach-Object { Write-Ok $_ }
& $pyExe -c "import websockets.asyncio.client;print('asyncio.client OK')"   | ForEach-Object { Write-Ok $_ }
& $pyExe -c "import websockets.asyncio.connection;print('asyncio.connection OK')" | ForEach-Object { Write-Ok $_ }

$stat = Get-ChildItem -LiteralPath $RuntimePy -Recurse -File | Measure-Object -Property Length -Sum
Write-Host ("`n完成：{0} 个文件 / {1:N2} MB  →  {2}" -f $stat.Count, ($stat.Sum / 1MB), $RuntimePy) -ForegroundColor Green
