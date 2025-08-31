#!/bin/bash
# aztec_node.sh - 更稳健的节点 + 检测脚本
set -u
export PATH="$HOME/.aztec/bin:$PATH"

# -------- 配置 --------
L1_CHAIN_ID=11155111
STAKING_ASSET_HANDLER=0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2
NODE_NAME="aztec-node"
DATA_DIR="/root/.$NODE_NAME"
AZTEC_ENV="/root/aztec.env"

# 检测参数（可调）
LOG_TAIL_LINES=1000     # docker logs --tail N
DOCKER_TIMEOUT=20       # docker logs 超时（秒）
INSPECT_TIMEOUT=10      # docker inspect 超时（秒）
CHECK_INTERVAL=60       # 检测间隔（秒）
STUCK_THRESHOLD=10      # 本地区块连续 N 次不变 -> 认为卡住（N * CHECK_INTERVAL 秒）

# -------- 工具函数 --------
log() {
    local color="$1"; shift
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "\033[${color}m[${ts}] $*\033[0m"
}

# 导入环境
if [ -f "$AZTEC_ENV" ]; then
    # shellcheck disable=SC1090
    source "$AZTEC_ENV"
    log 0; echo -e "\033[0;32m成功导入环境变量文件\033[0m"
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

# timeout 可用性
TIMEOUT_CMD=$(command -v timeout || true)

# -------- 管理函数 --------
upgrade_node() {
    log 33 "尝试升级节点..."
    aztec-up
    if [ $? -eq 0 ]; then
        log 32 "✓ 节点升级成功"
    else
        log 31 "✗ 节点升级失败"
    fi
}

# 启动节点（防重复、后台）
start_node() {
    # 如果已有 aztec-start 容器，直接返回
    local c; c=$(get_aztec_container)
    if [ -n "$c" ]; then
        log 33 "发现已有容器 $c，跳过启动"
        return 0
    fi

    # 如果已有上次的 PID 且进程存在，跳过（防止重复后台）
    if [ -n "${NODE_PID:-}" ] && ps -p "$NODE_PID" >/dev/null 2>&1; then
        log 33 "发现已有节点进程 PID=$NODE_PID，跳过启动"
        return 0
    fi

    log 34 "正在启动节点..."
    aztec start --node --archiver --sequencer \
        --network alpha-testnet \
        --l1-rpc-urls "$L1_RPC_URL" \
        --l1-consensus-host-urls "$BEACON_RPC" \
        --sequencer.validatorPrivateKeys "$PRIVATE_KEY" \
        --sequencer.coinbase "$COINBASE" \
        --p2p.p2pIp "$(curl -s ipv4.icanhazip.com)" \
        --data-directory "$DATA_DIR" &
    NODE_PID=$!
    log 32 "节点已启动 (PID=$NODE_PID)"
    # 等待容器出现（最多等待 60 秒）
    local wait_sec=0
    while [ -z "$(get_aztec_container)" ] && [ $wait_sec -lt 60 ]; do
        log 33 "等待容器创建..."
        sleep 2
        wait_sec=$((wait_sec + 2))
    done
    if [ -n "$(get_aztec_container)" ]; then
        log 32 "容器创建成功: $(get_aztec_container)"
    else
        log 31 "等待容器超时（可能启动慢或出错），继续让进程在后台运行"
    fi
}

# 获取 aztec 容器（匹配 name 包含 aztec-start）
get_aztec_container() {
    # 取第一个匹配容器 id，避免返回多行
    docker ps -q --filter "name=aztec-start" | head -n1 || true
}

# -------- 检测状态数据（全局） --------
LAST_LOCAL_BLOCK=""
STUCK_COUNT=0

# -------- 检测函数（更稳） --------
check_block_sync() {
    {
        local container_id logs latest_block local_block diff
        container_id=$(get_aztec_container)
        if [ -z "$container_id" ]; then
            log 31 "节点未运行，调用 start_node..."
            start_node
            return
        fi

        # 带 timeout 获取最近若干行日志，防止阻塞
        if [ -n "$TIMEOUT_CMD" ]; then
            logs=$($TIMEOUT_CMD $DOCKER_TIMEOUT docker logs "$container_id" --tail "$LOG_TAIL_LINES" 2>&1 || true)
        else
            logs=$(docker logs "$container_id" --tail "$LOG_TAIL_LINES" 2>&1 || true)
        fi

        # 精确提取 blockNumber（只抓匹配片段），最后一条为最新
        latest_block=$(echo "$logs" | grep -Eo '"blockNumber":[0-9]+' | tail -n1 | cut -d: -f2 || true)
        local_block=$(echo "$logs" | grep 'World state updated' | grep -Eo '"blockNumber":[0-9]+' | tail -n1 | cut -d: -f2 || true)

        # 仅在都是纯数字时进行计算
        if [[ "$latest_block" =~ ^[0-9]+$ && "$local_block" =~ ^[0-9]+$ ]]; then
            diff=$((latest_block - local_block))
            log 36 "最新区块: $latest_block, 本地区块: $local_block, 落后: $diff"

            # 卡住检测：本地区块连续不变计数
            if [ "$local_block" = "$LAST_LOCAL_BLOCK" ]; then
                STUCK_COUNT=$((STUCK_COUNT + 1))
            else
                STUCK_COUNT=0
                LAST_LOCAL_BLOCK="$local_block"
            fi

            # 如果落后超过阀值或连续卡住超过阈值，重启
            if [ "$diff" -gt 10 ]; then
                log 31 "落后超过10个区块（$diff），正在重启节点..."
                docker rm -f "$container_id" >/dev/null 2>&1 || true
                sleep 5
                start_node
            elif [ $STUCK_COUNT -ge $STUCK_THRESHOLD ]; then
                log 31 "检测到本地区块已连续 ${STUCK_COUNT} 次未变化，判断卡住，重启节点..."
                docker rm -f "$container_id" >/dev/null 2>&1 || true
                STUCK_COUNT=0
                sleep 5
                start_node
            fi
        else
            log 33 "无法从日志获取区块高度 (latest=$latest_block, local=$local_block)"
            # 每次无法获取也应重置卡住计数，避免误判
            STUCK_COUNT=0
        fi
    } || log 31 "check_block_sync 执行出错，但脚本继续运行"
}

check_health() {
    {
        local container_id exit_code status
        container_id=$(get_aztec_container)
        if [ -z "$container_id" ]; then
            log 31 "未找到容器，节点可能未运行，调用 start_node..."
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
            log 31 "容器退出 (退出码: $exit_code)"

            if [ "$exit_code" -eq 139 ] 2>/dev/null; then
                log 31 "检测到内存溢出，修复配置..."
                # 修复 NODE_OPTIONS
                AZTEC_FILE="/root/.aztec/bin/aztec"
                if [ -f "$AZTEC_FILE" ] && ! grep -q 'export NODE_OPTIONS="--max-old-space-size=3072"' "$AZTEC_FILE"; then
                    echo 'export NODE_OPTIONS="--max-old-space-size=3072"' | cat - "$AZTEC_FILE" > /tmp/.aztec_temp && mv /tmp/.aztec_temp "$AZTEC_FILE"
                    chmod +x "$AZTEC_FILE"
                fi
                AZTEC_RUN_FILE="/root/.aztec/bin/.aztec-run"
                INJECT_LINE='ENV_VARS_TO_INJECT+=" NODE_OPTIONS"'
                if [ -f "$AZTEC_RUN_FILE" ] && ! grep -q 'ENV_VARS_TO_INJECT.*NODE_OPTIONS' "$AZTEC_RUN_FILE"; then
                    awk -v inject="$INJECT_LINE" '
                    BEGIN { inserted=0 }
                    {
                        print
                        if (!inserted && $0 ~ /arg_env_vars=\("-e" "HOME=\$HOME"\)/) {
                            print inject
                            inserted=1
                        }
                    }' "$AZTEC_RUN_FILE" > /tmp/.aztec_run_temp && mv /tmp/.aztec_run_temp "$AZTEC_RUN_FILE"
                    chmod +x "$AZTEC_RUN_FILE"
                fi
                sleep 5
            elif [ "$exit_code" -eq 1 ] 2>/dev/null; then
                log 33 "同步失败，删除数据目录重启..."
                rm -rf "$DATA_DIR"
                sleep 5
            else
                log 33 "异常退出，尝试升级..."
                upgrade_node
                sleep 5
            fi

            docker rm -f "$container_id" >/dev/null 2>&1 || true
            start_node
        else
            log 32 "节点正常运行，健康检查通过 (容器ID: $container_id)"
        fi
    } || log 31 "check_health 执行出错，但脚本继续运行"
}

# -------- 启动逻辑 --------
# 初次启动节点（如果没有容器）
initial_container=$(get_aztec_container)
if [ -z "$initial_container" ]; then
    start_node
    # 等待容器快速创建（最多 30 秒）
    local_wait=0
    while [ -z "$(get_aztec_container)" ] && [ $local_wait -lt 30 ]; do
        sleep 2
        local_wait=$((local_wait + 2))
    done
fi

# 启动检测线程（后台）
(
    # 首次等待短暂时间，避免和启动冲突
    sleep 5
    while true; do
        start_time=$(date +%s)
        check_health
        check_block_sync
        # 保持间隔约为 CHECK_INTERVAL（把检测耗时包含进来）
        elapsed=$(( $(date +%s) - start_time ))
        sleep_time=$(( CHECK_INTERVAL - elapsed ))
        if [ $sleep_time -gt 0 ]; then
            sleep $sleep_time
        fi
    done
) &

# 保持前台显示节点日志（如果我们有 PID，等待它）
if [ -n "${NODE_PID:-}" ]; then
    wait "$NODE_PID"
else
    # 如果没有 PID，就直接阻塞（防止 screen 会话退出）
    tail -f /dev/null
fi
