#!/usr/bin/env bash
set -euo pipefail

HOME_VOLUME="${HOME_VOLUME:-codex-dev-home}"

echo "即将删除 Home volume：$HOME_VOLUME"
echo "这会清除 Codex 登录态、mise 安装的运行时、git 配置和各种缓存。"
read -r -p "确认删除请输入 DELETE： " answer

if [ "$answer" != "DELETE" ]; then
  echo "已取消。"
  exit 0
fi

docker volume rm "$HOME_VOLUME"
echo "已删除：$HOME_VOLUME"
