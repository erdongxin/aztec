#!/bin/bash
echo "=== aztec_zhuce.sh 脚本启动 ==="

set -e

ENV_FILE="/root/aztec.env"

# 加载环境变量
source <(grep '=' "$ENV_FILE" | sed 's/ *= */=/g')

if [[ -z "$L1_RPC_URL" || -z "$COINBASE" || -z "$PRIVATE_KEY" ]]; then
  echo "❌ 缺少必要的环境变量，请检查 $ENV_FILE"
  exit 1
fi

# 参数
STAKING_HANDLER="0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2"
CHAIN_ID=11155111

# 注册函数
register_validator() {
  echo "🚀 正在尝试注册 Aztec L1 Validator... ($(date))"
  aztec add-l1-validator \
    --l1-rpc-urls "$L1_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --attester "$COINBASE" \
    --proposer-eoa "$COINBASE" \
    --staking-asset-handler "$STAKING_HANDLER" \
    --l1-chain-id "$CHAIN_ID"
}

# 执行注册并输出显示
OUTPUT=$(register_validator | tee /dev/tty)

# 解析 ValidatorQuotaFilledUntil 错误中的时间戳
if echo "$OUTPUT" | grep -q "ValidatorQuotaFilledUntil("; then
  TS=$(echo "$OUTPUT" | grep -oP 'ValidatorQuotaFilledUntil\(\K[0-9]+' | head -n1)

  if [[ -z "$TS" ]]; then
    echo "❌ 无法解析 ValidatorQuotaFilledUntil 时间戳"
    echo "$OUTPUT"
    exit 1
  fi

  NOW=$(date +%s)
  WAIT=$((TS - NOW - 5))

  if [ "$WAIT" -le 0 ]; then
    echo "⚠️ 配额时间已到或过期，立即重试注册..."
    register_validator
    exit 0
  fi

  AT=$(date -d "@$TS")
  echo "⏳ 当前时间：$(date)"
  echo "⌛ Validator 配额释放时间：$AT"
  echo "🕐 将在 $WAIT 秒后重试注册（提前5秒）..."
  sleep "$WAIT"

  echo "🔁 尝试重新注册 Validator ($(date))"
  register_validator
else
  echo "✅ 注册返回，无需延迟处理："
  echo "$OUTPUT"
fi

