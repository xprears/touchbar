import Cocoa
import Darwin

// Touch Bar 微信快捷工具
//   显示层：私有 API 往 Touch Bar 右侧控制条塞按钮
//     （macOS 27 上「整条接管」的 presentSystemModalTouchBar 实测不显示，已放弃）
//   控制层：5 个发快捷键 + 2 个「⌘4 进发现后按坐标点击」
//
//   ⚠️ 本 App 用 ad-hoc 签名，TCC 辅助功能授权绑定在代码签名哈希上，
//      重新编译会让授权失效、需重新勾一次。所以编译完就别再改了。

let WECHAT_BUNDLE = "com.tencent.xinWeChat"
let PROJ = "/Users/Xprears/WorkBuddy/Touch Bar项目"
let LOG_PATH = PROJ + "/out/app.log"
let DFR = "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"

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

// MARK: - 配置

enum Mode {
    case key(CGKeyCode)                 // 直接发快捷键
    case discoverThenClick(CGFloat)     // ⌘4 进「发现」后点击；参数是距窗口顶部的偏移
}

struct Item {
    let title: String
    let symbol: String
    let mode: Mode
}

let ITEMS: [Item] = [
    Item(title: "聊天",   symbol: "bubble.left.and.bubble.right.fill", mode: .key(0x31)),
    Item(title: "朋友圈", symbol: "circle.hexagongrid.fill",              mode: .discoverThenClick(75)),
    Item(title: "小程序", symbol: "square.grid.2x2.fill",                 mode: .discoverThenClick(267)),
    Item(title: "视频号", symbol: "play.rectangle.fill",                 mode: .discoverThenClick(123)),
    Item(title: "搜一搜", symbol: "sparkle.magnifyingglass",              mode: .discoverThenClick(172)),
    Item(title: "搜索",   symbol: "text.cursor",                          mode: .key(0x03)),
]
// 说明：通讯录 ⌘2 / 收藏 ⌘3 微信自带快捷键，一个组合键就能到，所以不放进 Touch Bar
//       —— 控制条空间宝贵，只留用户明确要的 5 个 + 顺手一个「搜一搜」。

/// 「发现」页条目行的点击 x（相对窗口左边）。实测有效区间约 60...283。
let CLICK_DX: CGFloat = 121

// MARK: - 私有 API

typealias FnSetPresence = @convention(c) (NSString, Bool) -> Void
typealias FnCloseBox = @convention(c) (Bool) -> Void

var setPresence: FnSetPresence?
var closeBox: FnCloseBox?

func loadPrivateAPI() -> Bool {
    let selAdd = NSSelectorFromString("addSystemTrayItem:")
    guard NSTouchBarItem.responds(to: selAdd) else {
        log("❌ addSystemTrayItem 私有方法不存在")
        return false
    }
    guard let h = dlopen(DFR, RTLD_NOW) else {
        log("❌ dlopen DFRFoundation 失败: \(String(cString: dlerror()))")
        return false
    }
    guard let p1 = dlsym(h, "DFRElementSetControlStripPresenceForIdentifier"),
          let p2 = dlsym(h, "DFRSystemModalShowsCloseBoxWhenFrontMost") else {
        log("❌ dlsym 失败")
        return false
    }
    setPresence = unsafeBitCast(p1, to: FnSetPresence.self)
    closeBox = unsafeBitCast(p2, to: FnCloseBox.self)
    closeBox?(false)
    log("✅ 私有 API 加载成功")
    return true
}

// MARK: - 输入模拟

let mainScreenH = NSScreen.screens.first?.frame.height ?? 0

func sendKey(_ kc: CGKeyCode, cmd: Bool) {
    let src = CGEventSource(stateID: .hidSystemState)
    let f: CGEventFlags = cmd ? [.maskCommand] : []
    let d = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)!
    d.flags = f; d.post(tap: .cghidEventTap)
    usleep(45000)
    let u = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)!
    u.flags = f; u.post(tap: .cghidEventTap)
}

func clickQuartz(_ p: CGPoint) {
    let cg = CGPoint(x: p.x, y: mainScreenH - p.y)   // 左下原点 → 左上原点
    let src = CGEventSource(stateID: .hidSystemState)
    if let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                        mouseCursorPosition: cg, mouseButton: .left) {
        mv.post(tap: .cghidEventTap)
    }
    usleep(150000)
    for down in [true, false] {
        let e = CGEvent(mouseEventSource: src, mouseType: down ? .leftMouseDown : .leftMouseUp,
                        mouseCursorPosition: cg, mouseButton: .left)!
        e.post(tap: .cghidEventTap)
        if down { usleep(80000) }
    }
}

func weChatApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == WECHAT_BUNDLE }
}

func weChatWindow() -> CGRect? {
    guard let wx = weChatApp() else { return nil }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    var best: CGRect? = nil
    for w in list {
        guard let p = w[kCGWindowOwnerPID as String] as? pid_t, p == wx.processIdentifier,
              let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd),
              r.width >= 200, r.height >= 150 else { continue }
        if best == nil || r.width * r.height > best!.width * best!.height { best = r }
    }
    return best
}

// MARK: - HUD

func hud(_ msg: String, ok: Bool) {
    DispatchQueue.main.async {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 78),
                        styleMask: [.titled], backing: .buffered, defer: false)
        p.title = ok ? "Touch Bar 微信助手" : "执行失败"
        p.level = .floating
        p.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 78))
        let tf = NSTextField(labelWithString: msg)
        tf.font = .systemFont(ofSize: 14)
        tf.frame = NSRect(x: 16, y: 20, width: 348, height: 40)
        v.addSubview(tf)
        p.contentView = v
        p.center(); p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { p.orderOut(nil) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    var keepAlive: [Any] = []
    var itemIDs: [NSTouchBarItem.Identifier] = []
    var buttonToItem: [ObjectIdentifier: Item] = [:]
    var statusItem: NSStatusItem?
    var pollTimer: Timer?
    var onlyWhenFrontmost = true
    var lastShownState = false
    var busy = false

    func applicationDidFinishLaunching(_ n: Notification) {
        log("=== Touch Bar 微信助手启动 ===")
        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        guard loadPrivateAPI() else {
            hud("私有 API 不可用，Touch Bar 按钮无法注册", ok: false)
            return
        }
        registerItems()
        setupStatusItem()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.applyVisibility()
        }
        applyVisibility()

        if !AXIsProcessTrusted() {
            log("⚠️ 辅助功能未授权，发按键/点击会失效")
            hud("请到 系统设置 → 隐私与安全性 → 辅助功能 勾选「TouchBarWX」", ok: false)
        }
    }

    // MARK: 注册控制条按钮

    func registerItems() {
        let selAdd = NSSelectorFromString("addSystemTrayItem:")
        for (i, item) in ITEMS.enumerated() {
            let id = NSTouchBarItem.Identifier("com.xprears.tbwx.item\(i)")
            let ti = NSCustomTouchBarItem(identifier: id)
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 30))
            btn.title = ""
            btn.toolTip = item.title
            btn.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
            btn.target = self
            btn.action = #selector(onTap(_:))
            btn.setButtonType(.momentaryChange)
            ti.view = btn
            _ = (NSTouchBarItem.self as AnyObject).perform(selAdd, with: ti)
            setPresence?(id.rawValue as NSString, true)
            keepAlive.append(ti)
            keepAlive.append(btn)
            itemIDs.append(id)
            buttonToItem[ObjectIdentifier(btn)] = item
            log("注册按钮 #\(i) \(item.title)  id=\(id.rawValue)")
        }
    }

    func applyVisibility() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let shouldShow = !onlyWhenFrontmost || front == WECHAT_BUNDLE
        guard shouldShow != lastShownState else { return }
        lastShownState = shouldShow
        for id in itemIDs { setPresence?(id.rawValue as NSString, shouldShow) }
        log("按钮可见性 → \(shouldShow ? "显示" : "隐藏")（前台=\(front)）")
    }

    // MARK: 菜单栏

    func setupStatusItem() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        si.button?.title = "微信TB"
        let m = NSMenu()

        let status = NSMenuItem(title: AXIsProcessTrusted() ? "辅助功能：已授权" : "辅助功能：未授权",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        m.addItem(.separator())

        let only = NSMenuItem(title: "仅微信在前台时显示", action: #selector(toggleOnly(_:)), keyEquivalent: "")
        only.target = self
        only.state = onlyWhenFrontmost ? .on : .off
        m.addItem(only)

        m.addItem(withTitle: "自检（发一次 ⌘1）", action: #selector(selfTest), keyEquivalent: "")
        m.addItem(withTitle: "打开日志", action: #selector(openLog), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { if $0.action != nil && $0.target == nil { $0.target = self } }
        si.menu = m
        statusItem = si
    }

    @objc func toggleOnly(_ sender: NSMenuItem) {
        onlyWhenFrontmost.toggle()
        sender.state = onlyWhenFrontmost ? .on : .off
        lastShownState = !lastWhenShownStateNeeded()
        applyVisibility()
        log("切换「仅微信前台显示」→ \(onlyWhenFrontmost)")
    }

    private func lastWhenShownStateNeeded() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return !onlyWhenFrontmost || front == WECHAT_BUNDLE
    }

    @objc func selfTest() {
        perform(.init(title: "自检", symbol: "", mode: .key(0x31)))
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: LOG_PATH))
    }

    // MARK: 执行动作

    @objc func onTap(_ sender: NSButton) {
        guard let item = buttonToItem[ObjectIdentifier(sender)] else { return }
        perform(item)
    }

    func perform(_ item: Item) {
        guard !busy else { log("忙，忽略 \(item.title)"); return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.execute(item)
            Thread.sleep(forTimeInterval: 0.2)
            DispatchQueue.main.async { self?.busy = false }
        }
    }

    func execute(_ item: Item) {
        let t0 = Date()
        log("▶ 执行「\(item.title)」")

        guard AXIsProcessTrusted() else {
            log("✗ 没有辅助功能权限，无法发送按键")
            hud("没有辅助功能权限，请到 系统设置 → 隐私与安全性 → 辅助功能 勾选本 App", ok: false)
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
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.7)

        // 2. 执行
        switch item.mode {
        case .key(let kc):
            sendKey(kc, cmd: true)
            log("  已发送快捷键 keycode=\(kc)")

        case .discoverThenClick(let topOffset):
            sendKey(0x34, cmd: true)            // ⌘4 → 发现
            log("  已发送 ⌘4，等待页面切换…")
            Thread.sleep(forTimeInterval: 1.6)
            guard let win = weChatWindow() else {
                log("✗ 取不到微信窗口坐标")
                hud("取不到微信窗口坐标", ok: false)
                return
            }
            let pt = CGPoint(x: win.minX + CLICK_DX, y: win.maxY - topOffset)
            log(String(format: "  点击发现页 (%.0f, %.0f)  窗口=(%.0f,%.0f,%.0fx%.0f)",
                       pt.x, pt.y, win.minX, win.minY, win.width, win.height))
            clickQuartz(pt)
        }

        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        log("✔「\(item.title)」完成，用时 \(ms)ms")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
