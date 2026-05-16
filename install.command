#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
GUARD_SCRIPT="${SCRIPT_DIR}/doubao-ime-guard.sh"

cd "${SCRIPT_DIR}"

if [[ ! -f "${GUARD_SCRIPT}" ]]; then
  echo "错误：没有找到 doubao-ime-guard.sh。"
  echo "请确认 install.command 和 doubao-ime-guard.sh 在同一个目录。"
  echo
  read "unused?按回车键退出..."
  exit 1
fi

chmod +x "${GUARD_SCRIPT}"

echo "正在安装豆包输入法强制守护..."
"${GUARD_SCRIPT}" install

echo
echo "安装完成。即将打开终端管理界面。"
sleep 1
"${GUARD_SCRIPT}" menu
