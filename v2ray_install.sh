#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用root用户运行此脚本"
    exit 1
fi

# 配置 BBR
echo "正在配置 BBR..."
cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p

# 验证 BBR 是否开启
if lsmod | grep bbr; then
    echo "BBR 已成功启用"
else
    echo "BBR 启用失败，请检查系统支持情况"
fi

# 交互式输入参数
read -p "请输入你的域名: " DOMAIN
while [[ -z "$DOMAIN" ]]; do
    read -p "域名不能为空，请重新输入: " DOMAIN
done

# 检查域名解析
echo "正在检查域名解析..."
DOMAIN_IP=$(dig +short ${DOMAIN})
SERVER_IP=$(curl -s ipv4.icanhazip.com)

if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    echo "警告：域名 ${DOMAIN} 解析到的IP ($DOMAIN_IP) 与服务器IP ($SERVER_IP) 不匹配"
    echo "请确保："
    echo "1. 已经正确设置域名解析"
    echo "2. 解析已经生效（可能需要等待几分钟到几小时）"
    read -p "是否继续安装？(y/n): " continue_install
    if [[ "$continue_install" != "y" && "$continue_install" != "Y" ]]; then
        echo "安装已取消"
        exit 1
    fi
fi

read -p "请输入你的邮箱: " EMAIL
while [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; do
    read -p "邮箱格式不正确，请重新输入: " EMAIL
done

# 端口输入和验证
read -p "请输入V2Ray端口 [默认17887]: " V2RAY_PORT
V2RAY_PORT=${V2RAY_PORT:-17887}
while ! [[ "$V2RAY_PORT" =~ ^[0-9]+$ ]] || [ "$V2RAY_PORT" -lt 1 ] || [ "$V2RAY_PORT" -gt 65535 ]; do
    read -p "端口必须是1-65535之间的数字，请重新输入: " V2RAY_PORT
done

read -p "请输入HTTPS端口 [默认443]: " HTTPS_PORT
HTTPS_PORT=${HTTPS_PORT:-443}
while ! [[ "$HTTPS_PORT" =~ ^[0-9]+$ ]] || [ "$HTTPS_PORT" -lt 1 ] || [ "$HTTPS_PORT" -gt 65535 ] || [ "$HTTPS_PORT" -eq "$V2RAY_PORT" ]; do
    read -p "端口必须是1-65535之间的数字且不能与V2Ray端口相同，请重新输入: " HTTPS_PORT
done

# 生成随机UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "已自动生成UUID: $UUID"

# 确认信息
echo "================================================"
echo "请确认以下信息："
echo "域名: $DOMAIN"
echo "邮箱: $EMAIL"
echo "V2Ray端口: $V2RAY_PORT"
echo "HTTPS端口: $HTTPS_PORT"
echo "UUID: $UUID"
echo "================================================"
read -p "信息确认无误？(y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消安装"
    exit 1
fi

# 提示配置云平台安全组
echo "================================================"
echo "请确保在云平台控制台配置以下端口："
echo "- TCP 80 端口 (证书申请用)"
echo "- TCP ${HTTPS_PORT} 端口 (HTTPS)"
echo "- TCP ${V2RAY_PORT} 端口 (V2Ray)"
echo "================================================"
read -p "已经配置好安全组规则了吗？(y/n): " sg_confirm
if [[ "$sg_confirm" != "y" && "$sg_confirm" != "Y" ]]; then
    echo "请配置好安全组规则后再继续"
    exit 1
fi

# 仅更新软件包列表并安装必要的包
echo "正在安装必要的包..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y curl wget unzip nginx certbot python3-certbot-nginx dnsutils

# 安装 V2Ray
echo "正在安装 V2Ray..."
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# 配置 V2Ray
echo "配置 V2Ray..."
cat > /usr/local/etc/v2ray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private", "geoip:cn"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:cn"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${V2RAY_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/api/streaming/8d4e9f"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

# 配置基础 Nginx
echo "配置基础 Nginx..."
cat > /etc/nginx/conf.d/v2ray.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 404;
    }
}
EOF

# 创建验证目录
mkdir -p /var/www/html/.well-known/acme-challenge
chmod -R 755 /var/www/html

# 重启 Nginx
systemctl restart nginx

# 等待 Nginx 完全启动
sleep 5

# 申请证书
echo "申请 SSL 证书..."
certbot --nginx -d ${DOMAIN} --email ${EMAIL} --agree-tos --non-interactive

# 检查证书是否成功申请
if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    echo "证书申请失败，请检查："
    echo "1. 域名解析是否正确"
    echo "2. 80端口是否可以访问"
    echo "3. 防火墙设置是否正确"
    exit 1
fi

# 配置完整的 Nginx（包含 SSL 和 V2Ray 配置）
cat > /etc/nginx/conf.d/v2ray.conf << EOF
server {
    listen ${HTTPS_PORT} ssl;
    server_name ${DOMAIN};
    
    ssl_certificate       /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key   /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    
    location /api/streaming/8d4e9f {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${V2RAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

# 检查 Nginx 配置
nginx -t

# 如果配置正确，重启服务
if [ $? -eq 0 ]; then
    echo "Nginx 配置检查通过，重启服务..."
    systemctl restart nginx
    systemctl restart v2ray
else
    echo "Nginx 配置有误，请检查配置文件"
    exit 1
fi

# 设置开机自启
systemctl enable v2ray
systemctl enable nginx

# 输出配置信息
echo "================================================"
echo "安装完成！"
echo "================================================"
echo "域名: ${DOMAIN}"
echo "HTTPS端口: ${HTTPS_PORT}"
echo "V2Ray端口: ${V2RAY_PORT}"
echo "UUID: ${UUID}"
echo "路径: /api/streaming/8d4e9f"
echo "传输协议: ws"
echo "TLS: 开启"
echo "BBR: 已启用"
echo "================================================"
echo "请保存好以上信息！"

# 最后检查服务状态
echo "检查服务状态..."
systemctl status v2ray --no-pager
systemctl status nginx --no-pager
