import Cocoa
import Darwin
import ApplicationServices

// Touch Bar 微信快捷工具
//   显示层：presentSystemModalTouchBar(_:placement:systemTrayItemIdentifier:) 接管主区域，
//          标准 NSTouchBarDelegate 提供 3 个按钮。
//   控制层：**全部靠快捷键**（⌘1 聊天 / ⌘4 发现 / ⌘F 搜索），不依赖坐标点击。
//
//   为什么砍掉了 小程序 / 视频号 / 搜一搜：
//   这三个微信没有独立快捷键，只能「⌘4 进发现 → 按窗口相对坐标点击列表项」。
//   而坐标点击依赖窗口钉死在某个位置 —— 用户一挪微信窗口就点不准（命中区间本来就很窄）。
//   朋友圈不需要点：⌘4 进「发现」默认就选中第一项（朋友圈），直接当快捷键用即可。
//   其余三个等 weixin:// 之类的深链方案跑通再补；**在跑通之前不要再复活坐标点击**。
//
//   ⚠️ 本App 用 ad-hoc 签名，TCC 辅助功能授权绑定在代码签名哈希上，
//      重新编译会让授权失效、需重新勾一次。菜单里点「申请辅助功能权限」可直接弹系统框。

let WECHAT_BUNDLE = "com.tencent.xinWeChat"
let PROJ = "/Users/Xprears/WorkBuddy/Touch Bar项目"
let LOG_PATH = PROJ + "/out/app.log"
let TB_AGENT = "com.apple.touchbar.agent" as CFString
let kPresentationModeGlobal = "PresentationModeGlobal" as CFString

// MARK: - 日志

func log(_ s: String) {
    let t = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
    let line = "[\(t)] \(s)\n"
    guard let d = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: LOG_PATH)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile(); fh.write(d); try? fh.close()
    } else {
        try? d.write(to: url)
    }
}

// MARK: - 虚拟键码（务必用这张表，别拿十进制凑）

enum Key {
    /// ⌘1 → 聊天
    static let chat:  CGKeyCode = 0x12        // ANSI 1
    /// ⌘4 → 发现（默认停在第一项「朋友圈」，因此这一条就等于「打开朋友圈」）
    static let discover: CGKeyCode = 0x15      // ANSI 4
    /// ⌘F → 搜索
    static let search: CGKeyCode = 0x03        // ANSI F
    /// 左Command
    static let cmd: CGKeyCode = 0x37

    /// 自检用键名，排查时一眼能看出发的是哪个键
    static func name(_ kc: CGKeyCode) -> String {
        switch kc {
        case chat: return "⌘1 聊天"
        case discover: return "⌘4 发现（默认朋友圈）"
        case search: return "⌘F 搜索"
        case cmd: return "左Command"
        default: return String(format: "keycode=0x%02X(%d)", kc, kc)
        }
    }
}

// MARK: - 配置

/// 动作类型。目前只有「发快捷键」这一种。
/// （曾经的 `.discoverThenClick(CGFloat)` 坐标点击已删除，原因见文件头。）
enum Mode {
    case key(CGKeyCode)                 // 直接发快捷键
}

struct Item {
    let title: String
    let symbol: String
    let mode: Mode
}

let ITEMS: [Item] = [
    Item(title: "聊天",   symbol: "bubble.left.and.bubble.right.fill", mode: .key(Key.chat)),
    // ⌘4 进「发现」，微信默认就停在第一项「朋友圈」，等价于直接打开朋友圈。
    Item(title: "朋友圈", symbol: "circle.hexagongrid.fill",           mode: .key(Key.discover)),
    Item(title: "搜索",   symbol: "magnifyingglass",                   mode: .key(Key.search)),
]
// 说明：通讯录 ⌘2 / 收藏 ⌘3 微信自带快捷键，一个组合键就能到，所以也不放进 Touch Bar。

/// 控制条里单个按钮的尺寸
let BTN_W: CGFloat = 32
let BTN_H: CGFloat = 30

// MARK: - 显示方式（菜单可切，重编译一次就能 A/B 两种）

/// 「App 区域只有一个格子」这个硬约束下，只有两种活法：
///
/// - `.always`：一进微信就占住 App 区域（原行为）。代价是**打字不出候选框** ——
///   用户得先点 Touch Bar 上的 × 把它关掉才能选字（2026-10-05 实测）。
/// - `.yield`：占住，但**一检测到你在敲键盘就立刻让位**，停手 ~2s 再把按钮收回来。
///   体感就是「打字时候选框在，打完字按钮自己回来」。
///
/// 曾经想走第三条路（把按钮搬进右侧控制条，与候选条天然并存），**已证伪**：
/// `addSystemTrayItem:` / `removeSystemTrayItem:` 在 `NSTouchBar` 上**不存在**
/// （类与实例 respondsToSelector 全 false；dyld 里那个字符串属于别的类）。
/// 证据见 out/app.log 15:46:03「控制条 item 添加：发出去=false」。
enum DisplayMode: String {
    case yield    // 打字时让位（默认）
    case always   // 一直占着（原行为）

    var title: String {
        self == .yield ? "打字时让位" : "一直占着 App 区域"
    }
}

/// 停手多久算「打完了」。太短会和输入法来回抢，太长按钮回来得慢。
let TYPING_WINDOW: Double = 2.0

/// 轮询间隔。让位必须够快 —— 1s 太慢，一句话打完都还没让位。
let TICK: Double = 0.3

let TB_PREFS = "com.xprears.tbwx" as CFString
let MODE_KEY = "DisplayMode" as CFString

func loadDisplayMode() -> DisplayMode {
    let s = (CFPreferencesCopyAppValue(MODE_KEY, TB_PREFS) as? String) ?? ""
    return DisplayMode(rawValue: s) ?? .yield
}

func saveDisplayMode(_ m: DisplayMode) {
    CFPreferencesSetAppValue(MODE_KEY, m.rawValue as CFString, TB_PREFS)
    CFPreferencesAppSynchronize(TB_PREFS)
}

// MARK: - Touch Bar 呈现（Pock 同款机制）

/// 读系统当前的 Touch Bar 呈现模式
func currentPresentationMode() -> String {
    (CFPreferencesCopyAppValue(kPresentationModeGlobal, TB_AGENT) as? String) ?? "appWithControlStrip"
}

/// 设置呈现模式。**只在模式真的变了时才重载 agent**——
/// pkill ControlStrip 会打断 Touch Bar 的截图/渲染通道，无脑每次调用会让界面卡住不刷新。
/// 返回值 = **是否真的改了模式**（不是「同步是否成功」）。
/// 调用方靠它决定要不要等 agent 起来：没改模式就没 pkill 过 ControlStrip、
/// 没碰渲染通道，那就不需要等。
///
/// 曾经有个 force 参数用来绕过「模式没变就不动」的保护，**已删除** ——
/// 那个保护正是防止无脑 pkill 打断渲染通道的关键，不该留绕过的入口。
@discardableResult
func setPresentationMode(_ mode: String) -> Bool {
    let cur = currentPresentationMode()
    guard cur != mode else { return false }
    CFPreferencesSetAppValue(kPresentationModeGlobal, mode as CFString, TB_AGENT)
    let ok = CFPreferencesAppSynchronize(TB_AGENT)
    reloadTouchBarAgent()
    log("  呈现模式 \(cur) → \(mode) sync=\(ok)")
    return true
}

/// pkill ControlStrip 让新模式生效
func reloadTouchBarAgent() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["ControlStrip"]
    try? p.run()
    p.waitUntilExit()
}

/// 把系统全局呈现模式还原成共享模式，**不 pkill ControlStrip**。
///
/// 为什么必须有这个：本App 独占模式时会把 `PresentationModeGlobal` 全局改成
/// "app"，而这是**写进系统偏好域、不随进程退出回滚**的。一旦 App 在
/// present() 里崩溃（EXC_BAD_ACCESS），dismissBar() 跑不到，系统就永久卡在
/// "app" 模式：Control Strip 被踢掉、Touch Bar 整条不显示，且此后任何 App
/// 都present 不上去（present 返回 true 但 itemIdentifiers 恒为空）。
///
/// 崩溃 / 被杀 / 正常退出都要能还原，所以做成幂等的，并在 atexit 里兜底。
func restoreGlobalPresentationMode(reason: String) {
    guard currentPresentationMode() != "appWithControlStrip" else { return }
    CFPreferencesSetAppValue(kPresentationModeGlobal, "appWithControlStrip" as CFString, TB_AGENT)
    CFPreferencesAppSynchronize(TB_AGENT)
    log("↩️ 已还原全局呈现模式 → appWithControlStrip（\(reason)）")
}

/// 独立看门狗：**自己重新 exec 一份**、脱离父进程，盯着主进程 pid。
/// 主进程一消失（崩溃 / SIGKILL / 强杀）就把全局模式还原回去。
///
/// 为什么需要它：atexit 只在正常退出（含 SIGTERM）时跑，**SIGKILL 和
/// uncatchable crash 都不会跑**，而这恰恰是最容易把系统卡死的场景。
/// 进程内的任何回调在那一刻都已失效，只有一个独立于主进程的生命周期才靠得住。
func spawnWatchdog(parentPID: pid_t) {
    // 把自己再跑一遍，带 --watchdog 参数
    let exe = CommandLine.arguments[0]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = ["--watchdog", String(parentPID)]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        log("看门狗已启动 pid=\(p.processIdentifier) 盯着 \(parentPID)")
    } catch {
        log("⚠️ 看门狗启动失败：\(error.localizedDescription)")
    }
}

/// 看门狗主循环（独立进程）。每隔 1s 检查父进程是否还活着，
/// 一旦消失就把全局模式还原，然后自杀。
func runWatchdog(parentPID: pid_t) {
    log("[watchdog] 启动，盯 pid=\(parentPID)")
    while true {
        // kill(pid, 0) 不发信号，只探活
        if kill(parentPID, 0) != 0 {
            // ESRCH = 父进程没了 → 还原
            CFPreferencesSetAppValue(kPresentationModeGlobal, "appWithControlStrip" as CFString, TB_AGENT)
            CFPreferencesAppSynchronize(TB_AGENT)
            let line = "[\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))] [watchdog] 父进程 \(parentPID) 已消失，已还原全局模式 → appWithControlStrip\n"
            if let d = line.data(using: .utf8), let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: LOG_PATH)) {
                fh.seekToEndOfFile(); fh.write(d); try? fh.close()
            }
            exit(0)
        }
        usleep(1_000_000)
    }
}

// MARK: - 辅助功能授权

/// 统一的授权判断。菜单显示、按钮执行都走这里，避免各处口径不一致。
var isAXTrusted: Bool { AXIsProcessTrusted() }

/// 弹系统的「要访问辅助功能吗」框；已授权时什么都不做。
@discardableResult
func promptForAX() -> Bool {
    if isAXTrusted { return true }
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let ok = AXIsProcessTrustedWithOptions(opts)
    log(ok ? "AX 授权已生效" : "已弹出 AX 授权请求框，等待用户在系统设置里勾选")
    return ok
}

// MARK: - 输入模拟

/// 发一个组合键。
/// 注意：修饰键必须走「显式 keyDown / keyUp」，只在主键事件上挂 flags 的写法
/// 在 App 异常退出时会把 Command 卡在按下状态，之后所有键都变成组合键。
func sendKey(_ kc: CGKeyCode, cmd: Bool) {
    let src = CGEventSource(stateID: .combinedSessionState)

    @discardableResult
    func post(_ down: Bool, _ code: CGKeyCode, _ flags: CGEventFlags = []) -> Bool {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return false }
        e.flags = flags
        e.post(tap: .cghidEventTap)
        return true
    }

    // 间隔压到合计 ~41ms。原来是四段 40+50+60+50=200ms（第二大耗时来源）。
    // 合成事件是同步投递到 HID tap 的，10~15ms 足够让 target 分清 keyDown/keyUp；
    // 真正不能省的是「松开 Command」那一步（省了会卡住修饰键）。
    if cmd {
        post(false, Key.cmd)                 // 先复位可能残留的 Command
        usleep(8000)
        post(true, Key.cmd, [.maskCommand])
        usleep(10000)
    }
    let f: CGEventFlags = cmd ? [.maskCommand] : []
    post(true, kc, f)
    usleep(15000)
    post(false, kc, f)
    if cmd {
        usleep(8000)
        post(false, Key.cmd)                 // 必须松开，否则 Command 卡住
    }
}

func weChatApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == WECHAT_BUNDLE }
}

// MARK: - HUD

func hud(_ msg: String, ok: Bool) {
    DispatchQueue.main.async {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 84),
                        styleMask: [.titled], backing: .buffered, defer: false)
        p.title = ok ? "Touch Bar 微信助手" : "执行失败"
        p.level = .floating
        p.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 84))
        let tf = NSTextField(labelWithString: msg)
        tf.font = .systemFont(ofSize: 13)
        tf.lineBreakMode = .byWordWrapping
        tf.maximumNumberOfLines = 3
        tf.frame = NSRect(x: 16, y: 16, width: 388, height: 52)
        v.addSubview(tf)
        p.contentView = v
        p.center(); p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { p.orderOut(nil) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTouchBarDelegate {

    var keepAlive: [Any] = []
    var statusItem: NSStatusItem?
    var authMenuItem: NSMenuItem?
    var pollTimer: Timer?
    var onlyWhenFrontmost = true
    // 呈现模式恒为共享（placement 0），配 appWithControlStrip。
    // 独占模式（placement 1 + 全局 "app"）每次切前台都要 pkill ControlStrip 重载，
    // 收益只是把音量/亮度条顶掉，风险却是「整条黑掉」那一类 —— 已砍掉。
    var displayMode: DisplayMode = loadDisplayMode()
    var lastShownState = false
    var busy = false
    /// 让位模式：上次尝试「抢回」的时间。防止反复 dismiss/present 打断渲染通道。
    var lastReclaim = Date.distantPast
    /// 让位模式：当前这一「显示轮次」里，撤下是不是**我们自己为了让位**干的。
    /// 用来区分「输入法抢占」和「用户点 × 手动关掉」——后者不该自动抢回来。
    var yieldedByTyping = false
    /// 用户手动点 × 关掉过 → 本轮不再自动抢回，等前台 App 再切换一次。
    var userClosed = false
    /// 我们自己发的合成按键也会计入 CGEventSource 的计数。
    /// 不屏蔽的话，「点一下按钮 → 立刻判定成用户在打字 → 立刻让位」，按钮刚出现就消失。
    var suppressYieldUntil = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        log("=== Touch Bar 微信助手启动 ===")
        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // 兜底 #1：进程正常退出（含被 pkill / 崩溃导致的 abort）时还原全局模式。
        // 系统偏好域是全局持久化的，不还原就会污染下一次启动和整个系统。
        atexit {
            CFPreferencesSetAppValue(kPresentationModeGlobal, "appWithControlStrip" as CFString, TB_AGENT)
            CFPreferencesAppSynchronize(TB_AGENT)
        }

        // 兜底 #2：启动即还原一次。上一次若是不干净退出的（崩溃/SIGKILL），
        // 这里把残留的 "app" 模式清掉，再按本次的真实意图设置。
        if currentPresentationMode() != "appWithControlStrip" {
            log("⚠️ 检测到上次残留的全局模式 \(currentPresentationMode())，先还原")
            restoreGlobalPresentationMode(reason: "启动时清理残留")
        }

        spawnWatchdog(parentPID: getpid())

        bar = buildTouchBar()
        log("显示方式=\(displayMode.title)（菜单可切，已持久化）")
        setupStatusItem()
        // 0.3s 轮询（原来 1s）。让位模式下 1s 太慢 —— 一句话都打完了按钮还没让位。
        pollTimer = Timer.scheduledTimer(withTimeInterval: TICK, repeats: true) { [weak self] _ in
            self?.tick()
            self?.refreshAuthIndicator()
        }
        refreshNow()

        if !isAXTrusted {
            log("⚠️ 辅助功能未授权，发按键会失效")
            hud("请到系统设置 → 隐私与安全性 → 辅助功能 勾选「TouchBarWX」\n（或点菜单栏「微信TB → 申请辅助功能权限」）", ok: false)
            _ = promptForAX()
        } else {
            log("✅ 辅助功能已授权")
        }
    }

    /// 兜底 #3：正常终止时把 Touch Bar 和全局模式都交还系统。
    func applicationWillTerminate(_ n: Notification) {
        log("退出中：dismiss + 还原全局模式")
        dismissBar()
        restoreGlobalPresentationMode(reason: "正常退出")
    }

    // ❌ 这里原本有一个「崩溃通知兜底」：注册 "NSApplicationWillCrashNotification"，
    //    在崩溃时先还原全局模式。**已删除，它是个假保险。**
    //    扫过 macOS 27 的 dyld 共享缓存全部 82 个分片（6.56 GB），整个系统里
    //    **不存在**这个名字的通知；AppKit 公开头文件 NSApplication.h 里那 20 个
    //    NSApplication*Notification 也没有 Crash 系。
    //    也就是说那个 observer 永远不会被触发，它唯一的实际作用是在启动日志里
    //    打印一句「崩溃兜底已注册」，让人误以为有这层保护。
    //
    //    真正有效的兜底是下面三层，别动它们：
    //      ① atexit + applicationWillTerminate（正常退出 / SIGTERM）
    //      ② 启动时清理上次残留的呈现模式
    //      ③ 独立看门狗进程（kill(pid,0) 探活）—— 唯一能扛 SIGKILL 的一层

    // MARK: 构建 Touch Bar + 呈现
    //
    // 用 Pock 同款机制（目前唯一在 macOS 27 上真能显示的路径）：
    //   1. presentSystemModalTouchBar(_:placement:systemTrayItemIdentifier:)
    //      placement 0 = 与控制条共享，1 = 独占主区域
    //   2. 配套把 PresentationModeGlobal 设成 "app"（独占）/ "appWithControlStrip"（共享）
    //   3. pkill ControlStrip 让模式生效
    //   4. 已显示的 bar 重复 present 不会移动，必须先 dismiss 再 present
    //
    // 之前走不通的两条路，别改回去：
    //   ① addSystemTrayItem: 往右侧控制条塞 item —— 控制条那块只留得住 1 个（用户截图实测）。
    //   ② presentSystemModalTouchBar(bar, systemTrayItemIdentifier:) —— 两参数旧版，
    //      macOS 27 上返回成功但完全不显示（present=true visible=false）。

    func buildTouchBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self

        for (i, item) in ITEMS.enumerated() {
            let cid = NSTouchBarItem.Identifier("com.xprears.tbwx.item\(i)")
            itemIDs.append(cid)
            buttonToOrder[cid] = (i, item)
            log("  声明按钮 #\(i) \(item.title)")
        }

        // ★★ 关键一行：defaultItemIdentifiers 是 NSTouchBar 的**属性**，不是 delegate 方法。
        //   官方头文件 NSTouchBar.h 里 NSTouchBarDelegate 只有一个可选方法
        //   touchBar(_:makeItemForIdentifier:)。所以之前那个
        //   「func defaultItemIdentifiers(in:)」根本不是协议方法 —— 只是个同名的普通方法，
        //   编得过、跑得到、系统永远不会调用它。
        //   不赋值 → bar.itemIdentifiers 解析为空 → itemForIdentifier: 从不被调用
        //   → makeItemForIdentifier 从不被回调 → present 返回 true 但整条不显示。
        bar.defaultItemIdentifiers = itemIDs

        // 不要设 customizationIdentifier：设了 bar 才成为「可自定义」，
        // itemIdentifiers 会改由 CustomizationPanel 决定、defaultItemIdentifiers 被忽略。
        bar.customizationAllowedItemIdentifiers = itemIDs + [.flexibleSpace]
        log("  defaultItemIdentifiers 已设为 \(bar.defaultItemIdentifiers.count) 项")
        return bar
    }

    var itemIDs: [NSTouchBarItem.Identifier] = []
    var buttonToOrder: [NSTouchBarItem.Identifier: (Int, Item)] = [:]
    var buttonToItem: [ObjectIdentifier: Item] = [:]
    var bar: NSTouchBar?
    var isPresented = false

    // ⚠️ 这里曾经写过一个 func defaultItemIdentifiers(in touchBar:)。那不是
    //    NSTouchBarDelegate 的协议方法（协议里只有 touchBar(_:makeItemForIdentifier:)），
    //    系统不会调用它，是整条 Touch Bar 不显示的真正原因。见 buildTouchBar()。

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard let (idx, item) = buttonToOrder[identifier] else {
            log("⚠️ 系统索要未知 item \(identifier.rawValue)")
            return nil
        }
        let ti = NSCustomTouchBarItem(identifier: identifier)
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: BTN_W, height: BTN_H))
        btn.title = item.title
        btn.font = .systemFont(ofSize: 11)
        btn.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
        btn.imagePosition = .imageLeading
        btn.target = self
        btn.action = #selector(onTap(_:))
        btn.setButtonType(.momentaryChange)
        btn.isBordered = false
        btn.tag = idx
        ti.view = btn

        buttonToItem[ObjectIdentifier(btn)] = item
        keepAlive.append(ti)
        keepAlive.append(btn)
        itemWasInstantiated = true
        log("  ➜ 实例化 item #\(idx)「\(item.title)」")
        return ti
    }

    /// 「一直占着」模式的显隐判断：只看前台 App 变没变。
    func applyVisibility(force: Bool = false) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let shouldShow = !onlyWhenFrontmost || front == WECHAT_BUNDLE
        if !force && shouldShow == lastShownState { return }
        lastShownState = shouldShow
        if shouldShow { present() } else { dismissBar() }
        log("Touch Bar → \(shouldShow ? "显示" : "隐藏")（前台=\(front)）")
    }

    /// 立即重算一次（启动时、菜单动作后调用）。**必须按模式分派** ——
    /// 让位模式直接走 applyVisibility 会无视「用户正在打字」这个条件。
    func refreshNow() {
        if displayMode == .always { applyVisibility(force: true) } else { tick() }
    }

    /// 把 `isPresented` 对齐**官方属性 `bar.isVisible`**。
    ///
    /// 为什么必须这样：私有 API 的 BOOL 返回值一律不可信 —— 这次连类型编码都验了，
    /// `presentSystemModalTouchBar:...` 与 `dismissSystemModalTouchBar:` 都是
    /// **`v`（void）返回**（见 /tmp/tbprobe 输出），按 BOOL 读寄存器读到的就是垃圾。
    /// 日志里的表现是「present 返回 true，几秒后 dismiss 打印 wasPresented=false」
    /// —— 解释不通的那种。`bar.isVisible` 是公开 property，它才是真值。
    func syncPresentationState() {
        guard lastShownState, let b = bar else { return }
        let vis = b.isVisible
        if vis != isPresented {
            log("🔄 状态对齐：isPresented \(isPresented) → \(vis)（以 bar.isVisible 为准）")
            isPresented = vis
        }
    }

    // MARK: 让位模式（打字时候选框优先，停手后按钮回来）

    /// 每 TICK 秒跑一次，**自己决定**显不显示 —— 不走「前台变了才动」那一套。
    ///
    /// 判据是 `CGEventSource.secondsSinceLastEventType(.keyDown)`：
    /// **公开 API、不需要任何 TCC 权限**（Input Monitoring / 屏幕录制都不要），
    /// 直接给出「距上一次物理按键过了几秒」。本机实测可用（计数 3716、时间正常递增）。
    ///
    /// 逻辑：敲键盘 → 撤下我们的 bar，把 App 区域让给输入法候选框；
    /// 停手满 TYPING_WINDOW → 把三个按钮抢回来。
    func tick() {
        if displayMode == .always {
            applyVisibility()
            syncPresentationState()
            return
        }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let shouldShow = !onlyWhenFrontmost || front == WECHAT_BUNDLE
        if shouldShow != lastShownState {
            lastShownState = shouldShow
            userClosed = false      // 前台 App 换了 → 重新给一次机会
            yieldedByTyping = true  // 本轮「我们是想显示的」，首次 tick 就会 present
            log("Touch Bar → \(shouldShow ? "显示" : "隐藏")（前台=\(front)，方式=\(displayMode.title)）")
        }
        guard shouldShow else {
            if isPresented { dismissBar() }
            return
        }

        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let typing = idle < TYPING_WINDOW && Date() > suppressYieldUntil
        let vis = bar?.isVisible ?? false

        if typing {
            if vis {
                log(String(format: "⌨️ 距上次按键 %.1fs → 让位，把 App 区域交给输入法", idle))
                yieldedByTyping = true
                dismissBar()
            }
            return
        }

        guard !vis else { return }

        guard !userClosed else { return }
        guard yieldedByTyping else {
            // vis 已成 false 但**不是我们让的** ⇒ 用户点了 Touch Bar 上的 × 手动关掉。
            // 那就别抢回来（抢回来就是跟用户对着干），等前台 App 再切一次再说。
            userClosed = true
            log("🚫 检测到手动关闭（点了 ×），本轮不再自动抢回")
            return
        }

        // 抢回来。带冷却：present 之后系统要 ~0.5s 才把 isVisible 翻上来，
        // 冷却期内不重复尝试，免得反复 dismiss/present 打断渲染通道。
        let now = Date()
        guard now.timeIntervalSince(lastReclaim) > 3 else { return }
        lastReclaim = now
        yieldedByTyping = false
        log(String(format: "⏳ 已停手 %.1fs → 抢回 Touch Bar", idle))
        present()
    }

    func present() {
        guard let b = bar else { return }
        if isPresented {
            // 已显示的 bar 重复 present 不会移动位置，必须先撤下来
            TBPrivate.dismiss(b)
            isPresented = false
            usleep(150000)
        }
        // 每次 present 都复位。原来是**粘性标志**：delegate 回调过一次就永远 true，
        // 于是下面那个「1.2s 后补 present」的补丁（L448）只在首个会话生效过，之后形同虚设。
        itemWasInstantiated = false
        // 顺序很关键（Pock 就是这个顺序）：
        //   ① 先设呈现模式 + 重载 agent，让系统切到「App Controls」渲染路径
        //   ② 等一下让 agent 起来
        //   ③ 再 present，delegate 才会被回调、按钮才会被实例化
        let mode = "appWithControlStrip"
        // 只在模式真的变了（= 真的 pkill 过 ControlStrip）时才等 agent 起来重建渲染通道。
        // 没改模式就别白等这 400ms —— 那是主线程阻塞，只会让菜单栏发顿。
        if setPresentationMode(mode) { usleep(400000) }

        let placement = 0
        let ret = TBPrivate.present(b, placement: Int32(placement))
        log("  present placement=\(placement) 返回 \(ret) 模式=\(mode) itemInstantiated=\(itemWasInstantiated)")
        // ⚠️ 不要把 ret 写进状态机：presentSystemModalTouchBar:... 的 BOOL 和
        //    dismissSystemModalTouchBar: 一样不可信（同 build 连续两次 true/false）。
        //    原实现 `isPresented = ret` 会把垃圾值写进状态机，日志里的表现就是
        //    「present 刚返回 true，几秒后 dismiss 却打印 wasPresented=false」。
        //    唯一可信的判据是官方属性 bar.isVisible —— 交给 1s 轮询去对齐。
        isPresented = true

        // 诊断：1.5s 后回读解析结果。itemIdentifiers 的个数才是「到底有几个按钮」的硬指标；
        // bar.isVisible 是官方文档定义的「已附着到 NSTouchBar provider、可显示」，
        // 比之前那个根本不存在的私有方法 isTouchBarVisible 靠谱。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let bar = self.bar else { return }
            log("  ⏱ 1.5s 后 itemIdentifiers=\(bar.itemIdentifiers.count) 个，已实例化=\(self.itemWasInstantiated)，bar.isVisible=\(bar.isVisible)")
        }

        // agent 重载有延迟，若delegate 还没被回调，补一次 present
        if !itemWasInstantiated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self else { log("  [补present] self 已释放，放弃"); return }
                log("  [补present] 到期：isPresented=\(self.isPresented) itemWasInstantiated=\(self.itemWasInstantiated)")
                guard self.isPresented, !self.itemWasInstantiated else { return }
                log("  ⟳ 补一次 present（首次没被回调）")
                TBPrivate.dismiss(self.bar!)
                usleep(120000)
                _ = TBPrivate.present(self.bar!, placement: Int32(placement))
            }
        }
    }

    var itemWasInstantiated = false

    /// 撤下模态 Touch Bar，并把全局呈现模式交还系统默认。
    ///
    /// ⚠️ **绝不要用 isPresented 来决定要不要 dismiss。**
    /// 原实现写成 `if let b = bar, isPresented { dismiss } else { 只还原模式 }`，
    /// 实测出现过「走了 else 分支、却在同一行里打印出 isPresented=true」的情况 ——
    /// 于是 `dismissSystemModalTouchBar:` 从未被调用，模态 bar 一直挂在系统上：
    /// 切到别的 App 也不消失、右侧控制条也回不来（就是「面板恒久显示」那个 bug）。
    /// dismiss 本身是幂等的（没 present 时返回 NO），无条件调用即可。
    func dismissBar() {
        if let b = bar {
            let r = TBPrivate.dismiss(b)
            log("  dismiss 调用：wasPresented=\(isPresented) 返回=\(r)")
            // 返回值不可信：如果 dismissSystemModalTouchBar: 实际声明为 void，
            // 我们按 BOOL 读寄存器就会读到垃圾值。真正的判据是 bar.isVisible ——
            // 它是官方 property，含义是「已附着到 NSTouchBar provider、可显示」，
            // 撤下成功后应变回 false。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, let bar = self.bar else { return }
                log("  ⏱ dismiss 后 0.8s：bar.isVisible=\(bar.isVisible)（false = 模态 bar 真撤下来了）")
            }
        } else {
            log("  dismiss 跳过：bar=nil")
        }
        // 交还系统默认。这里用 setPresentationMode 而不是 restoreGlobalPresentationMode：
        // 独占模式下模式确实变了，**必须伴随一次 ControlStrip 重载**，音量/亮度条才会回来；
        // 共享模式下模式本来就是 appWithControlStrip，内部会直接跳过、不会 pkill。
        setPresentationMode("appWithControlStrip")
        isPresented = false
    }

    // MARK: 菜单栏

    func setupStatusItem() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        si.button?.title = "微信TB"
        si.button?.toolTip = "Touch Bar 微信助手"
        let m = NSMenu()
        m.delegate = self

        let status = NSMenuItem(title: "辅助功能：\(isAXTrusted ? "已授权" : "未授权")",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        authMenuItem = status
        m.addItem(status)
        m.addItem(.separator())

        m.addItem(withTitle: "申请辅助功能权限", action: #selector(requestAX), keyEquivalent: "")
        let only = NSMenuItem(title: "仅微信在前台时显示", action: #selector(toggleOnly(_:)), keyEquivalent: "")
        only.target = self
        only.state = onlyWhenFrontmost ? .on : .off
        m.addItem(only)

        let dm = NSMenuItem(title: "显示方式：\(displayMode.title)",
                            action: #selector(toggleDisplayMode(_:)), keyEquivalent: "")
        dm.target = self
        m.addItem(dm)

        m.addItem(withTitle: "自检（发一次 ⌘1 → 聊天）", action: #selector(selfTest), keyEquivalent: "")
        m.addItem(withTitle: "打开日志", action: #selector(openLog), keyEquivalent: "")
        m.addItem(.separator())
        // ⚠️ 这里**必须**用 quitApp 而不是 #selector(NSApplication.terminate(_:))。
        // 下一行的 forEach 会把所有 target==nil 的项统一指向 self；若 action 是
        // NSApplication 的方法，target 就被篡改成一个不响应该 selector 的对象，
        // NSMenu 的 autoenablesItems 会直接把「退出」置灰 —— 表现就是「退出菜单是灰的」。
        m.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        m.items.forEach { if $0.action != nil && $0.target == nil { $0.target = self } }
        si.menu = m
        statusItem = si
    }

    /// 每次菜单弹出都重算授权状态并刷新标题 —— 之前这行文字是启动时算一次就写死的，
    /// 中途去系统设置授权完，菜单里还是「未授权」。
    func menuWillOpen(_ menu: NSMenu) {
        refreshAuthIndicator()
    }

    func refreshAuthIndicator() {
        let trusted = isAXTrusted
        authMenuItem?.title = "辅助功能：\(trusted ? "已授权" : "未授权")"
        let want = trusted ? "微信TB" : "微信TB ⚠︎"
        if statusItem?.button?.title != want { statusItem?.button?.title = want }
    }

    @objc func requestAX() {
        if promptForAX() {
            refreshAuthIndicator()
            hud("辅助功能已授权，可以正常发按键了", ok: true)
        } else {
            hud("请到 系统设置 → 隐私与安全性 → 辅助功能 勾选「TouchBarWX」", ok: false)
        }
    }

    @objc func toggleOnly(_ sender: NSMenuItem) {
        onlyWhenFrontmost.toggle()
        sender.state = onlyWhenFrontmost ? .on : .off
        refreshNow()
        log("切换「仅微信前台显示」→ \(onlyWhenFrontmost)")
    }

    /// 切换显示方式。先把手上这套彻底撤干净再切，否则会留下「半挂在系统上」的脏状态。
    /// 写入偏好域、重启后保持 —— 这样一次重编译就能慢慢 A/B 两种，不用反复重授权。
    @objc func toggleDisplayMode(_ sender: NSMenuItem) {
        dismissBar()
        displayMode = (displayMode == .yield) ? .always : .yield
        saveDisplayMode(displayMode)
        sender.title = "显示方式：\(displayMode.title)"
        lastShownState = false
        userClosed = false
        yieldedByTyping = true
        if displayMode == .always { applyVisibility(force: true) } else { tick() }
        log("切换显示方式 → \(displayMode.title)（已持久化）")
    }

    @objc func selfTest() {
        log("▶ 自检：AX 授权=\(isAXTrusted)，将发送 \(Key.name(Key.chat))")
        perform(Item(title: "自检", symbol: "", mode: .key(Key.chat)))
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: LOG_PATH))
    }

    /// 退出。走 NSApp.terminate 才会触发 applicationWillTerminate（撤下 bar + 还原全局模式）。
    /// 不要直接把菜单项的 action 指到 `NSApplication.terminate(_:)`，原因见 setupStatusItem。
    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 执行动作

    @objc func onTap(_ sender: NSButton) {
        guard let item = buttonToItem[ObjectIdentifier(sender)] else {
            log("✗ 按钮 #\(sender.tag) 找不到对应动作")
            return
        }
        log("👆 Touch Bar 按钮被点击：#\(sender.tag) 「\(item.title)」")
        perform(item)
    }

    func perform(_ item: Item) {
        guard !busy else { log("忙，忽略 \(item.title)"); return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.execute(item)
            // 原来这里还要再锁 0.2s：加上 execute 自身 ~0.93s ⇒ 全程 1.1s 内的连点
            // 全被 `guard !busy` 静默丢掉（日志里刷屏的「忙，忽略」就是它）。
            // execute 现在只剩 ~50ms，尾锁留 0.05s 足够防连击。
            Thread.sleep(forTimeInterval: 0.05)
            DispatchQueue.main.async { self?.busy = false }
        }
    }

    func execute(_ item: Item) {
        let t0 = Date()
        log("▶ 执行「\(item.title)」")

        guard isAXTrusted else {
            log("✗ 没有辅助功能权限，无法发送按键")
            hud("没有辅助功能权限。点菜单栏「微信TB → 申请辅助功能权限」，\n或在 系统设置 → 隐私与安全性 → 辅助功能 勾选本 App", ok: false)
            _ = promptForAX()
            return
        }

        // 1. 确保微信在运行且在前台
        var wx = weChatApp()
        if wx == nil {
            log("微信未运行，正在启动…")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "WeChat"]
            try? p.run()
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.5)
                wx = weChatApp()
                if wx != nil { break }
            }
        }
        guard let app = wx else {
            log("✗ 微信启动失败")
            hud("微信启动失败", ok: false)
            return
        }
        // 只有微信**不在前台**时才需要激活 + 等它起来。
        // 触发这个函数的两个入口（Touch Bar 按钮 / 控制条分段）都要求微信在前台
        // （onlyWhenFrontmost=true 时不显示），所以这 700ms 几乎恒白等 ——
        // 实测每次点击固定 930ms，其中 700ms 全花在这一行。
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if front != WECHAT_BUNDLE {
            log("  微信不在前台（\(front)），先激活并等 0.7s")
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            Thread.sleep(forTimeInterval: 0.7)
        }

        // 2. 执行。现在所有动作都是「发一个快捷键」。
        switch item.mode {
        case .key(let kc):
            sendKey(kc, cmd: true)
            // 我们自己的合成按键也会被 CGEventSource 计数进去。不屏蔽的话，
            // 点完按钮下一个 tick 就判定成「用户在打字」→ 立刻让位 → 按钮刚出来就没了。
            suppressYieldUntil = Date().addingTimeInterval(1.5)
            log("  已发送 \(Key.name(kc))")
        }

        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        log("✔「\(item.title)」完成，用时 \(ms)ms")
    }
}

// 看门狗模式：独立进程，盯着父进程，父进程一死就还原全局模式后退出。
// 不能碰 NSApplication——看门狗只做偏好还原，别在子进程里初始化 GUI。
let argv = CommandLine.arguments
if argv.count >= 3 && argv[1] == "--watchdog", let ppid = pid_t(argv[2]) {
    runWatchdog(parentPID: ppid)
    exit(0)   // 不会到这里
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()