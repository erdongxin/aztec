#!/bin/bash

echo "=== aztec_zhuce.sh 脚本启动：$(date) ==="

set -e

LOG_FILE="/root/aztec_zhuce.log"
exec > >(tee -a "$LOG_FILE") 2>&1

if ! command -v node &> /dev/null; then
  echo "🔧 正在安装 Node.js..."
  sudo apt update
  sudo apt install -y curl ca-certificates gnupg
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt install -y nodejs
else
  echo "✅ Node.js 已安装：$(node -v)"
fi

if ! command -v aztec &> /dev/null; then
  echo "❌ 未找到 aztec 命令，请确保已正确安装 aztec-cli"
  exit 1
fi

ENV_FILE="/root/aztec.env"
WEBHOOK="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=20745fb3-d024-4856-9b95-4c97f3f283c8"

source <(grep '=' "$ENV_FILE" | sed 's/ *= */=/g')

if [[ -z "$L1_RPC_URL" || -z "$COINBASE" || -z "$PRIVATE_KEY" ]]; then
  echo "❌ 缺少必要环境变量，请检查 $ENV_FILE"
  exit 1
fi

STAKING_HANDLER="0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2"
CHAIN_ID=11155111
FORWARDER="0x44bF76535F0a7FA302D17edB331EB61eD705129d"

register_validator_cli() {
  echo "📦 使用 aztec-cli 普通注册中..."
  aztec add-l1-validator \
    --l1-rpc-urls "$L1_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --attester "$COINBASE" \
    --proposer-eoa "$COINBASE" \
    --staking-asset-handler "$STAKING_HANDLER" \
    --l1-chain-id "$CHAIN_ID"
}

register_validator_high_gas() {
  echo "⚙️ 使用 ethers.js 高 gas 注册器抢注册..."
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

const ABI = ["function addValidator(address attester, address forwarder)"];
const provider = new ethers.JsonRpcProvider(RPC_URL, CHAIN_ID);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

const gasLimit = 210000;
const gasPrice = ethers.parseUnits("200", "gwei");

const timeout = (ms) => new Promise((_, reject) => setTimeout(() => reject(new Error("⏱️ 等待超时")), ms));

(async () => {
  try {
    console.log("🚀 正在发送 addValidator...");
    const tx = await contract.addValidator(COINBASE, FORWARDER, {
      gasLimit,
      gasPrice,
    });
    console.log("✅ 已发送 TX:", tx.hash);

    const receipt = await Promise.race([
      tx.wait(),
      timeout(60000)
    ]);

    console.log("🎉 成功确认! Block:", receipt.blockNumber);
    process.exit(0);
  } catch (err) {
    console.error("❌ 高 gas 注册失败:", err.message || err);
    process.exit(1);
  }
})();
EOF
}

while true; do
  OUTPUT=$(register_validator_cli | tee /dev/tty)

  if echo "$OUTPUT" | grep -q "ValidatorQuotaFilledUntil("; then
    TS=$(echo "$OUTPUT" | grep -oE 'ValidatorQuotaFilledUntil\([0-9]+\)' | tail -n1 | grep -oE '[0-9]+')

    if [[ -z "$TS" || "$TS" -lt 1700000000 || "$TS" -gt 2000000000 ]]; then
      echo "❌ 无法解析 ValidatorQuotaFilledUntil 时间戳：$TS"
      exit 1
    fi

    NOW=$(date +%s)
    WAIT=$((TS - NOW - 1))  # 提前 1 秒
    [[ $WAIT -lt 0 ]] && WAIT=0
    AT=$(date -d "@$TS")

    echo "⏳ 当前时间：$(date)"
    echo "⌛ 配额释放时间：$AT"
    echo "🕐 等待 $WAIT 秒后抢高 gas 注册（提前 1 秒）..."

    sleep "$WAIT"

    echo "🚀 现在使用高 gas 注册尝试抢注..."
    if register_validator_high_gas; then
      echo "✅ 高 gas 注册成功，退出循环"
      WECHAT_MSG="🎉 Aztec 高 gas 注册成功！！\n时间：$(date)\n地址：$COINBASE"
      curl "$WEBHOOK" -H 'Content-Type: application/json' -d "{
        \"msgtype\": \"markdown\",
        \"markdown\": {\"content\": \"$WECHAT_MSG\"}
      }"
      exit 0
    else
      echo "⚠️ 高 gas 注册失败，马上用普通注册尝试，再继续循环..."
      # 失败后马上尝试一次普通注册
      register_validator_cli || true
      echo "🔄 继续等待下一轮配额释放..."
    fi

  else
    # 注册成功，发送通知，退出
    WECHAT_MSG="🎉 Aztec 注册成功！！\n时间：$(date)\n地址：$COINBASE"
    curl "$WEBHOOK" -H 'Content-Type: application/json' -d "{
      \"msgtype\": \"markdown\",
      \"markdown\": {\"content\": \"$WECHAT_MSG\"}
    }"
    echo "✅ 注册成功！退出脚本。"
    exit 0
  fi
done
