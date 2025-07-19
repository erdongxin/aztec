#!/bin/bash

command -v aztec >/dev/null 2>&1 || {
  echo "❌ 未找到 aztec 命令，请确保已正确安装 aztec-cli"
  exit 1
}

echo "=== aztec_zhuce.sh 脚本启动 ==="

ENV_FILE="/root/aztec.env"
WEBHOOK="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=20745fb3-d024-4856-9b95-4c97f3f283c8"

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
    --staking-asset-handler "$STAKING_HANDLER" \
    --l1-chain-id "$CHAIN_ID"
}

while true; do
  OUTPUT=$(register_validator 2>&1)
  EXIT_CODE=$?

  echo "$OUTPUT" | tee /dev/tty

  # 检查 CLI 报错是否为配额限制
  if echo "$OUTPUT" | grep -q "ValidatorQuotaFilledUntil("; then
    TS=$(echo "$OUTPUT" | grep -oP 'ValidatorQuotaFilledUntil\(\K[0-9]+' | head -n1)
    if [[ -z "$TS" ]]; then
      echo "⚠️ 未能解析时间戳，等待 10 分钟后重试"
      sleep 600
      continue
    fi

    NOW=$(date +%s)
    WAIT=$((TS - NOW - 5))
    [ "$WAIT" -lt 0 ] && WAIT=5

    AT=$(date -d "@$TS")
    echo "⏳ 当前时间：$(date)"
    echo "⌛ Validator 配额释放时间：$AT"
    echo "🕐 距离注册还有 $WAIT 秒..."

    INTERVAL=600
    while [ "$WAIT" -gt 0 ]; do
      if [ "$WAIT" -le "$INTERVAL" ]; then
        sleep "$WAIT"
        break
      else
        sleep "$INTERVAL"
        WAIT=$((TS - $(date +%s) - 5))
        echo "⏳ 剩余等待时间：$WAIT 秒..."
      fi
    done
    continue
  fi

  # 检查 TypeError 或其他崩溃信息
  if echo "$OUTPUT" | grep -qE "TypeError|Exception|Cannot read properties"; then
    echo "❌ CLI 内部错误，10 分钟后重试"
    sleep 600
    continue
  fi

  # 检查命令是否失败
  if [ "$EXIT_CODE" -ne 0 ]; then
    echo "❌ 命令执行失败 (exit $EXIT_CODE)，5 分钟后重试"
    sleep 300
    continue
  fi

  # 注册成功，发送通知
  WECHAT_MSG="Aztec 验证者注册成功！！！！！！！！！！\n 成功时间：$(date)\n 注册地址：$COINBASE"
  curl -s "$WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d '{
      "msgtype": "markdown",
      "markdown": {
        "content": "'"$WECHAT_MSG"'"
      }
    }'

  echo "✅ 注册成功！！！！！！！！！！"
  break
done
