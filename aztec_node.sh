#!/bin/bash
export PATH="$HOME/.aztec/bin:$PATH"

# 公共环境变量
L1_CHAIN_ID=11155111
STAKING_ASSET_HANDLER=0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2
NODE_NAME="aztec-node"


# 导入aztec.env文件
AZTEC_ENV="/root/aztec.env"
if [ -f "$AZTEC_ENV" ]; then
    source "$AZTEC_ENV"
    echo -e "\033[0;32m成功导入环境变量文件\033[0m"
else
    echo -e "\033[0;31m错误: 未找到环境变量文件 $AZTEC_ENV\033[0m"
    exit 1
fi

# 检查必要的环境变量
required_vars=("BEACON_RPC" "L1_RPC_URL" "PRIVATE_KEY" "COINBASE")
missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -ne 0 ]; then
    echo -e "\033[0;31m错误: 以下环境变量未设置: ${missing_vars[*]}，请先删除/root/aztec.env文件，并重新运行aztec.sh脚本 \033[0m"
    exit 1
fi

# 函数：启动节点
start_node() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动$NODE_NAME"
    aztec start --node --archiver --sequencer \
      --network alpha-testnet \
      --l1-rpc-urls "$L1_RPC_URL" \
      --l1-consensus-host-urls "$BEACON_RPC" \
      --sequencer.validatorPrivateKey "$PRIVATE_KEY" \
      --sequencer.coinbase "$COINBASE" \
      --p2p.p2pIp "$(curl -s ipv4.icanhazip.com)" \
      --data-directory "/root/.$NODE_NAME"

    # 获取aztec命令的退出状态
    local exit_code=${PIPESTATUS[0]}
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 节点进程退出，代码: $exit_code"
    return $exit_code
}

# 主循环
while true; do
    # 启动节点并捕获输出
    start_node

    # 检查退出状态
    if [ $? -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 节点正常退出"
        break
    else
        # 如果非正常退出，等待10秒后重启
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 节点异常退出，10秒后尝试重启..."
        sleep 10
    fi
done
