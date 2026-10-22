#!/usr/bin/env bash
# ============================================================
# ImmortalWrt + OpenClash 全自动部署与编译脚本
# 适用环境：PVE KVM 虚拟机 / Debian 13 (Trixie)
# 运行要求：普通用户（需具备 sudo 权限），请勿直接使用 root 运行
# ============================================================

set -euo pipefail

# ---------- 配置区 ----------
SRC_DIR="$HOME/immortalwrt-build"
IMM_REPO="https://github.com/immortalwrt/immortalwrt.git"
OPENCLASH_REPO="https://github.com/vernesong/OpenClash.git"

# ---------- 基础检查 ----------
if [[ $EUID -eq 0 ]]; then
  echo "❌ 请勿直接使用 root 运行！请用普通用户（如 openwrt）。"
  exit 1
fi
if ! sudo -v &>/dev/null; then
  echo "❌ 当前用户没有 sudo 权限。"
  exit 1
fi

echo "============================================"
echo " ImmortalWrt + OpenClash 终极一键部署脚本"
echo " 工作目录：$SRC_DIR"
echo "============================================"
read -rp "准备好开始了吗？[y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }

# ============================================================
# 步骤 1：交互式换源 (可选但强烈推荐)
# ============================================================
echo ""
echo "🌐 步骤 1/7：配置国内镜像源 (上海电信推荐选 1 或 2)"
echo "  1) 阿里云       2) 上海交大       3) 清华大学       0) 跳过换源"
read -rp "请选择 [0-3]: " MIRROR_CHOICE

if [[ "$MIRROR_CHOICE" != "0" ]]; then
  case "$MIRROR_CHOICE" in
    1) HOST="mirrors.aliyun.com" ;;
    2) HOST="mirror.sjtu.edu.cn" ;;
    3) HOST="mirrors.tuna.tsinghua.edu.cn" ;;
    *) echo "无效选择，默认使用阿里云。"; HOST="mirrors.aliyun.com" ;;
  esac
  
  echo "正在切换到 $HOST ..."
  BACKUP_DIR="/etc/apt/mirror-backup-$(date +%Y%m%d-%H%M%S)"
  sudo mkdir -p "$BACKUP_DIR"
  [[ -f /etc/apt/sources.list ]] && sudo cp /etc/apt/sources.list "$BACKUP_DIR"/ || true
  [[ -f /etc/apt/sources.list.d/debian.sources ]] && sudo cp /etc/apt/sources.list.d/debian.sources "$BACKUP_DIR"/ || true

  sudo tee /etc/apt/sources.list.d/debian.sources > /dev/null <<EOF
Types: deb deb-src
URIs: https://${HOST}/debian
Suites: trixie trixie-updates trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: https://${HOST}/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  sudo truncate -s 0 /etc/apt/sources.list
  echo "✅ 换源完成！备份在 $BACKUP_DIR"
fi

# ============================================================
# 步骤 2：安装编译依赖 (防弹窗防卡死)
# ============================================================
echo ""
echo "📦 步骤 2/7：安装编译依赖 (需要几分钟，请耐心等待)..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
  bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk \
  gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man intltool \
  lib32gcc-s1 libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev \
  libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev libssl-dev \
  libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs nano ninja-build \
  p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
  python3-pyelftools python3-setuptools qemu-utils re2c rsync scons squashfs-tools \
  subversion swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd
echo "✅ 依赖安装完成。"

# ============================================================
# 步骤 3：浅克隆 ImmortalWrt 源码
# ============================================================
echo ""
echo "📥 步骤 3/7：克隆 ImmortalWrt 源码 (浅克隆加速)..."
mkdir -p "$(dirname "$SRC_DIR")"
cd "$(dirname "$SRC_DIR")"
if [[ -d "$SRC_DIR" ]]; then
  echo "⚠️  目录 $SRC_DIR 已存在，跳过克隆。"
else
  git clone --depth 1 "$IMM_REPO" "$SRC_DIR"
fi
cd "$SRC_DIR"

# ============================================================
# 步骤 4：集成 OpenClash
# ============================================================
echo ""
echo "📥 步骤 4/7：下载 OpenClash 插件..."
if [[ -d "package/luci-app-openclash" ]]; then
  echo "⚠️  OpenClash 目录已存在，跳过下载。"
else
  git clone --depth 1 "$OPENCLASH_REPO" package/luci-app-openclash
fi

# ============================================================
# 步骤 5：Feeds 更新与安装
# ============================================================
echo ""
echo "🔄 步骤 5/7：更新并安装 Feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# ============================================================
# 步骤 6：预下载依赖包 (防中断机制)
# ============================================================
echo ""
echo "📦 步骤 6/7：预下载所有依赖包..."
# 针对容易出错的包使用单线程重试，避免并发过高导致镜像站 403 或拒绝连接
make download -j8 V=s || {
  echo ""
  echo "⚠️  部分软件包下载失败（如之前遇到的 elfutils 403 错误）。"
  echo "正在尝试使用单线程重新下载失败的包，这需要一点时间..."
  make download -j1 V=s || true
}
echo "✅ 预下载阶段结束 (少量包失败不影响后续编译，编译时会自动重试)。"

# ============================================================
# 步骤 7：菜单配置与正式编译
# ============================================================
echo ""
echo "============================================"
echo " 步骤 7/7：配置与编译"
echo "============================================"
echo "即将进入 make menuconfig，请务必完成以下设置："
echo "  1. Target System：选择架构 (如 x86)"
echo "  2. Target Profile：选择具体型号"
echo "  3. LuCI → Applications → luci-app-openclash：按 Y 选中 (*)"
echo "  4. (可选) Kernel modules → Network Support → kmod-tun：按 Y 选中 (*)"
echo "  5. 保存退出"
echo ""
read -rp "按回车进入 menuconfig ..."
make menuconfig

# 验证 .config 文件是否生成
if [[ ! -f ".config" ]]; then
  echo "❌ 未找到 .config，配置失败或未保存。"
  exit 1
fi

# 强制检查 OpenClash 是否选中
if ! grep -q '^CONFIG_PACKAGE_luci-app-openclash=y' .config; then
  echo "⚠️  警告：未检测到 luci-app-openclash 被选中，固件中将不包含 OpenClash！"
  read -rp "是否仍然继续编译？[y/N]: " GO
  [[ "$GO" =~ ^[Yy]$ ]] || exit 1
fi

echo ""
echo "🚀 开始正式编译 (使用 $(nproc) 核心)，如果内存不足，随时可按 Ctrl+C 中断，然后输入 'make -j2 V=s' 重新开始。"
echo "开始时间：$(date)"
make -j"$(nproc)" V=s

echo ""
echo "🎉 编译顺利完成！固件生成在："
find bin/targets -maxdepth 3 -type f \( -name "*.bin" -o -name "*.img.gz" -o -name "*.tar.gz" \) 2>/dev/null | head -20