#!/usr/bin/env bash
set -e

INSTALL_DIR="/opt/site-tool"
TARGET_BIN="/usr/local/bin/siteadd"

REPO_RAW="https://raw.githubusercontent.com/hamletroyophelia/site-tool/main"
MAIN_SCRIPT_URL="$REPO_RAW/site-tool.sh"

echo "======================================"
echo " siteadd 网站/Nginx 管理工具安装器"
echo "======================================"
echo

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 用户运行"
  exit 1
fi

mkdir -p "$INSTALL_DIR"

echo "正在下载主脚本..."
curl -fsSL "$MAIN_SCRIPT_URL" -o "$INSTALL_DIR/site-tool.sh"

chmod +x "$INSTALL_DIR/site-tool.sh"

echo "正在安装命令: siteadd"
ln -sf "$INSTALL_DIR/site-tool.sh" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

echo
echo "安装完成!"
echo
echo "以后直接输入:"
echo "  siteadd"
echo
