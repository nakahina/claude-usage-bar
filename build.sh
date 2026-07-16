#!/bin/bash
# Claude使用量モニターをビルドして build/ClaudeUsageBar.app を作る
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeUsageBar"
APP_DIR="build/${APP_NAME}.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc -O -swift-version 5 \
  Sources/main.swift \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
  -framework AppKit \
  -framework UserNotifications \
  -framework ServiceManagement

cp Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# 通知APIに必要なコード署名（ローカル用のad-hoc署名）
codesign --force -s - "$APP_DIR"

echo "✅ ビルド完了: $APP_DIR"
