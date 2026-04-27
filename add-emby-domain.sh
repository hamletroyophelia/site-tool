#!/usr/bin/env bash
set -e

INSTALL_DIR="/opt/emby-tool"
TARGET_BIN="/usr/local/bin/embyadd"

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 用户运行"
    exit 1
  fi
}

uninstall_self() {
  check_root

  echo "======================================"
  echo " 卸载 embyadd 工具"
  echo "======================================"
  echo

  echo "即将删除:"
  echo "安装目录: $INSTALL_DIR"
  echo "命令链接: $TARGET_BIN"
  echo

  read -rp "确认卸载? 输入 y 继续: " CONFIRM
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "已取消"
    return
  fi

  rm -f "$TARGET_BIN"
  rm -rf "$INSTALL_DIR"

  echo
  echo "卸载完成。"
  echo "注意: 已创建的 Nginx 配置、SSL 证书、Emby 反代域名不会被删除。"
  exit 0
}

add_emby_domain() {
  check_root

  echo "======================================"
  echo " 添加新的 Emby 反代域名"
  echo "======================================"
  echo

  # 这里放你之前的完整添加脚本内容
  # 从 read -rp "请输入新的反代域名..." 开始
  # 到 nginx -t && systemctl reload nginx 结束

  echo "这里替换成添加 Emby 域名的完整逻辑"
}

main_menu() {
  while true; do
    clear
    echo "======================================"
    echo " Emby 反代域名工具"
    echo "======================================"
    echo
    echo "1. 添加新的 Emby 反代域名"
    echo "2. 卸载 embyadd 工具"
    echo "0. 退出"
    echo
    read -rp "请选择: " CHOICE

    case "$CHOICE" in
      1)
        add_emby_domain
        echo
        read -rp "按回车返回菜单..."
        ;;
      2)
        uninstall_self
        ;;
      0)
        echo "已退出"
        exit 0
        ;;
      *)
        echo "无效选择"
        sleep 1
        ;;
    esac
  done
}

main_menu
