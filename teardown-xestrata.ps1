<#
.SYNOPSIS
    XeStrataLab 完全破棄スクリプト (方式A/方式B 両対応)
.DESCRIPTION
    方式A (WSLコンテナ) または 方式B (WSL2独立インスタンス) のリソースを完全削除し、
    SSD容量およびホスト環境を100%元に戻します。
.PARAMETER Mode
    削除対象のモード:
      'Container' (方式A: wslc コンテナを削除)
      'Instance'  (方式B: WSLディストリビューションとフォルダを完全削除)
      'All'       (両方をチェックして削除)
.PARAMETER Name
    コンテナ名またはWSLインスタンス名（デフォルト: XeStrataLab）
.PARAMETER InstallDir
    方式Bの保存先フォルダ（デフォルト: 現在のスクリプト配下\distro）
.PARAMETER Force
    確認プロンプトをスキップ
#>

[CmdletBinding()]
param (
    [ValidateSet("Container", "Instance", "All")]
    [string]$Mode = "All",

    [string]$Name = "XeStrataLab",
    [string]$InstallDir = (Join-Path $PSScriptRoot "distro"),
    [switch]$Force
)

Write-Host "==========================================================" -ForegroundColor Red
Write-Host " [XeStrataLab] 完全破棄スクリプト" -ForegroundColor Red
Write-Host " 対象モード : $Mode"
Write-Host " 対象名     : $Name"
Write-Host " 対象パス   : $InstallDir"
Write-Host "==========================================================" -ForegroundColor Red

if (-not $Force) {
    $confirm = Read-Host "本当に完全破棄しますか？データおよび設定は復元できません (yes/NO)"
    if ($confirm -ne "yes") {
        Write-Host "キャンセルしました。" -ForegroundColor Green
        exit 0
    }
}

# --- 方式A (コンテナ) の破棄 ---
if ($Mode -eq "Container" -or $Mode -eq "All") {
    if (Get-Command "wslc" -ErrorAction SilentlyContinue) {
        $existingContainers = wslc list --all 2>$null
        if ($existingContainers -match "\b$Name\b") {
            Write-Host "WSLコンテナ '$Name' を停止・削除中..." -ForegroundColor Yellow
            wslc stop $Name 2>$null
            wslc remove $Name 2>$null
            Write-Host ">> WSLコンテナ '$Name' を削除しました。" -ForegroundColor Green
        } else {
            Write-Host ">> WSLコンテナ '$Name' は存在しません。" -ForegroundColor Gray
        }
    }
}

# --- 方式B (WSL2独立インスタンス) の破棄 ---
if ($Mode -eq "Instance" -or $Mode -eq "All") {
    $existingDistros = wsl --list --quiet 2>$null
    if ($existingDistros -contains $Name) {
        Write-Host "WSLインスタンス '$Name' を終了・登録解除中..." -ForegroundColor Yellow
        wsl --terminate $Name 2>$null
        wsl --unregister $Name
        Write-Host ">> WSLインスタンス '$Name' の登録を解除しました。" -ForegroundColor Green
    } else {
        Write-Host ">> WSLインスタンス '$Name' は登録されていません。" -ForegroundColor Gray
    }

    if (Test-Path $InstallDir) {
        Write-Host "保存先ディレクトリ '$InstallDir' を削除中..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $InstallDir
        Write-Host ">> 仮想ディスクとディレクトリを完全削除しました。" -ForegroundColor Green
    }
}

Write-Host "==========================================================" -ForegroundColor Green
Write-Host " [完了] 環境の完全破棄が完了しました。ディスク容量が解放されました。" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
