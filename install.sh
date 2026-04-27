#!/usr/bin/env bash
set -e

INSTALL_DIR="/opt/emby-tool"
TARGET_BIN="/usr/local/bin/embyadd"

REPO_RAW="https://raw.githubusercontent.com/你的用户名/emby-tool/main"
MAIN_SCRIPT_URL="$REPO_RAW/add-emby-domain.sh"

echo "======================================"
echo " Emby 反代域名工具安装器"
echo "======================================"

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 用户运行"
  echo "例如:"
  echo "sudo bash -c \"\$(curl -fsSL $REPO_RAW/install.sh)\""
  exit 1
fi

echo
echo "正在创建安装目录..."
mkdir -p "$INSTALL_DIR"

echo
echo "正在下载主脚本..."
curl -fsSL "$MAIN_SCRIPT_URL" -o "$INSTALL_DIR/add-emby-domain.sh"

chmod +x "$INSTALL_DIR/add-emby-domain.sh"

echo
echo "正在安装命令: embyadd"
ln -sf "$INSTALL_DIR/add-emby-domain.sh" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

echo
echo "安装完成!"
echo
echo "以后直接输入这个命令即可:"
echo
echo "  embyadd"
echo
