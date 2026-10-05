#!/bin/zsh
# 编译命令行工具（无 App Bundle，辅助功能权限归终端，不随二进制哈希失效）：
#   tools/wxctl   —— 遥控微信：激活 / 发按键 / 点击 / 截整窗
#   tools/wxscan  —— 扫描微信 AX 树与菜单快捷键，落盘到 out/
#
# ⚠️ 两者是**同一份源码**（shared/Scanner.swift + tools/cli/main.swift，靠 argv[1]
#    分流行为），必须一起编译。旧版本脚本只产出 wxscan，而 README 说它编译 wxctl ——
#    结果 wxctl 是手工编的，改完源码只重编一个，另一个就悄悄停在旧版本上。
set -e

PROJ="/Users/Xprears/WorkBuddy/Touch Bar项目"
SWIFTC=/Library/Developer/CommandLineTools/usr/bin/swiftc
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
RD=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift

for OUT in wxctl wxscan; do
  "$SWIFTC" -swift-version 5 -O \
    -sdk "$SDK" \
    -resource-dir "$RD" \
    -target arm64-apple-macos13.0 \
    "$PROJ/shared/Scanner.swift" \
    "$PROJ/tools/cli/main.swift" \
    -o "$PROJ/tools/$OUT"
  codesign --force --sign - "$PROJ/tools/$OUT"
  echo "built: $PROJ/tools/$OUT"
done
