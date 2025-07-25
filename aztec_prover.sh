#!/bin/bash
export PATH="$HOME/.aztec/bin:$PATH"

NODE_NAME="aztec-prover"
DATA_DIR="/root/.$NODE_NAME"
AZTEC_ENV="/root/aztec.env"

# 加载环境变量
if [ -f "$AZTEC_ENV" ]; then
    source "$AZTEC_ENV"
    echo -e "\033[0;32m✓ 成功导入环境变量文件 $AZTEC_ENV\033[0m"
else
    echo -e "\033[0;31m✗ 错误: 未找到环境变量文件 $AZTEC_ENV\033[0m"
    exit 1
fi

# 检查关键变量
required_vars=("ETHEREUM_HOSTS" "L1_CONSENSUS_HOST_URLS" "PROVER_PUBLISHER_PRIVATE_KEY" "PROVER_ID")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "\033[0;31m✗ 错误: 环境变量 $var 未设置，请检查 aztec.env 文件。\033[0m"
        exit 1
    fi
done

# 升级镜像
upgrade_images() {
    echo -e "\033[0;33m拉取最新镜像...\033[0m"
    docker pull aztecprotocol/aztec:latest
}

# 启动 Prover 节点（docker compose）
start_prover() {
    echo -e "\033[0;34m[$(date '+%Y-%m-%d %H:%M:%S')] 启动 Aztec Prover...\033[0m"
    
    cat > docker-compose.yml <<EOF
version: "3.8"
services:
  prover-node:
    image: aztecprotocol/aztec:latest
    command:
      - node
      - --no-warnings
      - /usr/src/yarn-project/aztec/dest/bin/index.js
      - start
      - --prover-node
      - --archiver
      - --network
      - alpha-testnet
    depends_on:
      broker:
        condition: service_started
    environment:
      NODE_OPTIONS: "--max-old-space-size=3072"
      DATA_DIRECTORY: /data
      DATA_STORE_MAP_SIZE_KB: "134217728"
      ETHEREUM_HOSTS: ${ETHEREUM_HOSTS}
      L1_CONSENSUS_HOST_URLS: ${L1_CONSENSUS_HOST_URLS}
      LOG_LEVEL: info
      PROVER_BROKER_HOST: http://broker:8080
      PROVER_PUBLISHER_PRIVATE_KEY: ${PROVER_PUBLISHER_PRIVATE_KEY}
    ports:
      - "8080:8080"
      - "40400:40400"
      - "40400:40400/udp"
    volumes:
      - ./node:/data

  agent:
    image: aztecprotocol/aztec:latest
    command:
      - node
      - --no-warnings
      - /usr/src/yarn-project/aztec/dest/bin/index.js
      - start
      - --prover-agent
      - --network
      - alpha-testnet
    environment:
      NODE_OPTIONS: "--max-old-space-size=3072"
      PROVER_AGENT_COUNT: "1"
      PROVER_AGENT_POLL_INTERVAL_MS: "10000"
      PROVER_BROKER_HOST: http://broker:8080
      PROVER_ID: ${PROVER_ID}
    restart: unless-stopped
    pull_policy: always

  broker:
    image: aztecprotocol/aztec:latest
    command:
      - node
      - --no-warnings
      - /usr/src/yarn-project/aztec/dest/bin/index.js
      - start
      - --prover-broker
      - --network
      - alpha-testnet
    environment:
      DATA_DIRECTORY: /data
      ETHEREUM_HOSTS: ${ETHEREUM_HOSTS}
      LOG_LEVEL: info
    volumes:
      - ./node:/data
EOF

    docker-compose up -d
    return $?
}

# 主循环
while true; do
    start_prover
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo -e "\033[0;31m✗ 启动失败 (退出码: $exit_code)\033[0m"
        echo -e "\033[0;33m尝试重新拉取镜像...\033[0m"
        upgrade_images
        echo -e "\033[0;34m10 秒后重试启动...\033[0m"
        sleep 10
    else
        echo -e "\033[0;32m✓ Prover 节点启动成功，监控中...\033[0m"
        docker-compose logs -f
    fi

    # 如果容器退出，等待 30 秒后重试
    echo -e "\033[0;33m容器退出，清理 8080 占用容器，等待 30 秒重试...\033[0m"
    docker ps --format '{{.ID}} {{.Ports}}' | grep '0.0.0.0:8080' | awk '{print $1}' | xargs -r docker rm -f

    sleep 30
done
