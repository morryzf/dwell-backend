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

# 模型做 PDF 要嵌中文字体。系统里没有就把思源黑体下到 data/fonts（不靠系统装包，
# 哪种 Linux 都一样）；下不到再试系统的包管理器。都不行不影响部署，只是 PDF 先做不了。
echo "==> PDF 用的中文字体"
if ! .venv/bin/python -m app.file_make --ensure-font; then
	if command -v apt-get >/dev/null; then
		sudo apt-get update -q && sudo apt-get install -y -q fonts-noto-cjk || true
	elif command -v dnf >/dev/null; then
		sudo dnf install -y -q google-noto-sans-cjk-ttc-fonts || sudo dnf install -y -q google-noto-sans-cjk-fonts || true
	elif command -v yum >/dev/null; then
		sudo yum install -y -q google-noto-sans-cjk-ttc-fonts || sudo yum install -y -q wqy-microhei-fonts || true
	fi
	.venv/bin/python -m app.file_make --ensure-font || echo "  还是没有中文字体：PDF 暂时做不了，Word 和文字文件不受影响"
fi

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
