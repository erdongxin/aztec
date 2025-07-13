#!/bin/bash
export PATH="$HOME/.aztec/bin:$PATH"

# 公共环境变量
L1_CHAIN_ID=11155111
STAKING_ASSET_HANDLER=0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2
NODE_NAME="aztec-node"
DATA_DIR="/root/.$NODE_NAME"

# 导入环境变量
AZTEC_ENV="/root/aztec.env"
if [ -f "$AZTEC_ENV" ]; then
    source "$AZTEC_ENV"
    echo -e "\033[0;32m成功导入环境变量文件\033[0m"
else
    echo -e "\033[0;31m错误: 未找到环境变量文件 $AZTEC_ENV\033[0m"
    exit 1
fi

# 检查必要环境变量
required_vars=("BEACON_RPC" "L1_RPC_URL" "PRIVATE_KEY" "COINBASE")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "\033[0;31m错误: 环境变量 $var 未设置，请检查 aztec.env 文件。\033[0m"
        exit 1
    fi
done

# 升级函数
upgrade_node() {
    echo -e "\033[0;33m尝试升级节点...\033[0m"
    aztec-up
    if [ $? -eq 0 ]; then
        echo -e "\033[0;32m✓ 节点升级成功\033[0m"
    else
        echo -e "\033[0;31m✗ 节点升级失败\033[0m"
    fi
}

# 启动函数
start_node() {
    echo -e "\033[0;34m[$(date '+%Y-%m-%d %H:%M:%S')] 正在启动节点...\033[0m"
    export NODE_OPTIONS="--max-old-space-size=3072"

    aztec start --node --archiver --sequencer \
        --network alpha-testnet \
        --l1-rpc-urls "$L1_RPC_URL" \
        --l1-consensus-host-urls "$BEACON_RPC" \
        --sequencer.validatorPrivateKey "$PRIVATE_KEY" \
        --sequencer.coinbase "$COINBASE" \
        --p2p.p2pIp "$(curl -s ipv4.icanhazip.com)" \
        --data-directory "$DATA_DIR"
    return $?
}

# 主循环
while true; do
    start_node
    exit_code=$?

    if [ $exit_code -eq 1 ]; then
        echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] 检测到状态码1，删除数据目录后重新同步...\033[0m"
        echo -e "\033[0;33m删除数据目录 $DATA_DIR 中...\033[0m"
        rm -rf "$DATA_DIR"
        echo -e "\033[0;32m数据目录已删除，10秒后重启节点...\033[0m"
        sleep 10
    elif [ $exit_code -eq 139 ]; then
        echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] 内存溢出 (退出码: $exit_code)\033[0m"
        echo -e "\033[0;34m10秒后尝试重新启动节点...\033[0m"
        sleep 10
    elif [ $exit_code -ne 0 ]; then
        echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] 节点异常退出 (退出码: $exit_code)\033[0m"
        upgrade_node
        echo -e "\033[0;34m10秒后尝试重新启动节点...\033[0m"
        sleep 10
    else
        echo -e "\033[0;32m[$(date '+%Y-%m-%d %H:%M:%S')] 节点正常退出，10秒后重启...\033[0m"
        sleep 10
    fi

    # 删除占用的容器
    docker ps --format '{{.ID}} {{.Ports}}' | grep '0.0.0.0:8080' | awk '{print $1}' | xargs -r docker rm -f
done
