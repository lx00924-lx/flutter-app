<#
.SYNOPSIS
    一键构建 LxAI Windows 安装器。

.DESCRIPTION
    流程：
      1. 校验 Flutter Release 产物存在（不在就先 flutter build windows --release）；
      2. 备料私有 Python 运行时（调 prepare-runtime.ps1）；
      3. 调 Inno Setup 的 ISCC 编译出 output\LxAI-Setup-<版本>.exe。

    版本号默认从 flutter_app\pubspec.yaml 的 version 读取，也可用 -Version 覆盖。

.PARAMETER Version
    覆盖版本号（默认取 pubspec.yaml）。

.PARAMETER SkipRuntime
    跳过私有运行时备料（运行时已就绪时更快）。

.EXAMPLE
    pwsh -File build-installer.ps1
    pwsh -File build-installer.ps1 -Version 1.0.2
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$SkipRuntime
)

$ErrorActionPreference = 'Stop'

$Root       = $PSScriptRoot
$RepoRoot   = Split-Path $Root -Parent
$ReleaseDir = Join-Path $RepoRoot 'flutter_app\build\windows\x64\runner\Release'
$IssFile    = Join-Path $Root 'lxai-setup.iss'
$OutputDir  = Join-Path $Root 'output'

function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "    $m" -ForegroundColor Green }

# ── 版本号 ───────────────────────────────────────────────────────────────────
if (-not $Version) {
    $pubspec = Join-Path $RepoRoot 'flutter_app\pubspec.yaml'
    if (Test-Path -LiteralPath $pubspec) {
        $line = Select-String -LiteralPath $pubspec -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' |
                Select-Object -First 1
        if ($line) { $Version = $line.Matches[0].Groups[1].Value }
    }
    if (-not $Version) { $Version = '1.0.1' }
}
Write-Step "版本号：$Version"

# ── 1) Flutter 产物 ──────────────────────────────────────────────────────────
Write-Step '校验 Flutter Release 产物'
if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir 'LxAI.exe'))) {
    throw "未找到 $ReleaseDir\LxAI.exe —— 请先在 flutter_app 里执行：flutter build windows --release"
}
$files = Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File
Write-Ok ("{0} 个文件 / {1:N2} MB" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB))

# ── 2) 私有 Python 运行时 ────────────────────────────────────────────────────
if ($SkipRuntime) {
    Write-Step '跳过运行时备料（-SkipRuntime）'
} else {
    Write-Step '备料私有 Python 运行时'
    & (Join-Path $Root 'prepare-runtime.ps1')
}

# ── 3) 定位 ISCC 并编译 ──────────────────────────────────────────────────────
Write-Step '定位 Inno Setup 编译器（ISCC.exe）'
$isccCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
)
$iscc = $isccCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) {
    throw @'
未找到 ISCC.exe。请先安装 Inno Setup 6：
  https://jrsoftware.org/isdl.php
静默安装示例：
  innosetup-6.7.3.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-
'@
}
Write-Ok $iscc

Write-Step '编译'
& $iscc "/DMyAppVersion=$Version" $IssFile | Select-Object -Last 6 | ForEach-Object { Write-Host "    $_" }
if ($LASTEXITCODE -ne 0) { throw "ISCC 编译失败（退出码 $LASTEXITCODE）" }

$setup = Get-ChildItem -LiteralPath $OutputDir -Filter "LxAI-Setup-*.exe" |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $setup) { throw '编译成功但没找到产物' }

Write-Host ''
Write-Host ("完成：{0}" -f $setup.FullName) -ForegroundColor Green
Write-Host ("       {0:N2} MB   构建于 {1:yyyy-MM-dd HH:mm:ss}" -f ($setup.Length / 1MB), $setup.LastWriteTime) -ForegroundColor Green
Write-Host ''
Write-Host '提醒：未做代码签名，用户首次运行会看到 SmartScreen 的“未知发布者”提示。' -ForegroundColor Yellow
