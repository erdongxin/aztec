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

# 获取 aztec 容器 ID
get_aztec_container() {
    docker ps -q --filter "name=aztec-start" | head -n1 || true
}

# 全局变量
LAST_LOCAL_BLOCK=""
STUCK_COUNT=0
CHECK_INTERVAL=60
STUCK_THRESHOLD=10
LOG_TAIL_LINES=1000

check_block_sync() {
    local container_id
    while true; do
        container_id=$(get_aztec_container)
        if [ -z "$container_id" ]; then
            sleep "$CHECK_INTERVAL"
            continue
        fi

        logs=$(docker logs --tail "$LOG_TAIL_LINES" "$container_id" 2>&1 || true)
        latest_block=$(echo "$logs" | grep -Eo '"blockNumber":[0-9]+' | tail -n1 | cut -d: -f2 || true)
        local_block=$(echo "$logs" | grep 'World state updated' | grep -Eo '"blockNumber":[0-9]+' | tail -n1 | cut -d: -f2 || true)

        if [[ "$latest_block" =~ ^[0-9]+$ && "$local_block" =~ ^[0-9]+$ ]]; then
            diff=$((latest_block - local_block))
            printf "\033[0;34m[%s] [BLOCK_SYNC] 最新区块: %s, 本地区块: %s, 落后: %s\033[0m\n" "$(date '+%H:%M:%S')" "$latest_block" "$local_block" "$diff"

            if [ "$local_block" = "$LAST_LOCAL_BLOCK" ]; then
                STUCK_COUNT=$((STUCK_COUNT + 1))
            else
                STUCK_COUNT=0
                LAST_LOCAL_BLOCK="$local_block"
            fi

            # 落后超过10块或卡住超过阈值，删除容器触发主循环重启
            if [ "$diff" -gt 10 ] || [ $STUCK_COUNT -ge $STUCK_THRESHOLD ]; then
                printf "\033[0;31m[$(date '+%H:%M:%S')] [BLOCK_SYNC] 区块同步异常，删除容器触发主循环重启...\033[0m"
                STUCK_COUNT=0
                docker rm -f "$container_id" >/dev/null 2>&1 || true
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

check_block_sync &

# 主循环：健康检测
while true; do

    # 节点启动
    start_node
    # 异常退出将会走修复流程
    exit_code=$?

    if [ $exit_code -eq 1 ]; then
        echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] 数据同步失败(退出码: $exit_code)\033[0m"
        echo -e "\033[0;33m删除数据目录后重新同步...删除目录 $DATA_DIR ...\033[0m"
        rm -rf "$DATA_DIR"
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
