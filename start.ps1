<#
.SYNOPSIS
    XeStrata 起動用ショートカットスクリプト
.DESCRIPTION
    WSLコンテナ (XeStrataLab) を開始し、XeStrata 推論サーバーをバックグラウンドで起動します。
#>

[CmdletBinding()]
param (
    [string]$Name = "XeStrataLab",
    [int]$Port = 8095
)

$ErrorActionPreference = "Stop"

Write-Host "XeStrataLab を起動しています..." -ForegroundColor Cyan

# 1. コンテナの開始確認
$status = wslc list --all 2>$null | Select-String "\b$Name\b"
if (-not $status) {
    Write-Error "コンテナ '$Name' が見つかりません。先に .\setup-xestrata.ps1 を実行してください。"
}

wslc container start $Name | Out-Null

# 2. 設定ファイルの検出
$configFiles = wslc exec -i $Name bash -c "ls -1 /root/.config/xestrata/xestrata-*.json 2>/dev/null"
if (-not $configFiles) {
    Write-Host "モデル設定が見つかりません。セットアップを開始します..." -ForegroundColor Yellow
    wslc exec -it $Name xestrata --setup
    exit 0
}

$targetConfig = ($configFiles -split "`r?`n")[0].Trim()
Write-Host "設定ファイル: $targetConfig" -ForegroundColor DarkGray

# 3. サーバーのバックグラウンド起動 (既に動いていなければ起動)
$isRunning = wslc exec -i $Name pgrep -f "server.py"
if (-not $isRunning) {
    wslc exec -d $Name python3 /usr/share/xestrata/serve/server.py --engine strata --config $targetConfig
    Write-Host "推論サーバーをバックグラウンドで開始しました。" -ForegroundColor Green
} else {
    Write-Host "推論サーバーは既に稼働中です。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Web UI: http://127.0.0.1:${Port}" -ForegroundColor Cyan
Write-Host "ブラウザで上記URLを開いてご利用ください。"
