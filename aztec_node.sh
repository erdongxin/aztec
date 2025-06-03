#!/bin/bash

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

# 启动容器
echo "[🚀] 启动$NODE_NAME"
aztec start --node --archiver --sequencer \
  --network alpha-testnet \
  --l1-rpc-urls $L1_RPC_URL \
  --l1-consensus-host-urls $BEACON_RPC \
  --sequencer.validatorPrivateKey $PRIVATE_KEY \
  --sequencer.coinbase $COINBASE \
  --p2p.p2pIp $(curl -s ipv4.icanhazip.com) \
  --data-directory /root/.$NODE_NAME
