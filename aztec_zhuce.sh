#!/bin/bash

echo "=== aztec_zhuce.sh 脚本启动：$(date) ==="

set -e

LOG_FILE="/root/aztec_zhuce.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# === 检查 Node.js，如果没有则安装 ===
if ! command -v node &> /dev/null; then
  echo "🔧 正在安装 Node.js..."
  sudo apt update
  sudo apt install -y curl ca-certificates gnupg
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt install -y nodejs
  echo "✅ Node.js 安装完成：$(node -v)"
else
  echo "✅ Node.js 已安装：$(node -v)"
fi

# === 检查 aztec-cli 是否存在 ===
if ! command -v aztec &> /dev/null; then
  echo "❌ 未找到 aztec 命令，请确保已正确安装 aztec-cli"
  exit 1
fi

ENV_FILE="/root/aztec.env"
WEBHOOK="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=20745fb3-d024-4856-9b95-4c97f3f283c8"

# === 加载环境变量 ===
source <(grep '=' "$ENV_FILE" | sed 's/ *= */=/g')

if [[ -z "$L1_RPC_URL" || -z "$COINBASE" || -z "$PRIVATE_KEY" ]]; then
  echo "❌ 缺少必要环境变量，请检查 $ENV_FILE"
  exit 1
fi

# === 参数 ===
STAKING_HANDLER="0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2"
CHAIN_ID=11155111
FORWARDER="0x44bF76535F0a7FA302D17edB331EB61eD705129d"

# === 标准 aztec-cli 注册函数 ===
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

# === 高 gas 注册函数（内嵌 node 脚本）===
register_validator_high_gas() {
  echo "⚙️ 使用 ethers.js 高 gas 注册器..."
  if ! npm list ethers >/dev/null 2>&1; then
    echo "📦 安装 ethers 模块中..."
    npm install ethers
  fi
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
  const gasPrice = ethers.parseUnits("3750", "gwei"); // 自定义 gas

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

# === 注册执行逻辑 ===
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
  AT=$(date -d "@$TS")

  if [ "$WAIT" -le 0 ]; then
    echo "⚠️ 配额释放，立即执行高 gas 注册..."
    register_validator_high_gas
    exit 0
  fi

  echo "⏳ 当前时间：$(date)"
  echo "⌛ 配额释放时间：$AT"
  echo "🕐 还需等待 $WAIT 秒..."

  INTERVAL=600
  while [ "$WAIT" -gt 0 ]; do
    if [ "$WAIT" -le "$INTERVAL" ]; then
      sleep "$WAIT"
      break
    else
      sleep "$INTERVAL"
      WAIT=$((TS - $(date +%s) - 5))
      echo ""
      echo "=== ⏳ 当前时间：$(date) | 剩余等待 $WAIT 秒 ==="
    fi
  done

  echo "🔁 执行高 gas 注册：$(date)"
  register_validator_high_gas
else
  # 注册成功通知
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
