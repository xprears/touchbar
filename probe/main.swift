import Cocoa
import Darwin

let PROJ = "/Users/Xprears/WorkBuddy/Touch Bar项目"
let LOG_PATH = "/tmp/tbprobe_probe.log"
let STATUS_PATH = PROJ + "/out/status.txt"
let DUMP_PATH = PROJ + "/out/wechat_ax.txt"
let WECHAT_BUNDLE_ID = "com.tencent.xinWeChat"
let DFR_PATH = "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"

func writeText(_ path: String, _ s: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? s.write(to: url, atomically: true, encoding: .utf8)
}

func log(_ s: String) {
    let line = "[probe] " + s + "\n"
    guard let d = line.data(using: .utf8) else { return }
    FileHandle.standardError.write(d)
    if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: LOG_PATH)) {
        fh.seekToEndOfFile(); fh.write(d); try? fh.close()
    } else {
        try? d.write(to: URL(fileURLWithPath: LOG_PATH))
    }
}

var statusLines: [String] = []
func setStatus(_ k: String, _ v: String) {
    statusLines.removeAll { $0.hasPrefix("\(k)\t") }
    statusLines.append("\(k)\t\(v)")
    writeText(STATUS_PATH, statusLines.sorted().joined(separator: "\n") + "\n")
}

func statusOf(_ k: String) -> String {
    statusLines.first { $0.hasPrefix("\(k)\t") }
        .map { String($0.dropFirst(k.count + 1)) } ?? ""
}

// MARK: - 屏幕上的可见提示（不依赖 Touch Bar）

var flashPanel: NSPanel?
func flash(_ msg: String) {
    DispatchQueue.main.async {
        if flashPanel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 100),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
            p.title = "Touch Bar 助手"
            p.level = .floating
            p.isReleasedWhenClosed = false
            flashPanel = p
        }
        guard let p = flashPanel, let v = p.contentView else { return }
        for s in v.subviews { s.removeFromSuperview() }
        let tf = NSTextField(labelWithString: msg)
        tf.stringValue = msg
        tf.font = .systemFont(ofSize: 15)
        tf.isEditable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.frame = NSRect(x: 16, y: 16, width: 488, height: 68)
        v.addSubview(tf)
        p.center()
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { p.orderOut(nil) }
    }
}

// MARK: - AX 扫描

func axString(_ el: AXUIElement, _ key: String) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return "" }
    if let s = v as? String { return s }
    if let arr = v as? [String] { return arr.joined(separator: " | ") }
    return ""
}

func axInt(_ el: AXUIElement, _ key: String) -> Int? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
    if let arr = v as? [AXUIElement] { return arr }
    return []
}

func axGeom(_ el: AXUIElement, _ pKey: String, _ sKey: String) -> String {
    var pv: CFTypeRef?, sv: CFTypeRef?
    var out = ""
    if AXUIElementCopyAttributeValue(el, pKey as CFString, &pv) == .success,
       let p = pv as? NSValue { out += String(format: "x=%.0f y=%.0f ", p.pointValue.x, p.pointValue.y) }
    if AXUIElementCopyAttributeValue(el, sKey as CFString, &sv) == .success,
       let s = sv as? NSValue { out += String(format: "w=%.0f h=%.0f", s.sizeValue.width, s.sizeValue.height) }
    return out
}

func decodeMods(_ m: Int) -> String {
    var s = ""
    if m & 0x100 != 0 { s += "CMD+" }
    if m & 0x200 != 0 { s += "SHIFT+" }
    if m & 0x400 != 0 { s += "CTRL+" }
    if m & 0x800 != 0 { s += "ALT+" }
    return s
}

var nodeBudget = 4000
var shortcuts: [String] = []
var pressableCount = 0
var menuItems: [String] = []

func dumpTree(_ el: AXUIElement, depth: Int, maxDepth: Int, into out: inout String) {
    if nodeBudget <= 0 { return }
    nodeBudget -= 1
    let indent = String(repeating: "  ", count: depth)
    let role = axString(el, kAXRoleAttribute as String)
    let subrole = axString(el, kAXSubroleAttribute as String)
    let title = axString(el, kAXTitleAttribute as String)
    let desc = axString(el, kAXDescriptionAttribute as String)
    let value = axString(el, kAXValueAttribute as String)
    let help = axString(el, kAXHelpAttribute as String)

    if role == "AXMenuBarItem" && (title == "Apple" || subrole == "AXMenuExtra") { return }
    if role == "AXMenuExtra" { return }

    var line = "\(indent)\(role.isEmpty ? "?" : role)"
    if !subrole.isEmpty { line += "/\(subrole)" }
    if !title.isEmpty { line += "  title=\"\(title)\"" }
    if !desc.isEmpty { line += "  desc=\"\(desc)\"" }
    if !value.isEmpty && value != title { line += "  value=\"\(value)\"" }
    if !help.isEmpty { line += "  help=\"\(help)\"" }

    if role == "AXWindow" {
        let g = axGeom(el, kAXPositionAttribute as String, kAXSizeAttribute as String)
        if !g.isEmpty { line += "  [\(g)]" }
        line += "  <子元素=\(axChildren(el).count)>"
    }

    if role == "AXMenuItem" {
        let ch = axString(el, "AXMenuItemCmdChar")
        let md = axInt(el, "AXMenuItemCmdModifiers")
        var key = ""
        if let md = md, !ch.isEmpty { key = "\(decodeMods(md))\(ch)" }
        if !key.isEmpty {
            line += "  ⌨=\(key)"
            shortcuts.append("「\(title)」→ \(key)")
        }
        var tmp: CFTypeRef?
        let pressable = AXUIElementCopyAttributeValue(el, "AXPress" as CFString, &tmp) == .success
        if pressable {
            pressableCount += 1
            line += "  [可AXPress]"
        }
        menuItems.append("\(title)\tkey=\(key.isEmpty ? "无" : key)\tpressable=\(pressable)")
    }

    out += line + "\n"
    guard depth < maxDepth else { return }
    for c in axChildren(el) { dumpTree(c, depth: depth + 1, maxDepth: maxDepth, into: &out) }
}

func scanWeChat(reason: String) {
    nodeBudget = 4000; shortcuts = []; pressableCount = 0; menuItems = []

    guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == WECHAT_BUNDLE_ID }) else {
        setStatus("scan", "微信未运行"); return
    }
    guard AXIsProcessTrusted() else {
        setStatus("scan", "等待辅助功能授权"); return
    }
    let pid = app.processIdentifier
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    let isFront = front == WECHAT_BUNDLE_ID
    log("扫描触发: \(reason) pid=\(pid) 微信在前台=\(isFront)")

    var out = "=== WeChat AX 扫描 ===\npid: \(pid)\n微信在前台: \(isFront)\n\n"
    dumpTree(AXUIElementCreateApplication(pid), depth: 0, maxDepth: 9, into: &out)
    out += "\n=== 汇总 ===\nAXPress 元素: \(pressableCount)\n带快捷键菜单项:\n"
    for s in shortcuts { out += "  \(s)\n" }

    writeText(DUMP_PATH, out)
    writeText(PROJ + "/out/wechat_menu.tsv", menuItems.joined(separator: "\n") + "\n")

    let summary = "AXPress=\(pressableCount) 快捷键=\(shortcuts.count) 微信前台=\(isFront)"
    setStatus("scan", "完成 " + summary)
    log("扫描完成: \(summary)")
    flash("✅ 微信界面扫描完成\nAXPress 元素 \(pressableCount) 个，带快捷键 \(shortcuts.count) 条\n微信在前台: \(isFront ? "是" : "否")")
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {

    let trayID = NSTouchBarItem.Identifier("com.xprears.tbprobe.tray")
    let labels = ["聊天", "朋友圈", "小程序", "视频号", "搜索", "通讯录"]
    var timer: Timer?
    var presentTick = 0

    func setupStatusItem() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        si.button?.title = "微"
        let menu = NSMenu()
        menu.addItem(withTitle: "立即扫描微信界面", action: #selector(menuScan), keyEquivalent: "r")
        menu.addItem(withTitle: "重新显示 Touch Bar", action: #selector(menuPresent), keyEquivalent: "")
        menu.addItem(withTitle: "打开输出目录", action: #selector(menuOpen), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        si.menu = menu
        setStatus("menu", "就绪")
    }

    @objc func menuScan() { scanWeChat(reason: "菜单") }
    @objc func menuPresent() { presentTouchBar(force: true); flash("已重新请求显示 Touch Bar") }
    @objc func menuOpen() { NSWorkspace.shared.open(URL(fileURLWithPath: PROJ + "/out")) }

    func touchBarVisible() -> Bool {
        let sel = NSSelectorFromString("isTouchBarVisible")
        guard NSTouchBar.responds(to: sel),
              let imp = class_getMethodImplementation(NSTouchBar.self, sel) else { return false }
        let f = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        return f(NSTouchBar.self as AnyObject, sel)
    }

    func setupTouchBar() -> Bool {
        let selAdd = NSSelectorFromString("addSystemTrayItem:")
        let selPresent = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        guard NSTouchBarItem.responds(to: selAdd), NSTouchBar.responds(to: selPresent) else {
            setStatus("private_api", "私有 API 不可用"); return false
        }
        setStatus("private_api", "可用")
        guard let handle = dlopen(DFR_PATH, RTLD_NOW) else {
            setStatus("private_api", "dlopen 失败"); return false
        }
        guard let pPresence = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier"),
              let pClose = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else {
            setStatus("private_api", "dlsym 失败"); return false
        }
        typealias FnPresence = @convention(c) (NSString, Bool) -> Void
        typealias FnClose = @convention(c) (Bool) -> Void
        let setPresence = unsafeBitCast(pPresence, to: FnPresence.self)
        unsafeBitCast(pClose, to: FnClose.self)(false)

        let trayItem = NSCustomTouchBarItem(identifier: trayID)
        trayItem.view = NSButton(title: "微", target: self, action: #selector(onTap(_:)))
        _ = (NSTouchBarItem.self as AnyObject).perform(selAdd, with: trayItem)
        setPresence(trayID.rawValue as NSString, true)

        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = labels.map { NSTouchBarItem.Identifier($0) }
        _ = (NSTouchBar.self as AnyObject).perform(selPresent, with: bar, with: trayID.rawValue)
        return true
    }

    func presentTouchBar(force: Bool) {
        presentTick += 1
        let ok = setupTouchBar()
        let vis = touchBarVisible()
        setStatus("touchbar", "present=\(ok) visible=\(vis) tick=\(presentTick)")
        if force { log("呈现 Touch Bar: present=\(ok) visible=\(vis)") }
    }

    @objc func onTap(_ sender: NSButton) {
        if sender.title == "微" || sender.title.hasPrefix("✓") {
            sender.title = "扫描…"
            scanWeChat(reason: "Touch Bar 按钮")
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        log("=== probe v4 启动 ===")
        log("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        setStatus("app", "运行中 pid=\(ProcessInfo.processInfo.processIdentifier)")
        setStatus("ax", AXIsProcessTrusted() ? "已授权" : "未授权")

        setupStatusItem()
        presentTouchBar(force: true)
        scanWeChat(reason: "启动")

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let axOK = AXIsProcessTrusted()
            setStatus("ax", axOK ? "已授权" : "未授权")
            if axOK && !statusOf("scan").hasPrefix("完成") {
                scanWeChat(reason: "自动重试")
            }
            if self.presentTick < 4 { self.presentTouchBar(force: false) }
        }
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        item.view = NSButton(title: id.rawValue, target: self, action: #selector(onTap(_:)))
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
