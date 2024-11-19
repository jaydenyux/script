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

# 获取服务器IP
SERVER_IP=$(curl -s ipv4.icanhazip.com)
echo "当前服务器IP: ${SERVER_IP}"

# 生成随机端口
generate_random_port() {
    while true; do
        PORT=$(shuf -i 10000-65000 -n 1)
        if ! netstat -tuln | grep -q ":$PORT "; then
            echo $PORT
            break
        fi
    done
}

# 选择传输协议
echo "请选择传输协议："
echo "1. TCP (默认)"
echo "2. mKCP"
echo "3. QUIC"
read -p "请输入选项 [1-3]: " PROTOCOL_CHOICE
case $PROTOCOL_CHOICE in
    2) PROTOCOL="mkcp";;
    3) PROTOCOL="quic";;
    *) PROTOCOL="tcp";;
esac

# 设置端口
read -p "是否使用随机端口? (y/n): " USE_RANDOM_PORT
if [[ "$USE_RANDOM_PORT" == "y" || "$USE_RANDOM_PORT" == "Y" ]]; then
    V2RAY_PORT=$(generate_random_port)
    echo "已生成随机端口: $V2RAY_PORT"
else
    read -p "请输入V2Ray端口 [默认17887]: " V2RAY_PORT
    V2RAY_PORT=${V2RAY_PORT:-17887}
    while ! [[ "$V2RAY_PORT" =~ ^[0-9]+$ ]] || [ "$V2RAY_PORT" -lt 1 ] || [ "$V2RAY_PORT" -gt 65535 ]; do
        read -p "端口必须是1-65535之间的数字，请重新输入: " V2RAY_PORT
    done
fi

# 设置用户数量
read -p "请输入需要创建的用户数量 [默认1]: " USER_COUNT
USER_COUNT=${USER_COUNT:-1}
while ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ] || [ "$USER_COUNT" -gt 50 ]; do
    read -p "用户数量必须是1-50之间的数字，请重新输入: " USER_COUNT
done

# 生成用户配置
USERS_CONFIG=""
declare -a USER_INFO
for ((i=1; i<=$USER_COUNT; i++)); do
    UUID=$(cat /proc/sys/kernel/random/uuid)
    USER_INFO+=("用户$i UUID: $UUID")
    if [ $i -eq $USER_COUNT ]; then
        USERS_CONFIG+="                    {\"id\": \"$UUID\", \"alterId\": 0}"
    else
        USERS_CONFIG+="                    {\"id\": \"$UUID\", \"alterId\": 0},\n"
    fi
done

# 确认信息
echo "================================================"
echo "请确认以下信息："
echo "服务器IP: ${SERVER_IP}"
echo "端口: ${V2RAY_PORT}"
echo "传输协议: ${PROTOCOL}"
echo "用户数量: ${USER_COUNT}"
echo "用户信息:"
for info in "${USER_INFO[@]}"; do
    echo "$info"
done
echo "================================================"
read -p "信息确认无误？(y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消安装"
    exit 1
fi

# 提示配置云平台安全组
echo "================================================"
echo "请确保在云平台控制台配置以下端口："
echo "- ${PROTOCOL} ${V2RAY_PORT} 端口"
echo "================================================"
read -p "已经配置好安全组规则了吗？(y/n): " sg_confirm
if [[ "$sg_confirm" != "y" && "$sg_confirm" != "Y" ]]; then
    echo "请配置好安全组规则后再继续"
    exit 1
fi

# 安装必要的包
echo "正在安装必要的包..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y curl wget unzip

# 安装 V2Ray
echo "正在安装 V2Ray..."
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# 生成协议特定的配置
STREAM_SETTINGS=""
case $PROTOCOL in
    "tcp")
        STREAM_SETTINGS='"network": "tcp"'
        ;;
    "mkcp")
        STREAM_SETTINGS='"network": "kcp", "kcpSettings": {"uplinkCapacity": 100, "downlinkCapacity": 100, "congestion": true, "seed": "v2ray"}'
        ;;
    "quic")
        STREAM_SETTINGS='"network": "quic", "quicSettings": {"security": "none", "key": "", "header": {"type": "none"}}'
        ;;
esac

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
      "listen": "0.0.0.0",
      "port": ${V2RAY_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
$(echo -e $USERS_CONFIG)
        ]
      },
      "streamSettings": {
        $STREAM_SETTINGS
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

# 启动服务
echo "启动 V2Ray 服务..."
systemctl restart v2ray

# 设置开机自启
systemctl enable v2ray

# 输出配置信息
echo "================================================"
echo "安装完成！"
echo "================================================"
echo "服务器IP: ${SERVER_IP}"
echo "端口: ${V2RAY_PORT}"
echo "传输协议: ${PROTOCOL}"
echo "================================================"
echo "用户配置信息："
for info in "${USER_INFO[@]}"; do
    echo "$info"
    echo "------------------------"
    echo "地址(address): ${SERVER_IP}"
    echo "端口(port): ${V2RAY_PORT}"
    echo "传输协议(network): ${PROTOCOL}"
    echo "加密方式(security): auto"
    echo "------------------------"
done
echo "================================================"
echo "请保存好以上信息！"

# 检查服务状态
echo "检查服务状态..."
systemctl status v2ray --no-pager
