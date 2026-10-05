# Touch Bar 微信快捷助手

在 MacBook Pro (M1, 带 Touch Bar) 上给**微信**加 Touch Bar 快捷按钮。

## 效果

Touch Bar 右侧控制条出现 6 个图标按钮，**只在微信处于前台时显示**：

| 图标 | 跳转目标 | 实现方式 |
|---|---|---|
| 💬 气泡 | 聊天 | 发 `⌘1` |
| ◉ 六边形 | 朋友圈 | `⌘4` 进「发现」→ 点击 |
| ⊞ 四方格 | 小程序 | `⌘4` 进「发现」→ 点击 |
| ▶ 播放框 | 视频号 | `⌘4` 进「发现」→ 点击 |
| ✦ 放大镜 | 搜一搜 | `⌘4` 进「发现」→ 点击 |
| | 搜索 | 发 `⌘F` |

> 通讯录 `⌘2` / 收藏 `⌘3` 微信自带快捷键，一个组合键就到，不占 Touch Bar 位置。

## 安装 / 运行

App 已编译好，在：

```
app/build/TouchBarWX.app
```

**首次使用必须授一次辅助功能权限**（否则发不出按键和点击）：

1. `系统设置 → 隐私与安全性 → 辅助功能`
2. 点 `+`，添加 `/Users/Xprears/WorkBuddy/Touch Bar项目/app/build/TouchBarWX.app`
3. 打开开关

> ⚠️ **授权后不要重新编译 App。** 本项目用 ad-hoc 签名，macOS 把辅助功能授权
> 绑定在代码签名哈希上，重编译换了哈希，授权立刻失效且系统里还显示"已开启"。
> 真要改代码，改完提醒你重新勾一次。

启动：

```sh
open "/Users/Xprears/WorkBuddy/Touch Bar项目/app/build/TouchBarWX.app"
```

## 菜单栏

菜单栏出现「微信TB」，菜单里可以：

- 看辅助功能授权状态
- 切换「仅微信在前台时显示」
- 自检（发一次 `⌘1`）
- 打开日志
- 退出

运行日志：`out/app.log`

## 重新编译（改代码后）

```sh
cd "/Users/Xprears/WorkBuddy/Touch Bar项目"
./build_app.sh
```

编译完 **必须让用户在辅助功能里重新勾选**。

## 技术要点

### 显示层：为什么用控制条而不是整条接管

macOS 官方只允许前台 App 控制自己的 Touch Bar，要接管别人的必须用私有 API。
最初走的是 MTMR / Pock 那套「整条替换」：

```swift
NSTouchBar.presentSystemModalTouchBar(bar, systemTrayItemIdentifier: id)
```

在 macOS 27.0.1 上这个调用**成功、不崩溃，但完全不显示**（实测
`present=true visible=false`，肉眼也确认主区域空白）。

所以改成往右侧 **Control Strip** 塞按钮，这条路是活的：

```swift
NSTouchBarItem.addSystemTrayItem(item)                                  // 私有类方法
DFRElementSetControlStripPresenceForIdentifier(id as NSString, true)    // DFRFoundation
```

两个私有能力都通过 `dlopen` + `dlsym` 拿，**不需要链接 DFRFoundation**
（框架二进制在 dyld 共享缓存里，链不上）。

### 控制层：微信 4.1.13 的实际情况

微信是自绘界面，**对 Accessibility 的暴露几乎为零**——`AXFrame` / `AXSize` /
`AXMainWindow` / `AXFocusedWindow` 全部为空，窗口内容完全不可见。
唯一能读到的是菜单栏（菜单项 + 快捷键）。

所以控制层分两类：

- **发按键**（稳）：`⌘1` 聊天、`⌘2` 通讯录、`⌘3` 收藏、`⌘4` 发现、`⌘F` 搜索
- **坐标点击**（脆）：`⌘4` 进「发现」后点列表项。窗口坐标运行时用
  `CGWindowListCopyWindowInfo` 取（AX 拿不到），点击位置是相对窗口顶部的固定偏移

「发现」页实测偏移（距窗口顶部）：

| 条目 | 偏移 |
|---|---|
| 朋友圈 | 75px |
| 视频号 | 123px |
| 搜一搜 | 172px |
| 游戏 | 219px |
| 小程序 | 267px |

点击 x = 窗口左边 + 121px。

### 三个必须记住的坑

1. **坐标系**：`CGWindowList` / `screencapture -R` 是**左下原点**，
   `CGEvent` 鼠标事件是**左上原点**。换算 `cgY = 主屏高 - quartzY`。
2. **微信 UI 延迟 2~5 秒**：合成按键/点击都是延迟生效的，写自动化时别急着判断失败。
3. **发按键/点击前必须先激活微信**，否则事件打到别的 App。

## 目录结构

```
app/main.swift          正式 App（唯一需要维护的文件）
app/Info.plist          LSUIElement=true，只驻留菜单栏
build_app.sh            编译脚本
out/app.log             运行日志
probe/                  早期探针（Touch Bar 显示验证），已废弃但留着
shared/Scanner.swift    微信 AX 扫描核心
tools/cli/main.swift    命令行遥控器 wxctl：激活微信/发按键/点击/截图
tools/build_scan.sh     编译 wxctl
tools/find_items.py     纯 stdlib 解 PNG + 像素分析定位列表项坐标
```

## 已知限制

- 依赖私有 API，macOS 大版本升级后可能失效（`presentSystemModalFunctionBar:`
  就已经被移除了）。
- 坐标点击依赖微信「发现」页布局，微信改版可能失效。届时用
  `tools/find_items.py` 重新量一遍偏移，改 `ITEMS` 里的数字即可。
- 只对微信有效。要扩展到别的 App，需要重新做一次 AX 探测 + 快捷键确认。
