#!/bin/bash

echo "=== aztec_zhuce.sh 脚本启动：$(date) ==="

set -e

LOG_FILE="/root/aztec_zhuce.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# 自动时区适配，中文格式时间输出
format_time() {
  local ts=$1
  if [[ -z "$TZ" ]]; then
    date -d "@$ts" +"%Y年%m月%d日 %H时%M分%S秒 %Z"
  else
    TZ=$TZ date -d "@$ts" +"%Y年%m月%d日 %H时%M分%S秒 %Z"
  fi
}

# 环境检查
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

# 读取环境变量
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
  echo "📦 使用 aztec-cli 注册中..."
  aztec add-l1-validator \
    --l1-rpc-urls "$L1_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --attester "$COINBASE" \
    --proposer-eoa "$COINBASE" \
    --staking-asset-handler "$STAKING_HANDLER" \
    --l1-chain-id "$CHAIN_ID"
}

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
  "function addValidator(address attester, address forwarder)"
];

(async () => {
  const provider = new ethers.JsonRpcProvider(RPC_URL, CHAIN_ID);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

  const gasLimit = 200000;
  const gasPrice = ethers.parseUnits("100000", "gwei");

  try {
    console.log("🚀 正在发送 addValidator...");
    const tx = await contract.addValidator(COINBASE, FORWARDER, {
      gasLimit,
      gasPrice,
    });
    console.log("✅ 已发送 TX:", tx.hash);
    const receipt = await tx.wait();
    console.log("🎉 成功确认! Block:", receipt.blockNumber);
  } catch (err) {
    console.error("❌ 自定义注册失败:", err.message || err);
    process.exit(1);
  }
})();
EOF
}

# 注册循环逻辑
while true; do
  OUTPUT=$(register_validator_cli | tee /dev/tty)

  if echo "$OUTPUT" | grep -q "ValidatorQuotaFilledUntil("; then
    TS=$(echo "$OUTPUT" | grep -oP 'ValidatorQuotaFilledUntil\(\K[0-9]+' | head -n1)

    NOW=$(date +%s)
    DIFF=$((NOW - TS))

    if (( DIFF > 60 )); then
      echo "⚠️ 当前时间比配额释放晚了超过 1 分钟，可能错过注册，休息 1 小时后再试..."
      sleep 3600
      continue
    fi

    WAIT=$((TS - NOW - 1))
    (( WAIT < 0 )) && WAIT=0

    echo "⏳ 当前时间：$(format_time "$NOW")"
    echo "⌛ 配额释放时间：$(format_time "$TS")"
    echo "🕐 等待 $WAIT 秒后尝试高 gas 注册（提前 1 秒）..."
    sleep "$WAIT"

    if register_validator_high_gas; then
      curl "$WEBHOOK" \
        -H 'Content-Type: application/json' \
        -d '{
          "msgtype": "markdown",
          "markdown": {
            "content": "🎉 Aztec 高 gas 注册成功！\n时间：'"$(format_time $(date +%s))"'\n地址：'"$COINBASE"'"
          }
        }'
      echo "✅ 高 gas 注册成功，退出脚本。"
      exit 0
    else
      echo "❌ 高 gas 注册失败，继续下一轮循环..."
    fi
  else
    curl "$WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d '{
        "msgtype": "markdown",
        "markdown": {
          "content": "🎉 Aztec 普通注册成功！\n时间：'"$(format_time $(date +%s))"'\n地址：'"$COINBASE"'"
        }
      }'
    echo "✅ 普通注册成功，退出脚本。"
    exit 0
  fi
done
