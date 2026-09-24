#!/usr/bin/env bash
# VPS 上的一键部署：拉代码、补依赖、重启两个服务。
#
# Zeabur 时代是 push 完自动部署；搬到自己的机器之后，这个脚本就是那一步。
# 用法：在 VPS 的仓库目录里跑 ./deploy.sh
set -euo pipefail

cd "$(dirname "$0")"

echo "==> 拉代码"
git pull --ff-only

echo "==> Python 依赖"
.venv/bin/pip install -q -r requirements.txt

if [ -d bridge/node_modules ]; then
	echo "==> 桥接依赖"
	(cd bridge && npm install --silent --no-audit --no-fund)
fi

echo "==> 重启服务"
sudo systemctl restart dwell-bridge dwell

sleep 2
echo "==> 状态"
systemctl is-active dwell-bridge dwell
curl -fsS localhost:8787/health && echo
