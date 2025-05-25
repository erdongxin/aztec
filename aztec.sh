#!/bin/bash

check_docker_installed() {
  if ! command -v docker &> /dev/null; then
    echo "[+] Docker 未安装，正在安装..."
    curl -fsSL https://get.docker.com | bash
    sudo systemctl enable docker
    sudo systemctl start docker
  else
    echo "[✔] Docker 已安装"
  fi
}

show_menu() {
  echo "====== Aztec 多节点控制台 ======"
  echo "1. 启动节点 1"
  echo "2. 启动节点 2"
  echo "3. 启动节点 3"
  echo "4. 退出"
  echo "==============================="
  read -p "请选择操作: " choice

  case $choice in
    1)
      screen -dmS aztec_node1 bash aztec_node1.sh
      echo "[▶] 节点1 正在后台运行 (screen: aztec_node1)"
      ;;
    2)
      screen -dmS aztec_node2 bash aztec_node2.sh
      echo "[▶] 节点2 正在后台运行 (screen: aztec_node2)"
      ;;
    3)
      screen -dmS aztec_node3 bash aztec_node3.sh
      echo "[▶] 节点3 正在后台运行 (screen: aztec_node3)"
      ;;
    4)
      echo "退出"
      exit 0
      ;;
    *)
      echo "无效选择"
      ;;
  esac
}

main() {
  check_docker_installed
  show_menu
}

main
