# XeStrataLab 構築・運用手順書

Windowsホスト上のWSL環境（WSL2 / WSLコンテナー）を利用し、独立した専用環境で [XeStrata](https://github.com/MistVVK/XeStrata) を動作させるためのスクリプト群と解説ドキュメントです。
Docker Desktop等の外部ツールは使用せず、WindowsおよびWSLの標準機能のみで動作します。

---

## 目次
1. [概要と仕組み](#1-概要と仕組み)
2. [WSL2環境特有の技術情報と本スクリプトの対応内容](#2-wsl2環境特有の技術情報と本スクリプトの対応内容)
3. [動作要件](#3-動作要件)
4. [ホスト側の事前準備 (.wslconfig)](#4-ホスト側の事前準備-wslconfig)
5. [セットアップ手順](#5-セットアップ手順)
6. [日常の運用（起動と停止）](#6-日常の運用起動と停止)
7. [環境の完全破棄（アンインストール）](#7-環境の完全破棄アンインストール)
8. [ファイル構成](#8-ファイル構成)

---

## 1. 概要と仕組み

XeStrataは、MoE（Mixture of Experts）アーキテクチャの大規模言語モデルを、GPUのVRAMとホストRAMに分散配置して推論を行うエンジンです。動作環境としてUbuntu 26系が想定されています。

本リポジトリでは以下の2通りの実行方式を用意しています：

- **方式A: WSLコンテナー (`wslc`) 直接運用（推奨・既定値）**  
  WSL公式のコンテナーCLI（`wslc.exe`）を使用し、`ubuntu:26.04` イメージからコンテナーを起動して実行します。独立インスタンスを登録する必要がなく、不要になった際の破棄がコンテナー削除のみで完結します。
- **方式B: WSL2 独立インスタンスインポート**  
  `wslc` を用いて最小rootfsを展開し、`wsl --import` で専用のWSLディストリビューションとして登録します。通常のLinuxマシン（VM）としてシェル常駐させたい場合に利用できます。

---

## 2. WSL2環境特有の課題と適用したパッチの詳細

XeStrataはベアメタル（物理マシン直接インストール）のLinux環境を想定して設計されているため、WSL2およびWSLコンテナ環境では以下の3つの課題が生じます。本リポジトリではこれらを自動検出・修正するパッチを [internal-setup.sh](./internal-setup.sh) 内で自動適用しています。

### (1) GPU検出の失敗 (`/sys/class/drm` の不在)
- **問題の現象**:  
  `xestrata --check` や `xestrata --setup` 実行時に `[X] no NVIDIA GPU on NVIDIA's driver found` と出力されて停止する。
- **原因の技術的背景**:  
  XeStrataのハードウェア検出処理（`/usr/share/xestrata/setup.py` の `gpus()` 関数）は、Linux物理PCIデバイスのsysfsノード（`/sys/class/drm/card*`）を走査してGPUを特定します。  
  しかしWSL2環境では、GPUは物理PCIバス直結ではなくMicrosoftのDirectX仮想化ドライバ（`dxgkrnl` / `/dev/dxg`）経由でパススルーされるため、`/sys/class/drm` が存在しません。その結果、コンテナ内で `nvidia-smi` やCUDAドライバが正常に動いていても検出から漏れてしまいます。
- **適用したパッチ（差分）**:  
  sysfs走査で見つからなかった場合、`nvidia_smi()` を呼び出してGPU名・VRAM容量・Compute Capabilityを取得し、レンダーノードを `/dev/dxg` に紐付けるフォールバックを追加しました。

```python
# /usr/share/xestrata/setup.py の gpus() 関数へのパッチ
if not found and not nvidia and not amd:
    smi = nvidia_smi()
    for pci, info in smi.items():
        nvidia.append({
            "name": info.get("name", "NVIDIA GPU"),
            "vram_gb": info.get("mib", 0.0) / 1024,
            "device_id": 0,
            "driver": "nvidia",
            "integrated": False,
            "supported": True,
            "pci": pci,
            "bar_gb": info.get("mib", 0.0) / 1024,
            "link": "WSL2 GPU Passthrough",
            "render": "/dev/dxg",
            "vendor": "nvidia",
            "cc": info.get("cc")
        })
```

---

### (2) 推論エンジンのIllegal Memory Access (`CUDA_ERROR_ILLEGAL_ADDRESS`)
- **問題の現象**:  
  モデル読み込み時（`reading the model's weights`）に Unified Runtime (UR) がエラー700（`CUDA_ERROR_ILLEGAL_ADDRESS`）を出力してプロセスが異常終了する。
- **原因の技術的背景**:  
  XeStrataの推論エンジン本体（`strata` バイナリ）は、Intel SYCLコンパイラ（`intel/llvm`）およびUnified RuntimeのCUDAアダプター経由でGPU処理を行います。  
  ① 推奨ライブラリ `libcublas-13-1`（`libcublas.so.13`）が欠落していると独自の内製カーネルにフォールバックすること、  
  ② 巨大なMoEモデルの重みをホストRAM上に一括確保（`experts in RAM`）しようとすると、WSL2のUVM（Unified Virtual Memory）仮想化境界でメモリアクセス違反が生じること、  
  この2点が重なることで発生します。
- **適用した対策**:  
  1. `libcublas-13-1` を自動インストールし、`/etc/ld.so.conf.d/cuda-13-1.conf` にパスを通す。
  2. モデル設定（JSON）に `--mmap-experts`（Low-RAMモード）を適用する。これにより、頻繁に使われるExpertのみをVRAMスロット（約7〜9GB）に保持し、残りはファイルキャッシュ経由で読み出す動作になり、RAMの圧迫とメモリアクセス例外が解消されます。

---

### (3) Web UIへの接続遮断 (ループバックバインド `127.0.0.1`)
- **問題の現象**:  
  コンテナ内でサーバーが起動しているにもかかわらず、Windowsホスト側のブラウザから `http://127.0.0.1:8095` を開くと接続リセット（Connection reset）となる。
- **原因の技術的背景**:  
  XeStrataのAPIサーバー（`/usr/share/xestrata/serve/server.py`）の既定の待ち受けIPが `127.0.0.1`（コンテナ内ローカルホスト）に固定されているため、Windowsホストから転送されてきたパケットが拒否されます。
- **適用したパッチ**:  
  サーバー起動設定のホストバインドアドレスのデフォルト値を `0.0.0.0` に変更し、コンテナ外からの通信を受け付けるように修正しました。

```python
# /usr/share/xestrata/serve/server.py へのパッチ
# cfg.get("host") or "127.0.0.1" -> cfg.get("host") or "0.0.0.0"
```

---

## 3. 動作要件

- **OS**: Windows 11 または Windows 10
- **WSLバージョン**: 2.9.3以降（`wsl --version` で確認可能。`wslc.exe` が利用できる環境）
- **GPU**: NVIDIA GeForce / RTX シリーズ
  - 推奨VRAM: 12GB以上（例: RTX 3060 12GB, RTX 4070 12GB, RTX 3080/4080/3090/4090等）
  - アーキテクチャ: Turing世代以降（RTX 2000番台以降、Ada/Blackwell等）
- **ドライバ**: 最新のNVIDIA Windows Display Driver（GeForceドライバ）
- **Docker Desktop**: **不要**

---

## 4. ホスト側の事前準備 (.wslconfig)

MoEモデルの重みを扱うため、WSL2に対して適切なメモリとスワップ領域を割り当てます。

ユーザーディレクトリ（`C:\Users\<ユーザー名>\.wslconfig`）を作成または編集し、以下を記述します。

```ini
[wsl2]
memory=24GB
swap=16GB
```

※搭載RAMが64GBなど大容量の場合は、`memory=32GB` や `swap=24GB` など、より大きな値を割り当てることで余裕が生まれます。

記述後、PowerShellでWSLを再起動します。
```powershell
wsl --shutdown
```

---

## 5. セットアップ手順

リポジトリを配置したディレクトリでPowerShellを開き、スクリプトを実行します。

```powershell
# 既定のWSLコンテナー方式で環境を構築
.\setup-xestrata.ps1
```

### スクリプトの処理内容:
1. WSLおよび `wslc` の存在確認
2. `ubuntu:26.04` コンテナーの作成とGPUパススルー（`--gpus all`）、ポート（8095）の割り当て
3. 最小依存パッケージ（python3, curl, libgomp1, jq 等）および `libcublas-13-1` の導入
4. GitHub Releasesから最新版XeStrataのdebパッケージを取得・検証・インストール
5. 前述のWSL2対応パッチ（GPU認識、0.0.0.0バインド）を適用
6. 対話型セットアップ（`xestrata --setup`）の起動

### モデル選択について:
対話画面でダウンロードするモデルを選択します。VRAM 12GB環境（RTX 3060等）では、**`IQ1_M`** などの軽量な量子化形式、または32B規模のモデルが適しています。

---

## 6. 日常の運用（起動と停止）

日々の利用では、以下のショートカットスクリプトを使用できます。

### 起動する
```powershell
.\start.ps1
```
コンテナーを開始し、推論サーバーをバックグラウンドで起動します。  
起動後、Windowsのブラウザで以下を開いて利用します：

🔗 **http://127.0.0.1:8095**

### 停止する
```powershell
.\stop.ps1
```
推論サーバーとコンテナーを停止し、確保されていたGPU VRAMおよびRAMを解放します。

---

## 7. 環境の完全破棄（アンインストール）

LLMモデルはファイルサイズが大きいため（20GB〜数十GB）、検証終了後は以下のスクリプトで関連データを完全に削除できます。

```powershell
.\teardown-xestrata.ps1 -Mode All
```

- **コンテナー方式**: コンテナーを削除（モデルデータ含む領域が解放されます）。
- **インスタンス方式**: WSLインスタンスの登録解除（`wsl --unregister`）とローカルディレクトリ（`distro/`）を削除。

Windowsホスト側に不要な残留データは残らず、SSD容量が元の状態に戻ります。

---

## 8. ファイル構成

- **`setup-xestrata.ps1`**: 独立環境の初期構築を行うメインスクリプト（Windows側）
- **`internal-setup.sh`**: コンテナー/インスタンス内部で実行される依存関係導入およびパッチ適用スクリプト
- **`start.ps1`**: コンテナーおよび推論サーバーの起動スクリプト
- **`stop.ps1`**: 推論サーバーの停止およびコンテナー停止スクリプト
- **`teardown-xestrata.ps1`**: 作成した環境・モデルデータを完全消去するスクリプト
- **`.gitignore`**: 仮想ディスクや一時ダウンロードファイルをGit管理から除外する設定
