# Touch Bar 微信快捷助手

在 MacBook Pro (M1, 带 Touch Bar) 上给**微信**加 Touch Bar 快捷按钮。

## 效果

微信处于前台时，Touch Bar 主区域出现 6 个按钮；切走微信自动隐藏并交还系统。

与右侧控制条**共享**（音量 / 亮度条保留）—— 见「显示层」里的 `placement 0`。

| 图标 | 跳转目标 | 实现方式 |
|---|---|---|
| 💬 气泡 | 聊天 | 发 `⌘1` |
| ◉ 六边形 | 朋友圈 | `⌘4` 进「发现」→ 点击 |
| ⊞ 四方格 | 小程序 | `⌘4` 进「发现」→ 点击 |
| ▶ 播放框 | 视频号 | `⌘4` 进「发现」→ 点击 |
| ✦ 放大镜 | 搜一搜 | `⌘4` 进「发现」→ 点击 |
| 🔍 放大镜 | 搜索 | 发 `⌘F` |

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
> **改过代码重编译后，要在辅助功能里先删掉旧条目、再重新添加**——
> 只重新开关那个开关是没用的，哈希已经变了。

启动：

```sh
open "/Users/Xprears/WorkBuddy/Touch Bar项目/app/build/TouchBarWX.app"
```

## 菜单栏

菜单栏出现「微信TB」，菜单里可以：

- 看辅助功能授权状态（每次弹出菜单都重算，去系统设置授权完回来就变）
- 申请辅助功能权限（直接弹系统框）
- 切换「仅微信在前台时显示」
- 切换「保留右侧控制条（音量/亮度）」= `placement 0` ↔ `1`
- 自检（发一次 `⌘1`）
- 打开日志
- 退出

运行日志：`out/app.log`

## 重新编译（改代码后）

```sh
cd "/Users/Xprears/WorkBuddy/Touch Bar项目"
./build_app.sh
```

编译完 **必须去辅助功能里删掉旧条目重新添加**。

## 技术要点

### 显示层：怎么让 Touch Bar 显示**别人的**按钮

macOS 官方只允许前台 App 控制自己的 Touch Bar，要接管别人的必须用私有 API。
最终走通的是 Pock / MTMR 同款路径：

```swift
NSTouchBar.presentSystemModalTouchBar(bar, placement: 0, systemTrayItemIdentifier: nil)
NSTouchBar.dismissSystemModalTouchBar(bar)
```

- `placement 0` = 与右侧控制条**共享**（音量/亮度条保留）—— 默认。
- `placement 1` = **独占**整条，控制条被挤掉。
- 这两个都是 `NSTouchBar` 的**类方法**，Swift 侧没有声明，所以用 Objective-C
  桥接走 `objc_msgSend`（见 `app/TBPrivate.{h,m}`）。**别改用 `unsafeBitCast`
  自取 IMP** —— 签名对不上会直接崩，这条路已经验证过了。

> **两条走不通的老路，别改回去**
> - `NSTouchBarItem.addSystemTrayItem:` + `DFRElementSetControlStripPresenceForIdentifier`
>   往右侧控制条塞按钮：控制条那块地方只留得住 1 个，6 个按钮塞不下。
> - `presentSystemModalTouchBar(bar, systemTrayItemIdentifier:)` 两参数旧版：
>   返回成功但完全不显示。

#### ⚠️ 卡了很久的真凶：`defaultItemIdentifiers` 是**属性**，不是 delegate 方法

`NSTouchBarDelegate` 协议里**只有一个**可选方法：

```objc
- (nullable NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar
                makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier;
```

而 `defaultItemIdentifiers` 是 `NSTouchBar` 的 **property**：

```objc
@property (copy) NSArray<NSTouchBarItemIdentifier> *defaultItemIdentifiers;
```

曾经把它写成同名方法，**编译零警告、运行不报错、系统永远不会调用它**：

```swift
// ❌ 这不是协议方法，只是个同名的普通实例方法
func defaultItemIdentifiers(in touchBar: NSTouchBar) -> [NSTouchBarItem.Identifier] { ... }
```

后果链是完全静默的：属性为空 → `bar.itemIdentifiers` 解析为空 →
`itemForIdentifier:` 从不被调用 → `makeItemForIdentifier` 从不回调 →
**`present` 返回 `true`，但整条 Touch Bar 什么都不显示。**

```swift
// ✅ 正解：显式赋值
bar.defaultItemIdentifiers = itemIDs
```

**`presentSystemModalTouchBar` 返回 `true` 什么都不代表。** 唯一可信的判据是：

```swift
bar.defaultItemIdentifiers.count   // 自己有没有把清单交出去
bar.itemIdentifiers.count          // 系统解析出几个（应等于按钮数）
bar.isVisible                      // 官方 property，已附着到 provider
```

不要用 `isTouchBarVisible` —— 这个私有方法在 macOS 27 上**不存在**，
`responds(to:)` 会静默返回 `false`，制造「visible=false」的假读数
（扫 dyld 共享缓存全部 82 个分片确认过，见「排查手法」）。

### 撤下：必须无条件 dismiss

```swift
// ✅ bar 非 nil 就撤，不要加任何条件
if let b = bar { _ = TBPrivate.dismiss(b) }
```

踩过的坑：原先用自己记录的状态位 `isPresented` 决定要不要撤 ——

```swift
// ❌ 实测走过 else 分支（只还原偏好、不撤 bar），模态 bar 就永远挂在系统上
if let b = bar, isPresented { TBPrivate.dismiss(b) } else { restorePresentationMode() }
```

后果是切到别的 App 也不消失、右侧控制条也回不来，表现为
**「面板恒久显示那几个按钮」**。`dismiss` 本身是幂等的（没 present 时返回 NO），
不需要条件保护。

**另外，`dismissSystemModalTouchBar:` 的返回值不可信**：同一个 build 连续两次调用
会一次返回 `true`、一次返回 `false`，而 `bar.isVisible` 两次都正确变成 `false`
（怀疑该方法实际声明为 `void`，按 `BOOL` 读寄存器只能读到垃圾）。
**判据一律用 `bar.isVisible`，别用私有方法的返回值。**

### 呈现模式：一个全局持久化的雷

`com.apple.touchbar.agent` 域里的 `PresentationModeGlobal` 是**写进系统偏好、
不随进程退出回滚**的。进程若在 `present()` 里崩在 `dismissBar()` 之前，
系统会永久卡在 `"app"` 模式：控制条被踢掉、整条 Touch Bar 黑掉，
此后任何 App 都 present 不上去。

所以有三层兜底。改这个偏好是**全局副作用**，别乱动：

1. `atexit` + `applicationWillTerminate`（正常退出 / SIGTERM）
2. 启动时检测并清理上次残留的模式
3. **独立看门狗进程**（`spawnWatchdog`，`kill(pid, 0)` 探活）——
   **唯一能扛 SIGKILL 的一层**，因为 `atexit` 在 SIGKILL 下根本不执行

手动恢复（不需要 sudo）：

```sh
defaults write com.apple.touchbar.agent PresentationModeGlobal -string appWithControlStrip
pkill ControlStrip
```

> 默认 `placement 0` + 恒为 `appWithControlStrip` 的好处：模式**全程不变**，
> 于是 `pkill ControlStrip` 一次都不会发生（`pkill` 会打断 Touch Bar 的渲染通道）。
> 切到 `placement 1` 才会因为模式来回切而频繁重载控制条。

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
| 游戏 | 219px（量过，没做按钮） |
| 小程序 | 267px |

点击 x = 窗口左边 + 121px。

### 必须记住的坑

1. **坐标系**：`CGWindowList` / `screencapture -R` 是**左下原点**，
   `CGEvent` 鼠标事件是**左上原点**。换算 `cgY = 主屏高 - quartzY`。
2. **微信 UI 延迟 2~5 秒**：合成按键/点击都是延迟生效的，写自动化时别急着判断失败。
3. **发按键/点击前必须先激活微信**，否则事件打到别的 App。
4. **发组合键必须显式 keyDown / keyUp 修饰键**，只在主键事件上挂 `flags`
   会在 App 异常退出时把 Command 卡在按下状态，之后所有键都变成组合键。
5. **不要设 `customizationIdentifier`**：设了 bar 才成为「可自定义」，
   `itemIdentifiers` 会改由 CustomizationPanel 决定、`defaultItemIdentifiers` 被忽略。

### 排查手法：验证某个私有 API 在你这台机器上到底存不存在

`strings` / `nm` 会被 Xcode 许可挡住，公开头文件里也查不到私有符号。
做法是直接扫 dyld 共享缓存 —— ObjC 的选择子是字符串，只要有任何类实现了它，
该字符串必定在里面：

```sh
python3 ~/.workbuddy/skills/macos-touchbar-app-debug/scripts/dyld_symbol_probe.py \
  'dismissSystemModalTouchBar:' 'isTouchBarVisible'
```

路径 `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/`，
82 个分片共约 6.56 GB，全扫约 23 秒。**必须同时塞一个「已知存在」的对照串**，
否则「没搜到」分不清是真的不存在，还是脚本写错了。

同步手法：搜**共同子串**并把命中处前后字节 dump 成文本，一次捞出一整个方法族
（`presentSystemModalTouchBar:placement:systemTrayItemIdentifier:` /
`dismissSystemModalTouchBar:` / `minimizeSystemModalTouchBar:` /
私有类 `NSSystemModalTouchBarOverlay` …），比逐个猜名字高效。

## 目录结构

```
app/main.swift          正式 App（唯一需要维护的文件）
app/TBPrivate.{h,m}     Touch Bar 私有 API 的 Objective-C 桥接
app/Info.plist          LSUIElement=true，只驻留菜单栏
build_app.sh            编译 App
out/app.log             运行日志
probe/                  早期探针（Touch Bar 显示验证），已废弃但留着
shared/Scanner.swift    微信 AX 扫描核心（**只有 wxscan 用它，App 不引用**）
tools/cli/main.swift    命令行工具源码（wxctl / wxscan 同一份源码，靠 argv 分流）
tools/build_scan.sh     编译 wxctl + wxscan（必须一起编，别只编一个）
tools/find_items.py     纯 stdlib 解 PNG + 像素分析定位列表项坐标
```

## 命令行工具

```sh
cd "/Users/Xprears/WorkBuddy/Touch Bar项目"
./tools/build_scan.sh          # 产出 tools/wxctl 与 tools/wxscan

tools/wxctl bounds             # 打印微信窗口坐标 / 屏幕数
tools/wxctl key 4 cmd          # 发 ⌘4（不带 cmd 就是裸按键）
tools/wxctl key 1              # 发 1
tools/wxctl click 320 688      # 点击屏幕坐标
tools/wxctl shot               # 截整窗到 out/wx_full.png
tools/wxscan                   # 扫描微信 AX 树 + 菜单快捷键，落盘 out/
```

> ⚠️ 键码表用的是 HID 虚拟键码，**不是字符 ASCII**。
> 这里踩过坑：把 `0..9` 写成 ASCII（`0x30–0x39`），于是 `2/3/4/6/7/8/9`
> 变成未定义键码、`0` 变 Tab、`1` 变空格、`5` 变 Esc ——
> `wxctl key 4 cmd`（发现页的默认用法）实际**什么都没发出去**，
> 早期用它做的探测结论全部不可信。

## 已知限制

- 依赖私有 API，macOS 大版本升级后可能失效（`presentSystemModalFunctionBar:`
  就已经被移除了）。
- **微信在前台时整条 Touch Bar 被这条 bar 占用**，即使选 `placement 0`，
  6 个按钮也把主区域铺满 —— 想同时保住控制条和按钮，这条路做不到，
  只能往控制条里塞 1 个按钮（见上面「走不通的老路」）。
- 坐标点击依赖微信「发现」页布局，微信改版可能失效。届时用
  `tools/find_items.py` 重新量一遍偏移，改 `ITEMS` 里的数字即可。
- 只对微信有效。要扩展到别的 App，需要重新做一次 AX 探测 + 快捷键确认。
