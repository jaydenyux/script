#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用root用户运行此脚本"
    exit 1
fi

# 交互式输入参数
read -p "请输入你的域名: " DOMAIN
while [[ -z "$DOMAIN" ]]; do
    read -p "域名不能为空，请重新输入: " DOMAIN
done

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

# 更新系统并安装必要的包
echo "正在更新系统并安装必要的包..."
apt update && apt upgrade -y
apt install -y curl wget unzip nginx certbot python3-certbot-nginx iptables

# 配置防火墙规则
echo "配置防火墙规则..."
iptables -I INPUT -p tcp --dport $HTTPS_PORT -j ACCEPT
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -p tcp --dport 22 -j ACCEPT

# 保存防火墙规则
apt install -y iptables-persistent
netfilter-persistent save
netfilter-persistent reload

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

# 配置 Nginx
echo "配置 Nginx..."
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

# 申请 SSL 证书
echo "申请 SSL 证书..."
certbot --nginx -d ${DOMAIN} --email ${EMAIL} --agree-tos --non-interactive

# 启动服务
echo "启动服务..."
systemctl restart v2ray
systemctl restart nginx

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
echo "================================================"
echo "请保存好以上信息！"
