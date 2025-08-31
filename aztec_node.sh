#!/bin/bash
# aztec_node.sh - 节点运行 + 健康检测 + 日志保持在 screen

set -u
export PATH="$HOME/.aztec/bin:$PATH"

# -------- 配置 --------
L1_CHAIN_ID=11155111
STAKING_ASSET_HANDLER=0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2
NODE_NAME="aztec-node"
DATA_DIR="/root/.$NODE_NAME"
AZTEC_ENV="/root/aztec.env"

# 检测参数
LOG_TAIL_LINES=1000     # docker logs --tail N
DOCKER_TIMEOUT=20       # docker logs 超时（秒）
INSPECT_TIMEOUT=10      # docker inspect 超时（秒）
CHECK_INTERVAL=120      # 区块检测间隔（秒）
STUCK_THRESHOLD=10      # 本地区块连续 N 次不变 -> 认为卡住

# -------- 工具函数 --------
log() {
    local color="$1"; shift
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "\033[${color}m[${ts}] $*\033[0m"
}

# 导入环境
if [ -f "$AZTEC_ENV" ]; then
    source "$AZTEC_ENV"
    log 0 "成功导入环境变量文件"
else
    log 31 "错误: 未找到环境变量文件 $AZTEC_ENV"
    exit 1
fi

# 必要变量检查
required_vars=("BEACON_RPC" "L1_RPC_URL" "PRIVATE_KEY" "COINBASE")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        log 31 "错误: 环境变量 $var 未设置，请检查 $AZTEC_ENV"
        exit 1
    fi
done

TIMEOUT_CMD=$(command -v timeout || true)

# -------- 管理函数 --------
upgrade_node() {
    aztec-up >/dev/null 2>&1
}

start_node() {
    local c; c=$(get_aztec_container)
    if [ -n "$c" ]; then return 0; fi

    aztec start --node --archiver --sequencer \
        --network alpha-testnet \
        --l1-rpc-urls "$L1_RPC_URL" \
        --l1-consensus-host-urls "$BEACON_RPC" \
        --sequencer.validatorPrivateKeys "$PRIVATE_KEY" \
        --sequencer.coinbase "$COINBASE" \
        --p2p.p2pIp "$(curl -s ipv4.icanhazip.com)" \
        --data-directory "$DATA_DIR"
}

get_aztec_container() {
    docker ps -q --filter "name=aztec-start" | head -n1 || true
}

# -------- 检测状态数据 --------
LAST_LOCAL_BLOCK=""
STUCK_COUNT=0

# -------- 区块同步检测 --------
check_block_sync() {
    local container_id logs latest_block local_block diff
    container_id=$(get_aztec_container)
    if [ -z "$container_id" ]; then
        log 31 "节点未运行，调用 start_node..."
        start_node
        return
    fi

    if [ -n "$TIMEOUT_CMD" ]; then
        logs=$($TIMEOUT_CMD $DOCKER_TIMEOUT docker logs "$container_id" --tail "$LOG_TAIL_LINES" 2>&1 || true)
    else
        logs=$(docker logs "$container_id" --tail "$LOG_TAIL_LINES" 2>&1 || true)
    fi

    latest_block=$(echo "$logs" | grep -Eo '"blockNumber":[0-9]+' | tail -n1 | cut -d: -f2 || true)
    local_block=$(echo "$logs" | grep 'World state updated' | grep -Eo '"blockNumber":[0-9]+' | tail -n1 | cut -d: -f2 || true)

    if [[ "$latest_block" =~ ^[0-9]+$ && "$local_block" =~ ^[0-9]+$ ]]; then
        diff=$((latest_block - local_block))
        log 36 "最新区块: $latest_block, 本地区块: $local_block, 落后: $diff"

        if [ "$local_block" = "$LAST_LOCAL_BLOCK" ]; then
            STUCK_COUNT=$((STUCK_COUNT + 1))
        else
            STUCK_COUNT=0
            LAST_LOCAL_BLOCK="$local_block"
        fi

        if [ "$diff" -gt 10 ]; then
            log 31 "落后超过10个区块（$diff），重启节点..."
            docker rm -f "$container_id" >/dev/null 2>&1 || true
            sleep 5
            start_node
        elif [ $STUCK_COUNT -ge $STUCK_THRESHOLD ]; then
            log 31 "检测到本地区块连续 ${STUCK_COUNT} 次未变化，判断卡住，重启节点..."
            docker rm -f "$container_id" >/dev/null 2>&1 || true
            STUCK_COUNT=0
            sleep 5
            start_node
        fi
    else
        log 33 "暂时无法从日志获取区块高度"
        STUCK_COUNT=0
    fi
}

# -------- 健康检测 --------
check_health() {
    local container_id exit_code status
    container_id=$(get_aztec_container)
    if [ -z "$container_id" ]; then
        start_node
        return
    fi

    if [ -n "$TIMEOUT_CMD" ]; then
        exit_code=$($TIMEOUT_CMD $INSPECT_TIMEOUT docker inspect "$container_id" --format '{{.State.ExitCode}}' 2>/dev/null || echo "")
        status=$($TIMEOUT_CMD $INSPECT_TIMEOUT docker inspect "$container_id" --format '{{.State.Status}}' 2>/dev/null || echo "")
    else
        exit_code=$(docker inspect "$container_id" --format '{{.State.ExitCode}}' 2>/dev/null || echo "")
        status=$(docker inspect "$container_id" --format '{{.State.Status}}' 2>/dev/null || echo "")
    fi

    if [ "$status" = "exited" ]; then
        if [ "$exit_code" -eq 139 ] 2>/dev/null; then
            AZTEC_FILE="/root/.aztec/bin/aztec"
            if [ -f "$AZTEC_FILE" ] && ! grep -q 'NODE_OPTIONS' "$AZTEC_FILE"; then
                echo 'export NODE_OPTIONS="--max-old-space-size=3072"' | cat - "$AZTEC_FILE" > /tmp/.aztec_temp && mv /tmp/.aztec_temp "$AZTEC_FILE"
                chmod +x "$AZTEC_FILE"
            fi
        elif [ "$exit_code" -eq 1 ] 2>/dev/null; then
            rm -rf "$DATA_DIR"
        else
            upgrade_node
        fi
        docker rm -f "$container_id" >/dev/null 2>&1 || true
        start_node
    fi
}

# -------- 启动逻辑 --------
initial_container=$(get_aztec_container)
if [ -z "$initial_container" ]; then
    start_node
fi

# 健康检测线程：无限循环，不输出日志
(
    while true; do
        check_health
    done
) &

# 区块同步检测线程：每隔 CHECK_INTERVAL 输出日志
(
    while true; do
        check_block_sync
        sleep "$CHECK_INTERVAL"
    done
) &

# -------- 前台日志保持在 screen --------
while true; do
    container_id=$(get_aztec_container)
    if [ -n "$container_id" ]; then
        docker logs -f "$container_id"
    else
        sleep 5
    fi
done
