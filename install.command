#!/bin/bash
# ダブルクリックで実行: ビルドして「アプリケーション」フォルダに入れ、起動します
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

# 既に起動中なら終了させてから差し替える
osascript -e 'tell application "ClaudeUsageBar" to quit' 2>/dev/null || true
sleep 1

rm -rf "/Applications/ClaudeUsageBar.app"
cp -R "build/ClaudeUsageBar.app" /Applications/

open "/Applications/ClaudeUsageBar.app"

echo ""
echo "✅ インストール完了！メニューバー右上に「● %」が表示されます。"
echo "   初回はキーチェーンへのアクセス許可を求められるので「常に許可」を押してください。"
echo "   通知の許可も求められるので「許可」を押してください。"
read -p "Enterキーで閉じます..."
