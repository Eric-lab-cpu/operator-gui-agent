<#
    release.ps1 —— 一条命令完成发布

      1) 编译启动器
      2) 打包 dist\Operator-<版本>\ 和 zip
      3) git 提交 + 打 tag
      4) 给出推送命令

    用法：
      .\release.ps1                 用当前 VERSION 发布
      .\release.ps1 -Version 0.5.0  指定版本号
      .\release.ps1 -Push           发布后直接推（需要先 gh auth login 或有远端）
#>
param(
    [string]$Version = '',
    [switch]$Push,
    [string]$Message = ''
)

$ErrorActionPreference = 'Continue'   # git 的 stderr 警告不该中断发布
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# ── 版本 ──
if ($Version) {
    [IO.File]::WriteAllText((Join-Path $root 'VERSION'), "$Version`n", (New-Object Text.UTF8Encoding($false)))
}
$ver = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
Write-Output "版本：$ver"

# ── 编译 ──
Write-Output '[1/4] 编译启动器'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'launcher\build.ps1') | ForEach-Object { "    $_" }

# ── 打包 ──
Write-Output '[2/4] 打包'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'package.ps1') | ForEach-Object { "    $_" }

# ── 提交 ──
Write-Output '[3/4] 提交'
git add -A 2>&1 | Out-Null
$dirty = (git status --short | Measure-Object).Count
if ($dirty -gt 0) {
    if (-not $Message) { $Message = "chore(release): v$ver" }
    git -c core.safecrlf=false commit -m $Message 2>&1 | Select-Object -First 3 | ForEach-Object { "    $_" }
} else {
    Write-Output '    工作区干净，跳过提交'
}

$tag = "v$ver"
$hasTag = (git tag --list $tag)
if (-not $hasTag) {
    git tag -a $tag -m "Operator $ver" 2>&1 | Out-Null
    Write-Output "    已打标签 $tag"
} else {
    Write-Output "    标签 $tag 已存在"
}

# ── 推送 ──
Write-Output '[4/4] 推送'
if ($Push) {
    $remote = git remote get-url origin 2>$null
    if (-not $remote) { throw '还没有远端仓库，先执行：git remote add origin <url>' }
    git push origin main --tags 2>&1 | ForEach-Object { "    $_" }
} else {
    Write-Output '    跳过（加 -Push 或手动执行：git push origin main --tags）'
}

Write-Output ''
Write-Output ("发布完成：dist\Operator-{0}.zip" -f $ver)
