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

# 模型做 PDF 要嵌中文字体，系统里没有就装一套（装不上不影响别的，只是 PDF 先做不了）
if ! .venv/bin/python -c "import sys; from app.file_make import find_cjk_font; sys.exit(0 if find_cjk_font()[0] else 1)"; then
	echo "==> 装 PDF 用的中文字体"
	if command -v apt-get >/dev/null; then
		sudo apt-get install -y -q fonts-noto-cjk || echo "  字体没装上：PDF 暂时做不了，Word 和文字文件不受影响"
	elif command -v dnf >/dev/null; then
		sudo dnf install -y -q google-noto-sans-cjk-ttc-fonts || sudo dnf install -y -q google-noto-sans-cjk-fonts \
			|| echo "  字体没装上：PDF 暂时做不了，Word 和文字文件不受影响"
	elif command -v yum >/dev/null; then
		sudo yum install -y -q google-noto-sans-cjk-ttc-fonts || sudo yum install -y -q wqy-microhei-fonts \
			|| echo "  字体没装上：PDF 暂时做不了，Word 和文字文件不受影响"
	fi
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
