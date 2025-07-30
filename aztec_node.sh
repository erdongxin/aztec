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

    aztec start --node --archiver --sequencer \
        --network alpha-testnet \
        --l1-rpc-urls "$L1_RPC_URL" \
        --l1-consensus-host-urls "$BEACON_RPC" \
        --sequencer.validatorPrivateKeys "$PRIVATE_KEY" \
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
        echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] 数据同步失败(退出码: $exit_code)\033[0m"
        echo -e "\033[0;33m删除数据目录后重新同步...删除目录 $DATA_DIR 中...\033[0m"
        rm -rf "$DATA_DIR"
        echo -e "\033[0;32m数据目录已删除，10秒后重启节点...\033[0m"
        sleep 10
    elif [ $exit_code -eq 139 ]; then
        echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] 内存溢出 (退出码: $exit_code)\033[0m"

        echo -e "\033[0;34m检查并修复内存参数配置...\033[0m"
    
        # 1. 修复 aztec 脚本中的 NODE_OPTIONS 设置
        AZTEC_FILE="/root/.aztec/bin/aztec"
        if ! grep -q 'export NODE_OPTIONS="--max-old-space-size=3072"' "$AZTEC_FILE"; then
            echo 'export NODE_OPTIONS="--max-old-space-size=3072"' | cat - "$AZTEC_FILE" > temp && mv temp "$AZTEC_FILE"
            chmod +x "$AZTEC_FILE"
            echo -e "\033[0;32m已修复 aztec 文件中的 NODE_OPTIONS 设置\033[0m"
        else
            echo -e "\033[0;32maztec 文件中的 NODE_OPTIONS 已正确设置\033[0m"
        fi
    
        # 2. 注入 NODE_OPTIONS 到 .aztec-run 的 ENV_VARS_TO_INJECT
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
            echo -e "\033[0;32m已注入 NODE_OPTIONS 到 .aztec-run 中的 ENV_VARS_TO_INJECT\033[0m"
        else
            echo -e "\033[0;32m.aztec-run 中已存在 NODE_OPTIONS 环境注入\033[0m"
        fi
    
        echo -e "\033[0;33m内存配置修复完成，5秒后重启脚本...\033[0m"
        sleep 5
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
