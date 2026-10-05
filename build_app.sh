#!/bin/zsh
# 编译正式 App: Touch Bar 微信助手
# ⚠️ 编译后不要再改代码——ad-hoc 签名一变，辅助功能授权就失效需重勾
set -e

PROJ="/Users/Xprears/WorkBuddy/Touch Bar项目"
SWIFTC=/Library/Developer/CommandLineTools/usr/bin/swiftc
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
RD=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift

APP="$PROJ/app/build/TouchBarWX.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$PROJ/app/Info.plist" "$APP/Contents/Info.plist"

"$SWIFTC" -swift-version 5 -O \
  -sdk "$SDK" \
  -resource-dir "$RD" \
  -target arm64-apple-macos13.0 \
  "$PROJ/app/main.swift" \
  "$PROJ/app/TBPrivate.m" \
  -import-objc-header "$PROJ/app/TBPrivate.h" \
  -o "$APP/Contents/MacOS/TouchBarWX"

codesign --force --sign - "$APP"
echo "built: $APP"
echo "下一步：open \"$APP\"，然后到 系统设置 → 隐私与安全性 → 辅助功能 勾选 TouchBarWX"
