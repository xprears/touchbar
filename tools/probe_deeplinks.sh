#!/bin/zsh
# 逐个实测 weixin:// 深链：每条 URL 前后各截一张全屏图（缩放后存盘）。
# 用法: probe_deeplinks.sh
set -u
OUT="/Users/Xprears/WorkBuddy/Touch Bar项目/out/reverse"
SHOT="$OUT/shots"
mkdir -p "$SHOT"

shoot() {  # $1 = 输出名
  screencapture -x "/tmp/_probe_full.png"
  sips -Z 1000 "/tmp/_probe_full.png" --out "$SHOT/$1.png" >/dev/null 2>&1
}

probe() {  # $1 = 序号, $2 = url
  local idx="$1" url="$2"
  echo "───── [$idx] $url"
  open -b com.tencent.xinWeChat >/dev/null 2>&1
  sleep 1.2
  shoot "${idx}_before"
  local err
  # ⚠️ 必须 -b 强制投给微信；裸 `open "<url>"` 会被 LaunchServices 按 scheme 抢注路由到第三方
  #    （本机 `search://` 归 Parallels「文件资源管理器.app」，会启动 Windows 11 虚拟机）
  err=$(open -b com.tencent.xinWeChat "$url" 2>&1)
  local rc=$?
  echo "      open rc=$rc  ${err}"
  sleep 2.8
  shoot "${idx}_after"
}

# 基线
open -b com.tencent.xinWeChat >/dev/null 2>&1
sleep 1.5
shoot "00_baseline"

probe "01" "weixin://"
probe "02" "weixin://jump/mainframe/"
probe "03" "weixin://resourceid/Search/app.html"
probe "04" "weixin://resourceid/AppletDiscover/app.html"
probe "05" "weixin://dl/jumpredirect_url:https://mp.weixin.qq.com/"
probe "06" "weixin://dl/openinvalid"
probe "07" "weixin://bizmsgmenu?msgmenucontent=test&msgmenuid=0"
probe "08" "weixin://kefumenu?kefumenucontent=test"

echo "===== 完成，截图在 $SHOT ====="
ls "$SHOT"
