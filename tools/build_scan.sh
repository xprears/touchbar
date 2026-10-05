#!/bin/zsh
# 编译命令行扫描器 wxscan（无 App Bundle，权限归终端，永久有效）
set -e

PROJ="/Users/Xprears/WorkBuddy/Touch Bar项目"
SWIFTC=/Library/Developer/CommandLineTools/usr/bin/swiftc
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
RD=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift

"$SWIFTC" -swift-version 5 -O \
  -sdk "$SDK" \
  -resource-dir "$RD" \
  -target arm64-apple-macos13.0 \
  "$PROJ/shared/Scanner.swift" \
  "$PROJ/tools/cli/main.swift" \
  -o "$PROJ/tools/wxscan"

codesign --force --sign - "$PROJ/tools/wxscan"
echo "built: $PROJ/tools/wxscan"
