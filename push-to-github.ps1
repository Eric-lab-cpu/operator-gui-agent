<#
    push-to-github.ps1 —— 把仓库推到 GitHub

    前提：已执行 gh auth login（或用 -Token 传入 PAT）
    用法：
      .\push-to-github.ps1 -Repo <用户名>/<仓库名>
      .\push-to-github.ps1 -Repo <用户名>/<仓库名> -Private
#>
param(
    [Parameter(Mandatory)][string]$Repo,
    [switch]$Private,
    [string]$Token = '',
    [string]$Description = 'Windows GUI Agent: 用自然语言驱动鼠标键盘，带 Web 控制台、定时任务与托盘守护'
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

if ($Token) { $env:GH_TOKEN = $Token }

$status = (& gh auth status 2>&1 | Out-String)
if ($status -match 'not logged into' -or $status -match '没有登录') {
    Write-Output '未登录 GitHub。请先执行：gh auth login'
    Write-Output '（或加 -Token <你的 PAT>）'
    exit 1
}
$who = (& gh api user --jq .login 2>&1 | Out-String).Trim()
Write-Output "已登录：$who"

$origin = (git remote get-url origin 2>$null)
if (-not $origin) {
    $view = (& gh repo view $Repo 2>&1 | Out-String)
    if ($view -match 'Could not resolve|not found') {
        Write-Output "创建仓库 $Repo ..."
        $args = @('repo', 'create', $Repo, '--source=.', '--remote=origin', '--description', $Description)
        if ($Private) { $args += '--private' } else { $args += '--public' }
        & gh @args 2>&1 | ForEach-Object { "  $_" }
    } else {
        Write-Output "仓库已存在，关联远端"
        git remote add origin "https://github.com/$Repo.git"
        git push -u origin main 2>&1 | ForEach-Object { "  $_" }
    }
}

Write-Output '推送 main ...'
git push -u origin main 2>&1 | ForEach-Object { "  $_" }
Write-Output '推送标签 ...'
git push origin --tags 2>&1 | ForEach-Object { "  $_" }

$url = (& gh repo view $Repo --json url -q .url 2>&1 | Out-String).Trim()
Write-Output ''
Write-Output "完成：$url"