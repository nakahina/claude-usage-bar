#!/bin/bash
# Claude使用量モニターをビルド・署名・公証して build/ClaudeUsageBar.app を作る
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeUsageBar"
APP_DIR="build/${APP_NAME}.app"
MIN_OS="13.0" # Info.plistのLSMinimumSystemVersionと必ず合わせること

# 署名・公証の設定は個人情報を含むため build.local.sh（gitignore対象）に分離している。
# 初回は build.local.sh.example をコピーして自分の証明書名に書き換えること。
SIGN_IDENTITY=""
NOTARY_PROFILE=""
[ -f build.local.sh ] && source build.local.sh

if [ -z "$SIGN_IDENTITY" ]; then
  echo "ℹ️  build.local.sh が無いため、ad-hoc署名でビルドします（配布向けの署名・公証はスキップ）"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc -target "arm64-apple-macos${MIN_OS}" -O -swift-version 5 \
  Sources/main.swift \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
  -framework AppKit \
  -framework UserNotifications \
  -framework ServiceManagement

cp Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

if [ -z "$SIGN_IDENTITY" ]; then
  echo "🔏 ad-hoc署名中..."
  codesign --force -s - "$APP_DIR"
  echo "✅ ビルド完了（ad-hoc署名）: $APP_DIR"
  exit 0
fi

echo "🔏 署名中..."
codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP_DIR"

echo "📤 公証のためAppleに送信中（数分かかります）..."
NOTARIZE_ZIP="build/notarize-upload.zip"
NOTARIZE_LOG="build/notarize.log"
rm -f "$NOTARIZE_ZIP" "$NOTARIZE_LOG"
ditto -c -k --keepParent "$APP_DIR" "$NOTARIZE_ZIP"

# 失敗時もログが必ず画面に出るよう、tee でリアルタイムに書き出す
set +e
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$NOTARIZE_LOG"
NOTARY_STATUS=${PIPESTATUS[0]}
set -e
rm -f "$NOTARIZE_ZIP"

if [ "$NOTARY_STATUS" -ne 0 ] || ! grep -q "status: Accepted" "$NOTARIZE_LOG"; then
  echo "❌ 公証に失敗しました。ログ: $NOTARIZE_LOG"
  exit 1
fi

echo "📎 公証チケットをアプリに添付中..."
xcrun stapler staple "$APP_DIR"

echo "✅ ビルド・署名・公証完了: $APP_DIR"
