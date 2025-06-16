#!/bin/bash

set -e

ENV_FILE="/root/aztec.env"

# 从 .env 文件中提取变量
source <(grep '=' "$ENV_FILE" | sed 's/ *= */=/g')

# 检查变量是否存在
if [[ -z "$L1_RPC_URL" || -z "$COINBASE" || -z "$PRIVATE_KEY" ]]; then
  echo "❌ 缺少必要的环境变量，请检查 $ENV_FILE 是否包含 L1_RPC_URL, COINBASE 和 PRIVATE_KEY"
  exit 1
fi

# 注册参数
STAKING_HANDLER="0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2"
CHAIN_ID=11155111

# 注册函数
function register_validator() {
  aztec add-l1-validator \
    --l1-rpc-urls "$L1_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --attester "$COINBASE" \
    --proposer-eoa "$COINBASE" \
    --staking-asset-handler "$STAKING_HANDLER" \
    --l1-chain-id $CHAIN_ID 2>&1
}

# 执行注册
echo "🚀 正在尝试注册 Aztec L1 Validator..."
OUTPUT=$(register_validator)

echo "$OUTPUT" | grep -q "ValidatorQuotaFilledUntil"
if [ $? -ne 0 ]; then
  echo "✅ 注册成功或出现其他错误："
  echo "$OUTPUT"
  exit 0
fi

# 提取时间戳
TS=$(echo "$OUTPUT" | grep -oP 'ValidatorQuotaFilledUntil\(\K[0-9]+')

if [ -z "$TS" ]; then
  echo "❌ 无法提取 ValidatorQuotaFilledUntil 时间戳。原始输出："
  echo "$OUTPUT"
  exit 1
fi

# 当前时间戳
NOW=$(date +%s)
WAIT_SECS=$((TS - NOW - 5))

if [ "$WAIT_SECS" -le 0 ]; then
  echo "⚠️  时间已接近或过期，立即重试注册..."
  register_validator
  exit 0
fi

# 等待并重试
TARGET_TIME=$(date -d "@$TS")
echo "⏳ 配额释放时间为：$TARGET_TIME"
echo "⌛ 距离现在 $WAIT_SECS 秒，将在目标前 5 秒尝试注册..."

sleep "$WAIT_SECS"

echo "🔁 时间到，重新注册..."
register_validator
