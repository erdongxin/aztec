#!/bin/bash

command -v aztec >/dev/null 2>&1 || { echo "❌ 未找到 aztec 命令，请确保已正确安装 aztec-cli"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "❌ 未找到 Node.js，请先安装 Node.js"; exit 1; }

echo "=== aztec_zhuce.sh 脚本启动 ==="

set -e

ENV_FILE="/root/aztec.env"
WEBHOOK="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=20745fb3-d024-4856-9b95-4c97f3f283c8"

# 加载环境变量
source <(grep '=' "$ENV_FILE" | sed 's/ *= */=/g')

if [[ -z "$L1_RPC_URL" || -z "$COINBASE" || -z "$PRIVATE_KEY" ]]; then
  echo "❌ 缺少必要的环境变量，请检查 $ENV_FILE"
  exit 1
fi

STAKING_HANDLER="0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2"
CHAIN_ID=11155111
FORWARDER="0x44bF76535F0a7FA302D17edB331EB61eD705129d"

# 标准 aztec-cli 注册方法
register_validator_cli() {
  echo "📦 使用 aztec-cli 注册中..."
  aztec add-l1-validator \
    --l1-rpc-urls "$L1_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --attester "$COINBASE" \
    --proposer-eoa "$COINBASE" \
    --staking-asset-handler "$STAKING_HANDLER" \
    --l1-chain-id "$CHAIN_ID"
}

# 高 gas 自定义注册（内嵌 node 脚本）
register_validator_high_gas() {
  echo "⚙️ 使用 ethers.js 高 gas 注册器..."

  node <<EOF
const { ethers } = require("ethers");

const RPC_URL = "${L1_RPC_URL}";
const PRIVATE_KEY = "${PRIVATE_KEY}";
const COINBASE = "${COINBASE}";
const CONTRACT_ADDRESS = "${STAKING_HANDLER}";
const CHAIN_ID = ${CHAIN_ID};
const FORWARDER = "${FORWARDER}";

const ABI = [
  "function addValidator(address attester, address proposer, address forwarder)"
];

(async () => {
  const provider = new ethers.JsonRpcProvider(RPC_URL, CHAIN_ID);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

  const gasLimit = 12000000;
  const gasPrice = ethers.parseUnits("4500", "gwei"); // 高 gas，必要时可改大

  try {
    console.log("🚀 正在发送 addValidator...");
    const tx = await contract.addValidator(COINBASE, COINBASE, FORWARDER, {
      gasLimit,
      gasPrice,
    });
    console.log("✅ 已发送 TX:", tx.hash);
    const receipt = await tx.wait();
    console.log("🎉 成功确认! Block:", receipt.blockNumber);
  } catch (err) {
    console.error("❌ 自定义注册失败:", err.message || err);
  }
})();
EOF
}

# 先用 aztec-cli 尝试
OUTPUT=$(register_validator_cli | tee /dev/tty)

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
    echo "⚠️ 配额时间已到或过期，立即重试注册（高 gas）..."
    register_validator_high_gas
    exit 0
  fi

  AT=$(date -d "@$TS")
  echo "⏳ 当前时间：$(date)"
  echo "⌛ Validator 配额释放时间：$AT"
  echo "🕐 距离注册尝试还有 $WAIT 秒（提前5秒）..."

  # 分段等待提示
  INTERVAL=600  # 10分钟提示一次
  while [ "$WAIT" -gt 0 ]; do
    if [ "$WAIT" -le "$INTERVAL" ]; then
      sleep "$WAIT"
      break
    else
      sleep "$INTERVAL"
      WAIT=$((TS - $(date +%s) - 5))
      echo ""
      echo "======================================"
      echo "⏳ 当前时间：$(date)"
      echo "⌛ Validator 配额释放时间：$AT"
      echo "⏳ 仍需等待 $WAIT 秒..."
    fi
  done

  echo "🔁 尝试使用高优先级注册 Validator ($(date))"
  register_validator_high_gas
else
  # 成功直接发通知
  WECHAT_MSG="🎉 Aztec 注册成功！！\n时间：$(date)\n地址：$COINBASE"
  curl "$WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d '{
      "msgtype": "markdown",
      "markdown": {
        "content": "'"$WECHAT_MSG"'"
      }
    }'

  echo "✅ 注册成功！！！！！！！！！！"
  echo "$OUTPUT"
fi
