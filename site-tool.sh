#!/usr/bin/env bash
set -e

INSTALL_DIR="/opt/site-tool"
TARGET_BIN="/usr/local/bin/siteadd"

NGINX_CONF="/etc/nginx/nginx.conf"
CONF_DIR="/etc/nginx/conf.d"
SSL_BASE="/etc/nginx/ssl"

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 用户运行"
    exit 1
  fi
}

pause() {
  echo
  read -rp "按回车返回菜单..."
}

backup_nginx() {
  local domain="$1"
  local backup="/root/nginx-backup-before-add-${domain}-$(date +%F-%H%M%S).tar.gz"
  tar -czf "$backup" /etc/nginx
  echo "Nginx 配置已备份到: $backup"
}

normalize_domain() {
  echo "$1" | sed 's#https://##;s#http://##;s#/$##'
}

normalize_url() {
  echo "$1" | sed 's#/$##'
}

get_host_from_url() {
  echo "$1" | sed -E 's#^https?://##;s#/.*$##;s#:.*$##'
}

get_scheme_from_url() {
  echo "$1" | sed -E 's#://.*$##'
}

check_dns() {
  local domain="$1"

  echo
  echo "====== 检查 DNS 解析 ======"

  local server_ip
  local domain_ip

  server_ip="$(curl -4 -s ifconfig.me || true)"
  domain_ip="$(dig +short "$domain" @8.8.8.8 | tail -n1 || true)"

  echo "当前 VPS IP: $server_ip"
  echo "$domain 解析到: $domain_ip"

  if [ -z "$domain_ip" ]; then
    echo
    echo "警告: $domain 还没有解析。"
    echo "请先去 Spaceship 添加 A 记录:"
    echo "主机名: ${domain%%.*}"
    echo "值: $server_ip"
    echo
    read -rp "如果你确认已经添加并想继续,输入 y: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || exit 1
  elif [ "$domain_ip" != "$server_ip" ]; then
    echo
    echo "警告: DNS 解析 IP 和当前 VPS IP 不一致。"
    echo "如果刚改 DNS,可以等 1-5 分钟再试。"
    echo
    read -rp "如果你确认没问题并想继续,输入 y: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || exit 1
  else
    echo "DNS 看起来正常。"
  fi
}

issue_cert() {
  local domain="$1"
  local ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "====== 申请 SSL 证书 ======"

  mkdir -p "$ssl_dir"

  echo "临时停止 Nginx,用于 acme standalone 申请证书..."
  systemctl stop nginx

  set +e
  ~/.acme.sh/acme.sh --issue --standalone -d "$domain" --keylength ec-256 --force
  local acme_status=$?
  set -e

  echo "启动 Nginx..."
  systemctl start nginx

  if [ "$acme_status" -ne 0 ]; then
    echo
    echo "证书申请失败。常见原因:"
    echo "1. DNS 还没生效"
    echo "2. DMIT 防火墙没放行 80"
    echo "3. 域名没有指向这台 VPS"
    echo
    exit 1
  fi

  ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
    --fullchain-file "$ssl_dir/fullchain.pem" \
    --key-file "$ssl_dir/privkey.pem" \
    --reloadcmd "systemctl reload nginx"

  echo "证书已安装到: $ssl_dir"
}

add_stream_map() {
  local domain="$1"

  echo
  echo "====== 添加到 Stream SNI 分流 ======"

  python3 - "$domain" "$NGINX_CONF" <<'PY'
import sys

domain = sys.argv[1]
path = sys.argv[2]

with open(path, "r") as f:
    lines = f.readlines()

text = "".join(lines)

if domain in text:
    print(f"{domain} 已存在于 nginx.conf,跳过添加。")
    sys.exit(0)

start = None
end = None

for i, line in enumerate(lines):
    if "map $ssl_preread_server_name $tcpsni_name" in line:
        start = i
        break

if start is None:
    print("没有找到 stream map: map $ssl_preread_server_name $tcpsni_name")
    sys.exit(1)

for i in range(start + 1, len(lines)):
    if lines[i].strip().startswith("}"):
        end = i
        break

if end is None:
    print("没有找到 stream map 的结束符 }")
    sys.exit(1)

insert_index = None
for i in range(start + 1, end):
    if lines[i].strip().startswith("default"):
        insert_index = i
        break

if insert_index is None:
    insert_index = end

lines.insert(insert_index, f"    {domain:<28} nginx_https;\n")

with open(path, "w") as f:
    f.writelines(lines)

print(f"已添加 {domain} 到 stream map。")
PY
}

reload_nginx() {
  echo
  echo "====== 测试并重载 Nginx ======"
  nginx -t
  systemctl reload nginx
  echo "Nginx 已重载。"
}

create_http_redirect_block() {
  local domain="$1"

  cat <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    return 301 https://\$host\$request_uri;
}
NGINX
}

confirm_overwrite() {
  local file="$1"

  if [ -f "$file" ]; then
    echo "检测到配置文件已存在: $file"
    read -rp "是否覆盖? 输入 y 覆盖: " overwrite
    [[ "$overwrite" =~ ^[Yy]$ ]] || exit 1
  fi
}

common_prepare() {
  local domain="$1"

  backup_nginx "$domain"
  check_dns "$domain"
  issue_cert "$domain"
}

add_emby_proxy() {
  check_root

  echo "======================================"
  echo " 添加 Emby 反代"
  echo "======================================"
  echo

  read -rp "请输入反代域名，例如 emby2.254252.xyz: " domain
  read -rp "请输入 Emby 源站地址，例如 https://iris.niceduck.lol: " upstream

  domain="$(normalize_domain "$domain")"
  upstream="$(normalize_url "$upstream")"

  if [ -z "$domain" ] || [ -z "$upstream" ]; then
    echo "域名或源站不能为空。"
    return
  fi

  if ! echo "$upstream" | grep -Eq '^https?://'; then
    echo "源站地址必须以 http:// 或 https:// 开头。"
    return
  fi

  local upstream_host
  local upstream_scheme
  local conf_file
  local ssl_dir

  upstream_host="$(get_host_from_url "$upstream")"
  upstream_scheme="$(get_scheme_from_url "$upstream")"
  conf_file="${CONF_DIR}/${domain}.conf"
  ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "反代域名: $domain"
  echo "Emby 源站: $upstream"
  echo "源站 Host: $upstream_host"
  echo

  read -rp "确认继续? 输入 y: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return

  common_prepare "$domain"
  confirm_overwrite "$conf_file"

  local ssl_proxy_part=""
  if [ "$upstream_scheme" = "https" ]; then
    ssl_proxy_part="
        proxy_ssl_server_name on;
        proxy_ssl_name $upstream_host;"
  fi

  cat > "$conf_file" <<NGINX
server {
    listen 127.0.0.1:8443 ssl proxy_protocol;
    http2 on;
    server_name $domain;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     $ssl_dir/fullchain.pem;
    ssl_certificate_key $ssl_dir/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 0;

    location / {
        proxy_pass $upstream;
$ssl_proxy_part

        proxy_set_header Host $upstream_host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "";

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
    }
}

$(create_http_redirect_block "$domain")
NGINX

  add_stream_map "$domain"
  reload_nginx

  echo
  echo "完成: https://$domain"
}

add_normal_proxy() {
  check_root

  echo "======================================"
  echo " 添加普通网站反代"
  echo "======================================"
  echo

  read -rp "请输入网站域名，例如 app.254252.xyz: " domain
  read -rp "请输入后端地址，例如 http://127.0.0.1:3000: " upstream

  domain="$(normalize_domain "$domain")"
  upstream="$(normalize_url "$upstream")"

  if [ -z "$domain" ] || [ -z "$upstream" ]; then
    echo "域名或后端地址不能为空。"
    return
  fi

  if ! echo "$upstream" | grep -Eq '^https?://'; then
    echo "后端地址必须以 http:// 或 https:// 开头。"
    return
  fi

  local upstream_host
  local upstream_scheme
  local conf_file
  local ssl_dir
  local host_header

  upstream_host="$(get_host_from_url "$upstream")"
  upstream_scheme="$(get_scheme_from_url "$upstream")"
  conf_file="${CONF_DIR}/${domain}.conf"
  ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "Host 头怎么传?"
  echo "1. 传访问域名: $domain    适合本地服务、Docker 服务"
  echo "2. 传后端域名: $upstream_host    适合反代外部网站"
  read -rp "请选择 [1/2],默认 1: " host_choice

  if [ "$host_choice" = "2" ]; then
    host_header="$upstream_host"
  else
    host_header="\$host"
  fi

  echo
  echo "网站域名: $domain"
  echo "后端地址: $upstream"
  echo "Host 头: $host_header"
  echo

  read -rp "确认继续? 输入 y: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return

  common_prepare "$domain"
  confirm_overwrite "$conf_file"

  local ssl_proxy_part=""
  if [ "$upstream_scheme" = "https" ]; then
    ssl_proxy_part="
        proxy_ssl_server_name on;
        proxy_ssl_name $upstream_host;"
  fi

  cat > "$conf_file" <<NGINX
server {
    listen 127.0.0.1:8443 ssl proxy_protocol;
    http2 on;
    server_name $domain;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     $ssl_dir/fullchain.pem;
    ssl_certificate_key $ssl_dir/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 100m;

    location / {
        proxy_pass $upstream;
$ssl_proxy_part

        proxy_set_header Host $host_header;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "";

        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
}

$(create_http_redirect_block "$domain")
NGINX

  add_stream_map "$domain"
  reload_nginx

  echo
  echo "完成: https://$domain"
}

add_static_site() {
  check_root

  echo "======================================"
  echo " 添加静态网站"
  echo "======================================"
  echo

  read -rp "请输入网站域名，例如 static.254252.xyz: " domain
  read -rp "请输入网站目录，例如 /var/www/static: " webroot

  domain="$(normalize_domain "$domain")"
  webroot="$(echo "$webroot" | sed 's#/$##')"

  if [ -z "$domain" ] || [ -z "$webroot" ]; then
    echo "域名或网站目录不能为空。"
    return
  fi

  local conf_file
  local ssl_dir

  conf_file="${CONF_DIR}/${domain}.conf"
  ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "网站域名: $domain"
  echo "网站目录: $webroot"
  echo

  read -rp "确认继续? 输入 y: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return

  mkdir -p "$webroot"
  chown -R www-data:www-data "$webroot" || true

  if [ ! -f "$webroot/index.html" ]; then
    cat > "$webroot/index.html" <<HTML
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>$domain</title>
</head>
<body>
  <h1>$domain 已创建成功</h1>
  <p>请把你的静态文件上传到: $webroot</p>
</body>
</html>
HTML
  fi

  common_prepare "$domain"
  confirm_overwrite "$conf_file"

  cat > "$conf_file" <<NGINX
server {
    listen 127.0.0.1:8443 ssl proxy_protocol;
    http2 on;
    server_name $domain;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     $ssl_dir/fullchain.pem;
    ssl_certificate_key $ssl_dir/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root $webroot;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|webp|svg|woff2?|ttf|eot|css|js)$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/atom+xml image/svg+xml;
    gzip_min_length 1024;
}

$(create_http_redirect_block "$domain")
NGINX

  add_stream_map "$domain"
  reload_nginx

  echo
  echo "完成: https://$domain"
  echo "静态文件目录: $webroot"
}

add_php_site() {
  check_root

  echo "======================================"
  echo " 添加 PHP 网站"
  echo "======================================"
  echo

  read -rp "请输入网站域名，例如 blog.254252.xyz: " domain
  read -rp "请输入网站目录，例如 /var/www/blog: " webroot
  read -rp "请输入 PHP-FPM 地址，默认 127.0.0.1:9000: " php_fpm

  domain="$(normalize_domain "$domain")"
  webroot="$(echo "$webroot" | sed 's#/$##')"
  php_fpm="${php_fpm:-127.0.0.1:9000}"

  if [ -z "$domain" ] || [ -z "$webroot" ]; then
    echo "域名或网站目录不能为空。"
    return
  fi

  local conf_file
  local ssl_dir

  conf_file="${CONF_DIR}/${domain}.conf"
  ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "网站域名: $domain"
  echo "网站目录: $webroot"
  echo "PHP-FPM: $php_fpm"
  echo

  read -rp "确认继续? 输入 y: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return

  mkdir -p "$webroot"
  chown -R www-data:www-data "$webroot" || true

  if [ ! -f "$webroot/index.php" ]; then
    cat > "$webroot/index.php" <<PHP
<?php
echo "<h1>$domain PHP 网站已创建成功</h1>";
echo "<p>请把 Typecho、WordPress 或其他 PHP 程序放到: $webroot</p>";
PHP
    chown www-data:www-data "$webroot/index.php" || true
  fi

  common_prepare "$domain"
  confirm_overwrite "$conf_file"

  cat > "$conf_file" <<NGINX
server {
    listen 127.0.0.1:8443 ssl proxy_protocol;
    http2 on;
    server_name $domain;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     $ssl_dir/fullchain.pem;
    ssl_certificate_key $ssl_dir/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root $webroot;
    index index.php index.html index.htm;

    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php(/|$) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        fastcgi_pass $php_fpm;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        include fastcgi_params;
        fastcgi_param REMOTE_ADDR \$remote_addr;
    }

    location ~ ^/(var|config\.inc\.php|install\.php|install)$ {
        deny all;
        return 404;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|webp|svg|woff2?|ttf|css|js)$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public";
    }

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/atom+xml image/svg+xml;
    gzip_min_length 1024;
}

$(create_http_redirect_block "$domain")
NGINX

  add_stream_map "$domain"
  reload_nginx

  echo
  echo "完成: https://$domain"
  echo "PHP 网站目录: $webroot"
}

uninstall_self() {
  check_root

  echo "======================================"
  echo " 卸载 siteadd 工具"
  echo "======================================"
  echo

  echo "即将删除:"
  echo "安装目录: $INSTALL_DIR"
  echo "命令链接: $TARGET_BIN"
  echo

  read -rp "确认卸载? 输入 y 继续: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return

  rm -f "$TARGET_BIN"
  rm -rf "$INSTALL_DIR"

  echo
  echo "卸载完成。"
  echo "注意: 不会删除已经创建的网站、Nginx 配置、SSL 证书。"
  exit 0
}

main_menu() {
  while true; do
    clear
    echo "======================================"
    echo " 网站/Nginx 反代添加工具"
    echo " 适用于 Nginx Stream SNI 分流架构"
    echo "======================================"
    echo
    echo "1. 添加 Emby 反代"
    echo "2. 添加普通网站反代"
    echo "3. 添加静态网站"
    echo "4. 添加 PHP 网站"
    echo "5. 卸载 siteadd 工具"
    echo "0. 退出"
    echo
    read -rp "请选择: " choice

    case "$choice" in
      1)
        add_emby_proxy
        pause
        ;;
      2)
        add_normal_proxy
        pause
        ;;
      3)
        add_static_site
        pause
        ;;
      4)
        add_php_site
        pause
        ;;
      5)
        uninstall_self
        ;;
      0)
        echo "已退出。"
        exit 0
        ;;
      *)
        echo "无效选择。"
        sleep 1
        ;;
    esac
  done
}

main_menu
