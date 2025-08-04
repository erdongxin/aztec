#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

# 安装 Docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}未找到 Docker，正在安装...${RESET}"
        apt-get update -y
        apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io
        systemctl start docker
        systemctl enable docker
        echo -e "${GREEN}Docker 已安装并启动${RESET}"
    else
        echo -e "${GREEN}Docker 已安装${RESET}"
    fi
}

# 安装 screen
install_screen() {
    if ! command -v screen &> /dev/null; then
        echo -e "${RED}未找到 screen，正在安装...${RESET}"
        apt-get update -y
        apt-get install -y screen
        echo -e "${GREEN}screen 已安装${RESET}"
    else
        echo -e "${GREEN}screen 已安装${RESET}"
    fi
}

# 安装 jq
install_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}未找到 jq，正在安装...${RESET}"
        apt-get update -y
        apt-get install -y jq
        echo -e "${GREEN}jq 已安装${RESET}"
    else
        echo -e "${GREEN}jq 已安装${RESET}"
    fi
}

# 安装 Aztec CLI
install_aztec() {
    if ! command -v aztec &> /dev/null; then
        echo -e "${RED}未检测到 Aztec CLI，正在安装...${RESET}"
        yes y | bash -i <(curl -s https://install.aztec.network)

        # 添加环境变量到 PATH
        if ! grep -q 'aztec/bin' ~/.bashrc; then
            echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc
            source ~/.bashrc
        fi

        echo -e "${GREEN}Aztec CLI 安装完成并配置环境变量。${RESET}"
    else
        echo -e "${GREEN}Aztec CLI 已安装${RESET}"
    fi
}

# 检查并创建aztec.env文件
setup_aztec_env() {
    AZTEC_ENV_FILE="/root/aztec.env"

    echo -e "${GREEN}未找到aztec.env文件，需要配置环境变量${RESET}"
    read -p "请输入BEACON RPC地址: " BEACON_RPC
    read -p "请输入eth sepolia rpc地址: " L1_RPC_URL
    read -p "请输入0x开头的以太坊私钥（eth sepolia余额需大于0.01）: " PRIVATE_KEY
    read -p "请输入0x开头的以太坊地址: " COINBASE
    
    # 写入环境变量文件
    echo "BEACON_RPC=$BEACON_RPC" > "$AZTEC_ENV_FILE"
    echo "L1_RPC_URL=$L1_RPC_URL" >> "$AZTEC_ENV_FILE"
    echo "PRIVATE_KEY=$PRIVATE_KEY" >> "$AZTEC_ENV_FILE"
    echo "COINBASE=$COINBASE" >> "$AZTEC_ENV_FILE"
    
    echo -e "${GREEN}aztec.env文件已创建${RESET}"
}

show_menu() {
  while true; do
    clear
    echo "==================================================================="
    echo "====脚本由陈喜顺@Chancy59850326编写，Aztec节点控制台，免费开源===="
    echo "==================================================================="
    echo "1. 运行序列器节点"
    echo "2. 查看序列节点日志"
    echo "3. 删除序列器节点"
    echo "4. 配置环境变量"
    echo "5. 退出"
    echo "==============================="
    read -p "请选择操作: " choice

    case $choice in
      1)
        install_docker
        install_screen
        install_jq
        install_aztec

        if [ ! -f "/root/aztec.env" ]; then
          setup_aztec_env
          echo -e "${GREEN}aztec.env文件已创建${RESET}"
        else
          echo -e "${GREEN}aztec.env文件已存在${RESET}"
        fi
        
        # 添加环境变量
        if ! grep -q 'aztec/bin' ~/.profile; then
          echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.profile
        fi

        # 下载脚本
        curl -L https://raw.githubusercontent.com/erdongxin/aztec/refs/heads/main/aztec_node.sh -o /root/aztec_node.sh
        sleep 1

        screen -ls | grep aztec | awk '{print $1}' | sed 's/\.aztec$//' | xargs -I {} screen -S {} -X quit
        docker ps -a --filter "name=aztec" -q | xargs --no-run-if-empty docker rm -f

        chmod +x aztec_node.sh && screen -dmS aztec_node bash aztec_node.sh
        echo -e "${GREEN}[▶] 序列器节点已启动，查看日志请使用 screen -r aztec_node ${RESET}"

        echo "按任意键返回主菜单..."
        read -n 1
        ;;
      2)
        if screen -ls | grep aztec_node > /dev/null; then
          echo "ctrl + A + D 安全退出日志"
          screen -r aztec_node
        else
          echo -e "${YELLOW}节点未运行${RESET}"
        fi
        echo "按任意键返回主菜单..."
        read -n 1
        ;;
      3)
        screen -ls | grep aztec_node | awk '{print $1}' | sed 's/\.aztec_node$//' | xargs -I {} screen -S {} -X quit
        docker ps -a --filter "name=aztec" -q | xargs --no-run-if-empty docker rm -f
        echo "证明者节点 已停止运行!"
        rm -rf /root/aztec_node
        echo "数据已清空!"

        echo "按任意键返回主菜单..."
        read -n 1
        ;;
      4)
        setup_aztec_env
        echo "按任意键返回主菜单..."
        read -n 1
        ;;
      5)
        exit 0
        ;;
      *)
        echo "无效选择"
        echo "按任意键返回主菜单..."
        read -n 1
        ;;
    esac
  done
}

main() {
  show_menu
}

main
