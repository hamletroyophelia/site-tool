#!/usr/bin/env bash
set -e

INSTALL_DIR="/opt/site-tool"
TARGET_BIN="/usr/local/bin/siteadd"

NGINX_CONF="/etc/nginx/nginx.conf"
CONF_DIR="/etc/nginx/conf.d"
SSL_BASE="/etc/nginx/ssl"

ACME_BIN="$HOME/.acme.sh/acme.sh"
if [ "$(id -u)" -eq 0 ]; then
  ACME_BIN="/root/.acme.sh/acme.sh"
fi

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

ensure_deps() {
  local need_install=0

  command -v curl >/dev/null 2>&1 || need_install=1
  command -v dig >/dev/null 2>&1 || need_install=1
  command -v python3 >/dev/null 2>&1 || need_install=1

  if [ "$need_install" -eq 1 ]; then
    echo "检测到缺少基础依赖,正在安装 curl dnsutils python3..."
    apt update
    apt install -y curl dnsutils python3
  fi
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

backup_nginx() {
  local name="$1"
  local backup="/root/nginx-backup-${name}-$(date +%F-%H%M%S).tar.gz"

  tar -czf "$backup" /etc/nginx
  echo "$backup"
}

restore_nginx_backup() {
  local backup="$1"

  if [ -f "$backup" ]; then
    echo "正在回滚 Nginx 配置..."
    tar -xzf "$backup" -C /
    echo "已回滚到备份: $backup"
  else
    echo "备份文件不存在,无法回滚: $backup"
  fi
}

safe_reload_nginx() {
  local backup="$1"

  echo
  echo "====== 测试 Nginx 配置 ======"

  if nginx -t; then
    echo "Nginx 配置测试通过,正在重载..."
    systemctl reload nginx
    echo "Nginx 已重载。"
  else
    echo
    echo "Nginx 配置测试失败!"
    restore_nginx_backup "$backup"

    echo
    echo "回滚后重新测试:"
    nginx -t || true

    echo
    echo "没有重载 Nginx。请检查上面的错误。"
    exit 1
  fi
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
    echo "请先去域名商添加 A 记录:"
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

ensure_acme() {
  if [ ! -x "$ACME_BIN" ]; then
    echo "没有找到 acme.sh: $ACME_BIN"
    echo "请先安装 acme.sh。"
    exit 1
  fi
}

issue_cert() {
  local domain="$1"
  local ssl_dir="${SSL_BASE}/${domain}"

  ensure_acme

  echo
  echo "====== 申请 SSL 证书 ======"

  mkdir -p "$ssl_dir"

  if [ -f "$ssl_dir/fullchain.pem" ] && [ -f "$ssl_dir/privkey.pem" ]; then
    echo "检测到已有证书:"
    echo "$ssl_dir/fullchain.pem"
    echo "$ssl_dir/privkey.pem"
    echo
    read -rp "是否重新申请证书? 输入 y 重新申请,直接回车则复用: " reissue

    if [[ ! "$reissue" =~ ^[Yy]$ ]]; then
      echo "复用现有证书。"
      return
    fi
  fi

  echo "临时停止 Nginx,用于 acme standalone 申请证书..."
  systemctl stop nginx

  set +e
  "$ACME_BIN" --issue --standalone -d "$domain" --keylength ec-256 --force
  local acme_status=$?
  set -e

  echo "启动 Nginx..."
  systemctl start nginx

  if [ "$acme_status" -ne 0 ]; then
    echo
    echo "证书申请失败。常见原因:"
    echo "1. DNS 还没生效"
    echo "2. 防火墙没放行 80"
    echo "3. 域名没有指向这台 VPS"
    echo
    exit 1
  fi

  "$ACME_BIN" --install-cert -d "$domain" --ecc \
    --fullchain-file "$ssl_dir/fullchain.pem" \
    --key-file "$ssl_dir/privkey.pem" \
    --reloadcmd "systemctl reload nginx"

  echo "证书已安装到: $ssl_dir"
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

if domain in "".join(lines):
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

lines.insert(insert_index, f"    {domain:<32} nginx_https;\n")

with open(path, "w") as f:
    f.writelines(lines)

print(f"已添加 {domain} 到 stream map。")
PY
}

remove_stream_map() {
  local domain="$1"

  echo
  echo "====== 从 Stream SNI 分流移除 ======"

  python3 - "$domain" "$NGINX_CONF" <<'PY'
import sys

domain = sys.argv[1]
path = sys.argv[2]

with open(path, "r") as f:
    lines = f.readlines()

new_lines = []
removed = 0

for line in lines:
    if domain in line and ("nginx_https" in line or "xray" in line):
        removed += 1
        continue
    new_lines.append(line)

with open(path, "w") as f:
    f.writelines(new_lines)

if removed:
    print(f"已从 stream map 移除 {domain}。")
else:
    print(f"没有在 stream map 找到 {domain},跳过。")
PY
}

ssl_proxy_part() {
  local upstream="$1"
  local upstream_host
  local upstream_scheme

  upstream_host="$(get_host_from_url "$upstream")"
  upstream_scheme="$(get_scheme_from_url "$upstream")"

  if [ "$upstream_scheme" = "https" ]; then
    cat <<NGINX
        proxy_ssl_server_name on;
        proxy_ssl_name $upstream_host;
NGINX
  fi
}

create_proxy_common_headers() {
  local host_header="$1"

  cat <<NGINX
        proxy_set_header Host $host_header;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "";

        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
NGINX
}

add_emby_proxy() {
  check_root

  clear
  echo "======================================"
  echo " 添加 Emby 普通反代"
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
  local conf_file
  local ssl_dir
  local backup

  upstream_host="$(get_host_from_url "$upstream")"
  conf_file="${CONF_DIR}/${domain}.conf"
  ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "反代域名: $domain"
  echo "Emby 源站: $upstream"
  echo "源站 Host: $upstream_host"
  echo

  read -rp "确认继续? 输入 y: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return

  backup="$(backup_nginx "$domain")"
  echo "Nginx 配置已备份到: $backup"

  check_dns "$domain"
  issue_cert "$domain"
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

    client_max_body_size 0;

    location / {
        proxy_pass $upstream;
$(ssl_proxy_part "$upstream")

$(create_proxy_common_headers "$upstream_host")

        proxy_buffering off;
        proxy_request_buffering off;
    }
}

$(create_http_redirect_block "$domain")
NGINX

  add_stream_map "$domain"
  safe_reload_nginx "$backup"

  echo
  echo "完成: https://$domain"
}

add_emby_split_proxy() {
  check_root

  clear
  echo "======================================"
  echo " 添加 Emby 前后端分离反代"
  echo "======================================"
  echo

  read -rp "请输入反代域名，例如 emby.254252.xyz: " domain
  read -rp "请输入主后端地址，例如 https://main.example.com: " main_upstream
  read -rp "请输入推流后端地址，例如 https://stream.example.com: " stream_upstream

  domain="$(normalize_domain "$domain")"
  main_upstream="$(normalize_url "$main_upstream")"
  stream_upstream="$(normalize_url "$stream_upstream")"

  if [ -z "$domain" ] || [ -z "$main_upstream" ] || [ -z "$stream_upstream" ]; then
    echo "域名、主后端、推流后端不能为空。"
    return
  fi

  if ! echo "$main_upstream" | grep -Eq '^https?://'; then
    echo "主后端必须以 http:// 或 https:// 开头。"
    return
  fi

  if ! echo "$stream_upstream" | grep -Eq '^https?://'; then
    echo "推流后端必须以 http:// 或 https:// 开头。"
    return
  fi

  local main_host
  local stream_host
  local conf_file
  local ssl_dir
  local backup

  main_host="$(get_host_from_url "$main_upstream")"
  stream_host="$(get_host_from_url "$stream_upstream")"
  conf_file="${CONF_DIR}/${domain}.conf"
  ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "反代域名: $domain"
  echo "主后端: $main_upstream"
  echo "推流后端: $stream_upstream"
  echo
  echo "说明:"
  echo "登录、海报、普通 API 走主后端。"
  echo "播放、转码、下载等大流量路径走推流后端。"
  echo

  read -rp "确认继续? 输入 y: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return

  backup="$(backup_nginx "$domain")"
  echo "Nginx 配置已备份到: $backup"

  check_dns "$domain"
  issue_cert "$domain"
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

    client_max_body_size 0;

    # Emby 推流、播放、下载、大流量路径
    location ~* ^/(emby/)?(Videos|Audio|Items/.*/(PlaybackInfo|Download)|LiveTv|Sync|Sessions/Playing) {
        proxy_pass $stream_upstream;
$(ssl_proxy_part "$stream_upstream")

$(create_proxy_common_headers "$stream_host")

        proxy_buffering off;
        proxy_request_buffering off;
    }

    # 其他页面、登录、海报、普通 API
    location / {
        proxy_pass $main_upstream;
$(ssl_proxy_part "$main_upstream")

$(create_proxy_common_headers "$main_host")

        proxy_buffering off;
        proxy_request_buffering off;
    }
}

$(create_http_redirect_block "$domain")
NGINX

  add_stream_map "$domain"
  safe_reload_nginx "$backup"

  echo
  echo "完成: https://$domain"
}

add_normal_proxy() {
  check_root

  clear
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
  local conf_file
  local ssl_dir
  local host_header
  local backup

  upstream_host="$(get_host_from_url "$upstream")"
  conf_file="${CONF_DIR}/${domain}.conf"
  ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "Host 头怎么传?"
  echo "1. 传访问域名: $domain    适合本地服务、Docker 服务"
  echo "2. 传后端域名: $upstream_host    适合外部网站反代"
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

  backup="$(backup_nginx "$domain")"
  echo "Nginx 配置已备份到: $backup"

  check_dns "$domain"
  issue_cert "$domain"
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

    client_max_body_size 100m;

    location / {
        proxy_pass $upstream;
$(ssl_proxy_part "$upstream")

$(create_proxy_common_headers "$host_header")
    }
}

$(create_http_redirect_block "$domain")
NGINX

  add_stream_map "$domain"
  safe_reload_nginx "$backup"

  echo
  echo "完成: https://$domain"
}

add_static_site() {
  check_root

  clear
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
  local backup

  conf_file="${CONF_DIR}/${domain}.conf"
  ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "网站域名: $domain"
  echo "网站目录: $webroot"
  echo

  read -rp "确认继续? 输入 y: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return

  backup="$(backup_nginx "$domain")"
  echo "Nginx 配置已备份到: $backup"

  mkdir -p "$webroot"
  chown -R www-data:www-data "$webroot" 2>/dev/null || true

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
  <p>请把静态文件上传到: $webroot</p>
</body>
</html>
HTML
  fi

  check_dns "$domain"
  issue_cert "$domain"
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
  safe_reload_nginx "$backup"

  echo
  echo "完成: https://$domain"
  echo "静态文件目录: $webroot"
}

add_php_site() {
  check_root

  clear
  echo "======================================"
  echo " 添加 PHP 网站"
  echo "======================================"
  echo

  read -rp "请输入网站域名，例如 blog.254252.xyz: " domain
  read -rp "请输入网站目录，例如 /var/www/blog: " webroot
  read -rp "请输入 PHP-FPM 地址，默认 unix:/run/php/php8.3-fpm.sock: " php_fpm

  domain="$(normalize_domain "$domain")"
  webroot="$(echo "$webroot" | sed 's#/$##')"
  php_fpm="${php_fpm:-unix:/run/php/php8.3-fpm.sock}"

  if [ -z "$domain" ] || [ -z "$webroot" ]; then
    echo "域名或网站目录不能为空。"
    return
  fi

  local conf_file
  local ssl_dir
  local backup

  conf_file="${CONF_DIR}/${domain}.conf"
  ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "网站域名: $domain"
  echo "网站目录: $webroot"
  echo "PHP-FPM: $php_fpm"
  echo

  read -rp "确认继续? 输入 y: " ok
  [[ "$ok" =~ ^[Yy]$ ]] || return

  backup="$(backup_nginx "$domain")"
  echo "Nginx 配置已备份到: $backup"

  mkdir -p "$webroot"
  chown -R www-data:www-data "$webroot" 2>/dev/null || true

  if [ ! -f "$webroot/index.php" ]; then
    cat > "$webroot/index.php" <<PHP
<?php
echo "<h1>$domain PHP 网站已创建成功</h1>";
echo "<p>请把 Typecho、WordPress 或其他 PHP 程序放到: $webroot</p>";
PHP
    chown www-data:www-data "$webroot/index.php" 2>/dev/null || true
  fi

  check_dns "$domain"
  issue_cert "$domain"
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

    location ~ ^/(var|config\.inc\.php)$ {
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
  safe_reload_nginx "$backup"

  echo
  echo "完成: https://$domain"
  echo "PHP 网站目录: $webroot"
}

scan_existing_configs() {
  clear
  echo "======================================"
  echo " 扫描现有 Nginx / 证书配置"
  echo "======================================"
  echo

  printf "%-28s %-12s %-32s %-42s %-8s %-8s\n" "域名" "类型" "配置文件" "后端/目录" "证书" "Stream"
  printf "%-28s %-12s %-32s %-42s %-8s %-8s\n" "----------------------------" "------------" "--------------------------------" "------------------------------------------" "--------" "--------"

  for conf in "$CONF_DIR"/*.conf; do
    [ -f "$conf" ] || continue

    domains="$(grep -E '^\s*server_name\s+' "$conf" | sed -E 's/^\s*server_name\s+//;s/;//' | tr ' ' '\n' | grep -v '^$' | sort -u)"

    for domain in $domains; do
      [ "$domain" = "_" ] && continue

      type="未知"
      backend="-"

      if grep -q "fastcgi_pass" "$conf"; then
        type="PHP网站"
        root_path="$(grep -E '^\s*root\s+' "$conf" | head -1 | sed -E 's/^\s*root\s+//;s/;//')"
        php_fpm="$(grep -E '^\s*fastcgi_pass\s+' "$conf" | head -1 | sed -E 's/^\s*fastcgi_pass\s+//;s/;//')"
        backend="${root_path} -> ${php_fpm}"
      elif grep -q "proxy_pass" "$conf"; then
        if grep -qiE "PlaybackInfo|Download|LiveTv|Sessions/Playing" "$conf"; then
          type="Emby分离"
        elif grep -qi "emby" "$conf"; then
          type="Emby反代"
        else
          type="普通反代"
        fi
        backend="$(grep -E '^\s*proxy_pass\s+' "$conf" | head -2 | sed -E 's/^\s*proxy_pass\s+//;s/;//' | paste -sd ',' -)"
      elif grep -q "try_files" "$conf" && grep -q "root" "$conf"; then
        type="静态网站"
        backend="$(grep -E '^\s*root\s+' "$conf" | head -1 | sed -E 's/^\s*root\s+//;s/;//')"
      elif grep -q "return 301" "$conf"; then
        type="跳转/伪装"
        backend="$(grep -E '^\s*return\s+' "$conf" | head -1 | sed -E 's/^\s*return\s+//;s/;//')"
      fi

      cert="无"
      if [ -f "${SSL_BASE}/${domain}/fullchain.pem" ] || [ -f "${SSL_BASE}/${domain}/privkey.pem" ]; then
        cert="有"
      elif grep -q "ssl_certificate" "$conf"; then
        cert="引用"
      fi

      stream="无"
      if grep -F "$domain" "$NGINX_CONF" 2>/dev/null | grep -q "nginx_https"; then
        stream="有"
      elif grep -F "$domain" "$NGINX_CONF" 2>/dev/null | grep -q "xray"; then
        stream="Xray"
      fi

      short_conf="$(basename "$conf")"
      printf "%-28s %-12s %-32s %-42s %-8s %-8s\n" "$domain" "$type" "$short_conf" "${backend:0:42}" "$cert" "$stream"
    done
  done

  echo
  echo "====== acme.sh 证书列表 ======"
  if [ -x "$ACME_BIN" ]; then
    "$ACME_BIN" --list || true
  else
    echo "未找到 acme.sh: $ACME_BIN"
  fi

  echo
  echo "====== /etc/nginx/ssl 证书目录 ======"
  ls -1 "$SSL_BASE" 2>/dev/null || echo "没有找到 $SSL_BASE"
}

list_sites() {
  clear
  echo "======================================"
  echo " 当前站点配置"
  echo "======================================"
  echo

  echo "conf.d 配置文件:"
  ls -1 "$CONF_DIR"/*.conf 2>/dev/null | sed 's#^#  #' || echo "  没有找到 .conf 文件"

  echo
  echo "Stream map 中的 nginx_https / xray 域名:"
  grep -E 'nginx_https;|xray;' "$NGINX_CONF" 2>/dev/null | sed 's#^#  #' || echo "  没有找到记录"
}

delete_site_config() {
  check_root

  local force_delete_cert="${1:-no}"

  clear
  echo "======================================"
  echo " 删除站点配置"
  echo "======================================"
  echo

  read -rp "请输入要删除的域名，例如 emby2.254252.xyz: " domain
  domain="$(normalize_domain "$domain")"

  if [ -z "$domain" ]; then
    echo "域名不能为空。"
    return
  fi

  local conf_file="${CONF_DIR}/${domain}.conf"
  local ssl_dir="${SSL_BASE}/${domain}"
  local backup
  local del_cert=""

  echo
  echo "将删除:"
  echo "Nginx 配置: $conf_file"
  echo "Stream map: $domain"
  echo

  if [ "$force_delete_cert" = "yes" ]; then
    del_cert="y"
    echo "证书也会一起删除:"
    echo "$ssl_dir"
  else
    echo "证书目录:"
    echo "$ssl_dir"
    read -rp "是否同时删除证书? 输入 y 删除证书,直接回车保留: " del_cert
  fi

  echo
  read -rp "确认删除站点 $domain ? 输入 DELETE 继续: " confirm

  if [ "$confirm" != "DELETE" ]; then
    echo "已取消。"
    return
  fi

  backup="$(backup_nginx "delete-${domain}")"
  echo "Nginx 配置已备份到: $backup"

  rm -f "$conf_file"
  remove_stream_map "$domain"

  if [[ "$del_cert" =~ ^[Yy]$ ]]; then
    echo
    echo "正在删除 acme.sh 证书记录和证书目录..."

    if [ -x "$ACME_BIN" ]; then
      "$ACME_BIN" --remove -d "$domain" --ecc 2>/dev/null || true
      "$ACME_BIN" --remove -d "$domain" 2>/dev/null || true
    fi

    rm -rf "$ssl_dir"
    rm -rf "/root/.acme.sh/${domain}_ecc"
    rm -rf "/root/.acme.sh/${domain}"
  fi

  safe_reload_nginx "$backup"

  echo
  echo "删除完成: $domain"
}

delete_cert_only() {
  check_root

  clear
  echo "======================================"
  echo " 删除证书"
  echo "======================================"
  echo

  read -rp "请输入要删除证书的域名: " domain
  domain="$(normalize_domain "$domain")"

  if [ -z "$domain" ]; then
    echo "域名不能为空。"
    return
  fi

  local ssl_dir="${SSL_BASE}/${domain}"

  echo
  echo "将删除:"
  echo "证书目录: $ssl_dir"
  echo "acme.sh 记录: $domain"
  echo
  echo "注意: 不会删除 Nginx 站点配置。"
  echo "如果该站点还在使用证书,删除后 nginx -t 可能失败。"
  echo

  read -rp "确认删除证书? 输入 DELETE 继续: " confirm

  if [ "$confirm" != "DELETE" ]; then
    echo "已取消。"
    return
  fi

  if [ -x "$ACME_BIN" ]; then
    "$ACME_BIN" --remove -d "$domain" --ecc 2>/dev/null || true
    "$ACME_BIN" --remove -d "$domain" 2>/dev/null || true
  fi

  rm -rf "$ssl_dir"
  rm -rf "/root/.acme.sh/${domain}_ecc"
  rm -rf "/root/.acme.sh/${domain}"

  echo "证书已删除: $domain"
}

cert_issue_menu() {
  check_root

  clear
  echo "======================================"
  echo " 申请/重装证书"
  echo "======================================"
  echo

  read -rp "请输入域名: " domain
  domain="$(normalize_domain "$domain")"

  if [ -z "$domain" ]; then
    echo "域名不能为空。"
    return
  fi

  check_dns "$domain"
  issue_cert "$domain"
}

cert_list() {
  clear
