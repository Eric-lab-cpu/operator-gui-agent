<#
    push-to-github.ps1 —— 把仓库推到 GitHub

    前提：已 gh auth login（或用 -Token 传 PAT）
    用法：
      .\push-to-github.ps1 -Repo myname/operator
      .\push-to-github.ps1 -Repo myname/operator -Private
#>
param(
    [Parameter(Mandatory)][string]$Repo,
    [switch]$Private,
    [string]$Token = ''
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

if ($Token) {
    $env:GH_TOKEN = $Token
}

$status = gh auth status 2>&1 | Out-String
if ($status -match 'not logged into') {
    Write-Output '未登录 GitHub。请先执行：gh auth login'
    Write-Output '（或加 -Token <你的 PAT>）'
    exit 1
}

$exists = gh repo view $Repo 2>&1 | Out-String
if ($exists -match 'Could not resolve') {
    Write-Output "创建仓库 $Repo"
    if ($Private) { gh repo create $Repo --private --source=. --remote=origin --push }
    else { gh repo create $Repo --public --source=. --remote=origin --push }
} else {
    Write-Output "仓库已存在，关联并推送"
    $remote = git remote get-url origin 2>$null
    if (-not $remote) { git remote add origin "https://github.com/$Repo.git" }
    git push -u origin main 2>&1 | ForEach-Object { $_ }
}

git push --tags 2>&1 | ForEach-Object { $_ }
$url = gh repo view $Repo --json url -q .url 2>&1
Write-Output "完成：$url"