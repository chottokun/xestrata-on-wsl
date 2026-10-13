<#
.SYNOPSIS
    XeStrata 停止用ショートカットスクリプト
.DESCRIPTION
    XeStrata 推論サーバーおよび WSLコンテナ (XeStrataLab) を停止し、GPU VRAM と RAM を解放します。
#>

[CmdletBinding()]
param (
    [string]$Name = "XeStrataLab"
)

Write-Host "XeStrataLab を停止しています..." -ForegroundColor Yellow

if (Get-Command "wslc" -ErrorAction SilentlyContinue) {
    # サーバープロセスの終了
    wslc exec -i $Name pkill -f "python3.*server.py" 2>$null
    wslc exec -i $Name pkill -f "strata" 2>$null

    # コンテナの停止
    wslc container stop $Name 2>$null
}

Write-Host "停止しました。VRAM および RAM が解放されました。" -ForegroundColor Green
