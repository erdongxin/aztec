#!/bin/bash
export PATH="$HOME/.aztec/bin:$PATH"

# 公共环境变量
L1_CHAIN_ID=11155111
STAKING_ASSET_HANDLER=0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2
NODE_NAME="aztec-node"
DATA_DIR="/root/.$NODE_NAME"

# 导入环境变量（不再要求 PRIVATE_KEY 和 COINBASE）
AZTEC_ENV="/root/aztec.env"
if [ -f "$AZTEC_ENV" ]; then
    source "$AZTEC_ENV"
    echo -e "\033[0;32m成功导入环境变量文件\033[0m"
else
    echo -e "\033[0;31m错误: 未找到环境变量文件 $AZTEC_ENV\033[0m"
    exit 1
fi

# 从 keystore JSON 读取私钥和 coinbase 地址
KEYSTORE_FILE="/root/.aztec/keystore/key1.json"
if [ ! -f "$KEYSTORE_FILE" ]; then
    echo -e "\033[0;31m错误: 未找到密钥文件 $KEYSTORE_FILE\033[0m"
    exit 1
fi

PRIVATE_KEY=$(jq -r '.validators[0].attester.eth' "$KEYSTORE_FILE")
COINBASE=$(jq -r '.validators[0].coinbase' "$KEYSTORE_FILE")

# 校验读取结果
if [ -z "$PRIVATE_KEY" ] || [ "$PRIVATE_KEY" = "null" ]; then
    echo -e "\033[0;31m错误: 无法从 $KEYSTORE_FILE 读取私钥\033[0m"
    exit 1
fi
if [ -z "$COINBASE" ] || [ "$COINBASE" = "null" ]; then
    echo -e "\033[0;31m错误: 无法从 $KEYSTORE_FILE 读取 coinbase 地址\033[0m"
    exit 1
fi

echo -e "\033[0;32m成功读取私钥和 coinbase 地址\033[0m"

# 检查其他必要环境变量
required_vars=("BEACON_RPC" "L1_RPC_URL")
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

# ====== 数据初始化 ======
init_data() {
    CACHE_DIR="/root/aztec-alpha-testnet"

    if [ ! -d "$CACHE_DIR/data" ]; then
        echo -e "\033[0;33m未检测到缓存数据，开始下载...\033[0m"
        apt install -y lz4
        wget https://files5.blacknodes.net/aztec/aztec-alpha-testnet.tar.lz4 -O /root/aztec-alpha-testnet.tar.lz4
        mkdir -p "$CACHE_DIR"
        lz4 -d /root/aztec-alpha-testnet.tar.lz4 | tar x -C "$CACHE_DIR"
        rm /root/aztec-alpha-testnet.tar.lz4
        echo -e "\033[0;32m缓存数据已就绪\033[0m"
    else
        echo -e "\033[0;32m检测到已有缓存数据，跳过下载\033[0m"
    fi

    mkdir -p /root/.aztec-node
    cp -r "$CACHE_DIR/data/"* /root/.aztec-node/
    echo -e "\033[0;32m数据已恢复到节点目录\033[0m"
}

# 删除函数
delete_node(){
    docker ps -a --filter "name=aztec" -q | xargs --no-run-if-empty docker rm -f
    rm -rf "$DATA_DIR"
}

# 启动函数
start_node() {
    echo -e "\033[0;34m[$(date '+%Y-%m-%d %H:%M:%S')] 正在启动节点...\033[0m"

    aztec start --node --archiver --sequencer \
        --network alpha-testnet \
        --l1-rpc-urls "$L1_RPC_URL" \
        --l1-consensus-host-urls "$BEACON_RPC" \
        --sequencer.validatorPrivateKeys "$PRIVATE_KEY" \
        --sequencer.coinbase "$COINBASE" \
        --p2p.p2pIp "$(curl -s ipv4.icanhazip.com)" \
        --snapshots-urls "https://snapshots.aztec.graphops.xyz/files/" \
        --data-directory "$DATA_DIR"
    return $?
}

# 主循环：健康检测
while true; do

    # 节点启动
    start_node
    # 异常退出将会走修复流程
    exit_code=$?

    if [ $exit_code -eq 1 ]; then
        echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] 数据同步失败(退出码: $exit_code)\033[0m"
        echo -e "\033[0;33m删除数据目录后重新同步...删除目录 $DATA_DIR ...\033[0m"
        delete_node
        init_data
        echo -e "\033[0;32m数据目录已删除，10秒后重启节点...\033[0m"
        sleep 10
    elif [ $exit_code -eq 139 ]; then
        echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] 内存溢出 (退出码: $exit_code)\033[0m"
        echo -e "\033[0;34m检查并修复内存参数配置...\033[0m"

        AZTEC_FILE="/root/.aztec/bin/aztec"
        if ! grep -q 'export NODE_OPTIONS="--max-old-space-size=3072"' "$AZTEC_FILE"; then
            echo 'export NODE_OPTIONS="--max-old-space-size=3072"' | cat - "$AZTEC_FILE" > temp && mv temp "$AZTEC_FILE"
            chmod +x "$AZTEC_FILE"
            echo -e "\033[0;32m已修复 aztec 文件中的 NODE_OPTIONS 设置\033[0m"
        fi

        AZTEC_RUN_FILE="/root/.aztec/bin/.aztec-run"
        INJECT_LINE='ENV_VARS_TO_INJECT+=" NODE_OPTIONS"'
        if ! grep -q 'ENV_VARS_TO_INJECT.*NODE_OPTIONS' "$AZTEC_RUN_FILE"; then
            awk -v inject="$INJECT_LINE" '
            BEGIN { inserted=0 }
            {
                print
                if (!inserted && $0 ~ /arg_env_vars=\("-e" "HOME=\$HOME"\)/) {
                    print inject
                    inserted=1
                }
            }' "$AZTEC_RUN_FILE" > temp && mv temp "$AZTEC_RUN_FILE"
            chmod +x "$AZTEC_RUN_FILE"
            echo -e "\033[0;32m已注入 NODE_OPTIONS 到 .aztec-run 中\033[0m"
        fi

        echo -e "\033[0;33m内存配置修复完成，5秒后重启脚本...\033[0m"
        sleep 5
    elif [ $exit_code -ne 0 ] && [ $exit_code -ne 137 ]; then
        echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] 节点异常退出 (退出码: $exit_code)\033[0m"
        upgrade_node
        echo -e "\033[0;34m10秒后尝试重新启动节点...\033[0m"
        sleep 10
    else
        echo -e "\033[0;32m[$(date '+%Y-%m-%d %H:%M:%S')] 节点正常退出，10秒后重启...\033[0m"
        sleep 10
    fi

    # 删除占用的容器（端口冲突）
    docker ps --format '{{.ID}} {{.Ports}}' | grep '0.0.0.0:8080' | awk '{print $1}' | xargs -r docker rm -f
done
