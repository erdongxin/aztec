#!/bin/bash
set -o pipefail
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

# 升级节点
upgrade_node() {
    echo -e "\033[0;33m尝试升级节点...\033[0m"
    aztec-up
    if [ $? -eq 0 ]; then
        echo -e "\033[0;32m✓ 节点升级成功\033[0m"
    else
        echo -e "\033[0;31m✗ 节点升级失败\033[0m"
    fi
}

# 启动节点（后台运行）
start_node() {
    echo -e "\033[0;34m[$(date '+%Y-%m-%d %H:%M:%S')] 正在启动节点...\033[0m"
    aztec start --node --archiver --sequencer \
        --network alpha-testnet \
        --l1-rpc-urls "$L1_RPC_URL" \
        --l1-consensus-host-urls "$BEACON_RPC" \
        --sequencer.validatorPrivateKeys "$PRIVATE_KEY" \
        --sequencer.coinbase "$COINBASE" \
        --p2p.p2pIp "$(curl -s ipv4.icanhazip.com)" \
        --data-directory "$DATA_DIR" &
    NODE_PID=$!
    echo -e "\033[0;32m节点已启动 (PID=$NODE_PID)\033[0m"
}

# 获取当前 aztec 容器 ID
get_aztec_container() {
    container_id=$(docker ps -q --filter "name=aztec-start")
    echo "$container_id"
}

# 区块同步检查
check_block_sync() {
    {
        container_id=$(get_aztec_container)
        if [ -z "$container_id" ]; then
            echo -e "\033[0;31m节点未运行，调用 start_node...\033[0m"
            start_node
            return
        fi

        # 限制日志范围，防止超大输出
        logs=$(docker logs "$container_id" --tail 1000 2>&1)

        latest_block=$(echo "$logs" | tac | grep -m1 -Eo '"blockNumber":[0-9]+' | awk -F: '{print $2}')
        local_block=$(echo "$logs" | tac | grep -m1 'World state updated' | grep -Eo '"blockNumber":[0-9]+' | awk -F: '{print $2}')

        if [[ "$latest_block" =~ ^[0-9]+$ && "$local_block" =~ ^[0-9]+$ ]]; then
            diff=$((latest_block - local_block))
            echo -e "\033[0;36m[$(date '+%Y-%m-%d %H:%M:%S')] 最新区块: $latest_block, 本地区块: $local_block, 落后: $diff\033[0m"

            if [ "$diff" -gt 10 ]; then
                echo -e "\033[0;31m落后超过10个区块，正在重启节点...\033[0m"
                docker rm -f "$container_id" >/dev/null 2>&1 || true
                sleep 5
                start_node
            fi
        else
            echo -e "\033[0;33m[$(date '+%Y-%m-%d %H:%M:%S')] 无法从日志获取区块高度 (latest=$latest_block, local=$local_block)\033[0m"
        fi
    } || echo -e "\033[0;31mcheck_block_sync 执行出错，但脚本已忽略继续运行\033[0m"
}

# 健康检查
check_health() {
    {
        container_id=$(get_aztec_container)
        if [ -z "$container_id" ]; then
            return
        fi

        exit_code=$(docker inspect "$container_id" --format '{{.State.ExitCode}}' 2>/dev/null || echo "")
        status=$(docker inspect "$container_id" --format '{{.State.Status}}' 2>/dev/null || echo "")

        if [ "$status" == "exited" ]; then
            echo -e "\033[0;31m容器退出 (退出码: $exit_code)\033[0m"

            if [ "$exit_code" -eq 139 ]; then
                echo -e "\033[0;31m检测到内存溢出，修复配置...\033[0m"
                AZTEC_FILE="/root/.aztec/bin/aztec"
                if ! grep -q 'export NODE_OPTIONS="--max-old-space-size=3072"' "$AZTEC_FILE"; then
                    echo 'export NODE_OPTIONS="--max-old-space-size=3072"' | cat - "$AZTEC_FILE" > temp && mv temp "$AZTEC_FILE"
                    chmod +x "$AZTEC_FILE"
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
                fi
                sleep 5
            elif [ "$exit_code" -eq 1 ]; then
                echo -e "\033[0;33m同步失败，删除数据目录重启...\033[0m"
                rm -rf "$DATA_DIR"
                sleep 5
            else
                echo -e "\033[0;33m异常退出，尝试升级...\033[0m"
                upgrade_node
                sleep 5
            fi

            docker rm -f "$container_id"
            start_node
        else
            echo -e "\033[0;32m[$(date '+%Y-%m-%d %H:%M:%S')] 节点正常运行，健康检查通过 (容器ID: $container_id)\033[0m"
        fi

    } || echo -e "\033[0;31mcheck_health 执行出错，但脚本已忽略继续运行\033[0m"
}

# -------------------------
# 主程序
# -------------------------

# 初次启动节点
initial_container=$(get_aztec_container)
if [ -z "$initial_container" ]; then
    start_node
    # 等待容器创建
    while [ -z "$(get_aztec_container)" ]; do
        echo -e "\033[0;33m等待节点容器创建...\033[0m"
        sleep 5
    done
fi

# 启动检测线程
(
    while true; do
        sleep 60
        check_health
        check_block_sync 
    done
) &

# 等待节点前台输出，日志可见于screen
wait $NODE_PID
