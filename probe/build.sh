#!/bin/zsh
# 编译 Touch Bar 探针为 arm64 原生 .app
# 关键点：CLT 的 swiftc 找不到标准库，必须显式指定 Xcode 的 SDK 与 resource-dir
set -e

PROJ="/Users/Xprears/WorkBuddy/Touch Bar项目/probe"
SWIFTC=/Library/Developer/CommandLineTools/usr/bin/swiftc
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
RD=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift

APP="$PROJ/build/TBProbe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$PROJ/Info.plist" "$APP/Contents/Info.plist"

"$SWIFTC" -swift-version 5 -O \
  -sdk "$SDK" \
  -resource-dir "$RD" \
  -target arm64-apple-macos13.0 \
  "$PROJ/main.swift" \
  -o "$APP/Contents/MacOS/TBProbe"

codesign --force --sign - "$APP"
echo "built: $APP"
