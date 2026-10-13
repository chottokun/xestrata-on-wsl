#!/usr/bin/env bash
set -euo pipefail

# XeStrataLab 内部セットアップスクリプト
# 実行環境: WSL2 / WSLコンテナ (XeStrataLab インスタンス内)

TARGET_VERSION="${1:-latest}"
CUDA_VARIANT="${2:-cuda13.1}"

echo "=========================================================="
echo " [XeStrataLab] インスタンス内部のセットアップを開始します"
echo " 指定バージョン : ${TARGET_VERSION}"
echo " CUDA バリアント: ${CUDA_VARIANT}"
echo "=========================================================="

# 1. GPU認識チェック
echo "[1/4] GPU (NVIDIA SMI) の認識を確認中..."
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi
    echo ">> NVIDIA GPU が正常に認識されています。"
else
    echo ">> [警告] nvidia-smi が見つかりません。WSLのCUDA連携を確認してください。"
fi

# 2. 最小限のパッケージをインストール (jq を追加して自動パース対応)
echo "[2/4] 必要パッケージ（最小限）をインストール中..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    python3 \
    libgomp1 \
    jq

# 3. XeStrata 最新リリース情報の取得 & deb パッケージ解決
XESTRATA_DIR="/opt/xestrata"
mkdir -p "${XESTRATA_DIR}"
cd "${XESTRATA_DIR}"

echo "[3/4] XeStrata リリース情報を取得中..."
if [ "${TARGET_VERSION}" = "latest" ]; then
    API_URL="https://api.github.com/repos/MistVVK/XeStrata/releases/latest"
else
    API_URL="https://api.github.com/repos/MistVVK/XeStrata/releases/tags/${TARGET_VERSION}"
fi

RELEASE_JSON=$(curl -fsSL "${API_URL}")
TAG_NAME=$(echo "${RELEASE_JSON}" | jq -r '.tag_name')

# 指定CUDAバリアントのdeb URLとSHA256SUMS URLを抽出
DEB_URL=$(echo "${RELEASE_JSON}" | jq -r --arg variant "${CUDA_VARIANT}" '.assets[] | select(.name | test($variant) and test("\\.deb$")) | .browser_download_url' | head -n 1)
DEB_NAME=$(basename "${DEB_URL}")
SHA_URL=$(echo "${RELEASE_JSON}" | jq -r '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' | head -n 1)

if [ -z "${DEB_URL}" ] || [ "${DEB_URL}" = "null" ]; then
    echo ">> [エラー] ${TAG_NAME} に一致する deb パッケージ (${CUDA_VARIANT}) が見つかりませんでした。"
    exit 1
fi

echo ">> 対象タグ   : ${TAG_NAME}"
echo ">> ダウンロード: ${DEB_NAME}"

curl -fsSL -O "${DEB_URL}"

# チェックサム検証（SHA256SUMS が存在する場合）
if [ -n "${SHA_URL}" ] && [ "${SHA_URL}" != "null" ]; then
    curl -fsSL -O "${SHA_URL}"
    echo ">> SHA256 チェックサムを検証中..."
    sha256sum -c SHA256SUMS --ignore-missing || echo ">> [注意] チェックサム検証で一致しないファイルがあるかスキップされました"
fi

# 4. インストール
echo "[4/4] XeStrata (${TAG_NAME}) および推奨 cuBLAS をインストール中..."
apt-get install -y --no-install-recommends libcublas-13-1
echo '/usr/local/cuda/targets/x86_64-linux/lib' > /etc/ld.so.conf.d/cuda-13-1.conf
ldconfig 2>/dev/null || true
apt-get install -y "./${DEB_NAME}"

# WSL2 / コンテナ対応パッチの適用（/sys/class/drm非依存化 & /dev/dxg認識）
echo ">> WSL2 GPU パススルー対応パッチを適用中..."
python3 -c "
target_file = '/usr/share/xestrata/setup.py'
with open(target_file, 'r') as f:
    content = f.read()

target = 'return found + [{\x22index\x22: len(found) + i, **g} for i, g in enumerate(nvidia + amd)]'
patch = '''    if not found and not nvidia and not amd:
        smi = nvidia_smi()
        for pci, info in smi.items():
            nvidia.append({
                \x22name\x22: info.get(\x22name\x22, \x22NVIDIA GPU\x22),
                \x22vram_gb\x22: info.get(\x22mib\x22, 0.0) / 1024,
                \x22device_id\x22: 0,
                \x22driver\x22: \x22nvidia\x22,
                \x22integrated\x22: False,
                \x22supported\x22: True,
                \x22pci\x22: pci,
                \x22bar_gb\x22: info.get(\x22mib\x22, 0.0) / 1024,
                \x22link\x22: \x22WSL2 GPU Passthrough\x22,
                \x22render\x22: \x22/dev/dxg\x22,
                \x22vendor\x22: \x22nvidia\x22,
                \x22cc\x22: info.get(\x22cc\x22)
            })
    return found + [{\x22index\x22: len(found) + i, **g} for i, g in enumerate(nvidia + amd)]'''

if target in content:
    with open(target_file, 'w') as f:
        f.write(content.replace(target, patch, 1))
    print('>> WSL2 GPU パッチが正常に適用されました。')

# コンテナ外部（Windowsホスト）からアクセスできるように host のデフォルトを 0.0.0.0 に設定
server_file = '/usr/share/xestrata/serve/server.py'
with open(server_file, 'r') as f:
    s_content = f.read()
if 'cfg.get(\x22host\x22) or \x22127.0.0.1\x22' in s_content:
    s_content = s_content.replace('cfg.get(\x22host\x22) or \x22127.0.0.1\x22', 'cfg.get(\x22host\x22) or \x220.0.0.0\x22')
    with open(server_file, 'w') as f:
        f.write(s_content)
    print('>> 外部接続用ホスト設定 (0.0.0.0) を適用しました。')
"

echo "=========================================================="
echo " [XeStrataLab] インストールが完了しました！ (Version: ${TAG_NAME})"
echo " 次のコマンドで対話型セットアップを実行できます:"
echo "   xestrata --setup"
echo "=========================================================="
