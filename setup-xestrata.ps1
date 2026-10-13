<#
.SYNOPSIS
    XeStrataLab 構築自動化スクリプト (Docker Desktop不要 / WSL & WSLコンテナー対応)
.DESCRIPTION
    方式A (WSLコンテナー運用) または 方式B (WSL独立インスタンスインポート) を選択して
    Ubuntu 26.04 環境上に XeStrata を自動構築・セットアップします。
    GitHub Releases API から常に最新バージョン（または指定バージョン）の deb を自動解決します。
.PARAMETER Mode
    構築方式:
      'Container' (方式A: wslc を用いた軽量コンテナ直接運用、デフォルト)
      'Instance'  (方式B: wsl --import による独立ディストリビューション運用)
.PARAMETER XeVersion
    インストールするXeStrataのバージョンタグ（デフォルト: "latest"。例: "xe0.1.43.1"）
.PARAMETER CudaVariant
    CUDAバリアント（デフォルト: "cuda13.1"。または "cuda12.4"）
.PARAMETER Name
    コンテナ名またはWSLインスタンス名（デフォルト: XeStrataLab）
.PARAMETER InstallDir
    方式Bのインスタンス保存先フォルダ（デフォルト: 現在のスクリプト配下\distro）
.PARAMETER DockerImage
    ベースイメージ（デフォルト: ubuntu:26.04 ※XeStrata要件）
.PARAMETER Port
    Web UI公開ポート（デフォルト: 8095）
#>

[CmdletBinding()]
param (
    [ValidateSet("Container", "Instance")]
    [string]$Mode = "Container",

    [string]$XeVersion = "latest",
    [string]$CudaVariant = "cuda13.1",

    [string]$Name = "XeStrataLab",
    [string]$InstallDir = (Join-Path $PSScriptRoot "distro"),
    [string]$DockerImage = "ubuntu:26.04",
    [int]$Port = 8095
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [XeStrataLab] 自動構築スクリプト" -ForegroundColor Cyan
Write-Host " 動作モード   : 方式 $(if ($Mode -eq 'Container') {'A: WSLコンテナー直接運用'} else {'B: WSL独立インスタンスインポート'})" -ForegroundColor Green
Write-Host " 対象OS       : $DockerImage (Ubuntu 26系)" -ForegroundColor Green
Write-Host " XeStrata版   : $XeVersion ($CudaVariant)" -ForegroundColor Green
Write-Host " 名称         : $Name" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

# 0. WSL および wslc の存在確認
Write-Host "[0/4] 前提環境の確認 (wsl / wslc)..." -ForegroundColor Yellow
if (-not (Get-Command "wsl" -ErrorAction SilentlyContinue)) {
    Write-Error "WSL がインストールされていません。"
}
if (-not (Get-Command "wslc" -ErrorAction SilentlyContinue)) {
    Write-Error "wslc (WSL コンテナー CLI) が見つかりません。'wsl --update' で最新版に更新してください。"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$internalScriptPath = Join-Path $scriptDir "internal-setup.sh"
if (-not (Test-Path $internalScriptPath)) {
    Write-Error "内部セットアップスクリプトが見つかりません: $internalScriptPath"
}

# .wslconfig の確認
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
if (Test-Path $wslConfigPath) {
    Write-Host ">> .wslconfig 検出: $wslConfigPath" -ForegroundColor DarkGray
} else {
    Write-Warning ".wslconfig が未検出です。MoEモデル実行のため memory=24GB, swap=16GB 以上の設定を推奨します。"
}

# ==========================================================
# 方式 A: WSLコンテナー直接運用
# ==========================================================
if ($Mode -eq "Container") {
    Write-Host "`n--- [方式A] WSLコンテナー ($Name) の作成 ---" -ForegroundColor Cyan

    $existingContainers = wslc list --all 2>$null
    if ($existingContainers -match "\b$Name\b") {
        $confirm = Read-Host "既存のコンテナ '$Name' が存在します。削除して再作成しますか？ (y/N)"
        if ($confirm -eq "y" -or $confirm -eq "Y") {
            Write-Host "既存コンテナ '$Name' を停止・削除中..." -ForegroundColor Yellow
            wslc stop $Name 2>$null
            wslc remove $Name 2>$null
        } else {
            Write-Host "処理を中断しました。" -ForegroundColor Red
            exit 0
        }
    }

    Write-Host "[1/3] コンテナ '$Name' をバックグラウンド作成中..." -ForegroundColor Yellow
    wslc run -d `
        --name $Name `
        --gpus all `
        -p "${Port}:8095" `
        $DockerImage `
        tail -f /dev/null

    Write-Host "[2/3] コンテナ内部でセットアップを実行中 ($XeVersion)..." -ForegroundColor Yellow
    $scriptContent = Get-Content -Path $internalScriptPath -Raw | ForEach-Object { $_ -replace "\r\n", "`n" }
    $scriptContent | wslc exec -i $Name bash -c "cat > /tmp/internal-setup.sh && chmod +x /tmp/internal-setup.sh && /tmp/internal-setup.sh '$XeVersion' '$CudaVariant'"

    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host " [成功] WSLコンテナー版 XeStrataLab の構築が完了しました！" -ForegroundColor Green
    Write-Host ""
    Write-Host " コンテナ内で対話型セットアップを起動するコマンド:" -ForegroundColor Cyan
    Write-Host "   wslc exec -it $Name xestrata --setup" -ForegroundColor White
    Write-Host ""
    Write-Host " コンテナ内のシェルに入るコマンド:" -ForegroundColor Cyan
    Write-Host "   wslc exec -it $Name bash" -ForegroundColor White
    Write-Host ""
    Write-Host " Web UI アクセス先 (Windows ブラウザ):" -ForegroundColor Cyan
    Write-Host "   http://127.0.0.1:${Port}" -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Green

    $runSetupNow = Read-Host "今すぐ対話型セットアップ (xestrata --setup) を起動しますか？ (Y/n)"
    if ($runSetupNow -ne "n" -and $runSetupNow -ne "N") {
        wslc exec -it $Name xestrata --setup
    }
}

# ==========================================================
# 方式 B: WSL独立インスタンスインポート
# ==========================================================
elseif ($Mode -eq "Instance") {
    Write-Host "`n--- [方式B] WSL2 独立インスタンス ($Name) の構築 ---" -ForegroundColor Cyan

    $existingDistros = wsl --list --quiet 2>$null
    if ($existingDistros -contains $Name) {
        $confirm = Read-Host "既存のWSLインスタンス '$Name' が存在します。削除して再作成しますか？ (y/N)"
        if ($confirm -eq "y" -or $confirm -eq "Y") {
            Write-Host "既存インスタンス '$Name' を登録解除中..." -ForegroundColor Yellow
            wsl --terminate $Name 2>$null
            wsl --unregister $Name
            if (Test-Path $InstallDir) {
                Remove-Item -Recurse -Force $InstallDir
            }
        } else {
            Write-Host "処理を中断しました。" -ForegroundColor Red
            exit 0
        }
    }

    $tempDir = Join-Path $env:TEMP "XeStrataLab_temp_$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $InstallDir, $tempDir | Out-Null
    $tarPath = Join-Path $tempDir "ubuntu-rootfs.tar"

    try {
        Write-Host "[1/4] wslc で $DockerImage から rootfs を抽出中..." -ForegroundColor Yellow
        $tempContainer = "temp_xestrata_$(Get-Random)"
        wslc create --name $tempContainer $DockerImage | Out-Null
        wslc export $tempContainer -o $tarPath
        wslc remove $tempContainer | Out-Null

        Write-Host "[2/4] WSL2 へインスタンス '$Name' をインポート中..." -ForegroundColor Yellow
        wsl --import $Name $InstallDir $tarPath --version 2

    } finally {
        if (Test-Path $tempDir) {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }

    Write-Host "[3/4] インスタンス内部でセットアップを実行中 ($XeVersion)..." -ForegroundColor Yellow
    $scriptContent = Get-Content -Path $internalScriptPath -Raw | ForEach-Object { $_ -replace "\r\n", "`n" }
    $scriptContent | wsl -d $Name -e bash -c "cat > /tmp/internal-setup.sh && chmod +x /tmp/internal-setup.sh && /tmp/internal-setup.sh '$XeVersion' '$CudaVariant'"

    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host " [成功] WSL2 独立インスタンス版 XeStrataLab の構築が完了しました！" -ForegroundColor Green
    Write-Host ""
    Write-Host " 対話型セットアップを起動するコマンド:" -ForegroundColor Cyan
    Write-Host "   wsl -d $Name -e xestrata --setup" -ForegroundColor White
    Write-Host ""
    Write-Host " インスタンスのシェルに入るコマンド:" -ForegroundColor Cyan
    Write-Host "   wsl -d $Name" -ForegroundColor White
    Write-Host ""
    Write-Host " Web UI アクセス先 (Windows ブラウザ):" -ForegroundColor Cyan
    Write-Host "   http://127.0.0.1:8095" -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Green

    $runSetupNow = Read-Host "今すぐ対話型セットアップ (xestrata --setup) を起動しますか？ (Y/n)"
    if ($runSetupNow -ne "n" -and $runSetupNow -ne "N") {
        wsl -d $Name -e xestrata --setup
    }
}
