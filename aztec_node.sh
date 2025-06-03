#!/bin/bash

# 公共环境变量
L1_CHAIN_ID=11155111
STAKING_ASSET_HANDLER=0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2
NODE_NAME="aztec-node"

# 导入aztec.env文件，并检测否存在BEACON_RPC/L1_RPC_URL/PRIVATE_KEY/COINBASE


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
