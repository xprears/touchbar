import Cocoa
import CoreGraphics

// 微信遥控器：激活微信 → 发按键/点击 → 截整窗
// 用法:
//   wxctl key 4 cmd      发 ⌘4
//   wxctl key f cmd      发 ⌘F
//   wxctl key 1          发 1
//   wxctl click 320 688  点击屏幕坐标
//   wxctl shot           只截当前状态
//   wxctl bounds         只打印窗口坐标
//
// 截图默认存 out/wx_full.png（整窗，因为发现页没有聊天内容）

let OUT = WX.proj + "/out"

func die(_ m: String) { FileHandle.standardError.write(Data(m.utf8)) }

guard AXIsProcessTrusted() else {
    die("❌ 缺辅助功能权限\n"); exit(2)
}
guard let wx = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == WX.bundleID }) else {
    die("❌ 微信没在运行\n"); exit(3)
}

func waitMs(_ ms: Int) { usleep(useconds_t(ms) * 1000) }
func frontmost() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?" }

func windows() -> [(CGRect, Int)] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var r: [(CGRect, Int)] = []
    for w in list {
        guard let p = w[kCGWindowOwnerPID as String] as? pid_t, p == wx.processIdentifier,
              let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bd) else { continue }
        r.append((rect, w[kCGWindowLayer as String] as? Int ?? 0))
    }
    return r
}

func biggest() -> CGRect? {
    windows().filter { $0.0.width >= 200 && $0.0.height >= 150 }
        .sorted { $0.0.width * $0.0.height > $1.0.width * $1.0.height }.first?.0
}

func activate() {
    wx.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    waitMs(1200)
}

func shoot(_ path: String, _ rect: CGRect) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path]
    do { try p.run(); p.waitUntilExit(); return FileManager.default.fileExists(atPath: path) }
    catch { return false }
}

// 键码表
let KEYMAP: [String: CGKeyCode] = [
    "0":0x30,"1":0x31,"2":0x32,"3":0x33,"4":0x34,"5":0x35,"6":0x36,"7":0x37,"8":0x38,"9":0x39,
    "f":0x03,"a":0x00,"c":0x08,"d":0x02,"e":0x0E,"m":0x2E,"n":0x2D,"q":0x0C,"t":0x11,"v":0x09,
    "escape":0x35,"enter":0x24,"tab":0x30,"space":0x31,"left":0x7B,"right":0x7C,"down":0x7D,"up":0x7E
]

func sendKey(_ kc: CGKeyCode, _ cmd: Bool, _ shift: Bool) {
    var f: CGEventFlags = []
    if cmd { f.insert(.maskCommand) }
    if shift { f.insert(.maskShift) }
    let src = CGEventSource(stateID: .hidSystemState)
    let d = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)!
    d.flags = f; d.post(tap: .cghidEventTap)
    usleep(40000)
    let u = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)!
    u.flags = f; u.post(tap: .cghidEventTap)
}

// Quartz 窗口坐标是左下原点，CGEvent 鼠标坐标是左上原点，必须转换
let mainScreenH = NSScreen.screens.first?.frame.height ?? 0
let allScreens = NSScreen.screens

func toCGPoint(_ p: CGPoint) -> CGPoint {
    CGPoint(x: p.x, y: mainScreenH - p.y)
}

func sendClick(_ quartzPoint: CGPoint) {
    let p = toCGPoint(quartzPoint)
    let src = CGEventSource(stateID: .hidSystemState)
    // 先移动再点击，否则部分 App 收不到按下事件
    if let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                        mouseCursorPosition: p, mouseButton: .left) {
        mv.post(tap: .cghidEventTap)
    }
    usleep(120000)
    for down in [true, false] {
        let e = CGEvent(mouseEventSource: src, mouseType: down ? .leftMouseDown : .leftMouseUp,
                        mouseCursorPosition: p, mouseButton: .left)!
        e.post(tap: .cghidEventTap)
        if down { usleep(80000) }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "bounds"

print("微信 pid=\(wx.processIdentifier)")

switch cmd {

case "key":
    let name = (args.count > 1 ? args[1] : "4").lowercased()
    let useCmd = args.count > 2 ? args[2].lowercased().hasPrefix("cmd") : true
    let useShift = args.count > 3 ? args[2].lowercased().contains("shift") || args[3].lowercased().contains("shift") : false
    guard let kc = KEYMAP[name] else { die("❌ 未知按键 \(name)\n"); exit(5) }
    activate()
    print("发送 \(useCmd ? "⌘" : "")\(useShift ? "⇧" : "")\(name.uppercased())  发送前前台=\(frontmost())")
    sendKey(kc, useCmd, useShift)
    waitMs(2500)
    print("发送后前台=\(frontmost())")
    if let w = biggest() {
        let f = OUT + "/wx_full.png"
        print("整窗截图 \(shoot(f, w) ? "OK → \(f)" : "失败")")
        print(String(format: "窗口: x=%.0f y=%.0f w=%.0f h=%.0f", w.minX, w.minY, w.width, w.height))
    } else { print("❌ 取不到窗口坐标") }

case "click":
    guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
        die("用法: wxctl click X Y\n"); exit(5)
    }
    activate()
    print("点击 Quartz(\(Int(x)), \(Int(y))) → CGEvent(\(Int(x)), \(Int(mainScreenH - y)))  前台=\(frontmost())")
    print("点击前鼠标位置(Quartz)=\(NSEvent.mouseLocation)")
    sendClick(CGPoint(x: x, y: y))
    waitMs(1200)
    print("点击后鼠标位置(Quartz)=\(NSEvent.mouseLocation)")
    print("点击后前台=\(frontmost())")
    if let w = biggest() {
        let f = OUT + "/wx_full.png"
        print("整窗截图 \(shoot(f, w) ? "OK → \(f)" : "失败")")
        print(String(format: "窗口: x=%.0f y=%.0f w=%.0f h=%.0f", w.minX, w.minY, w.width, w.height))
    }

case "shot":
    activate()
    waitMs(1200)
    if let w = biggest() {
        let f = OUT + "/wx_full.png"
        print("前台=\(frontmost())")
        print("整窗截图 \(shoot(f, w) ? "OK → \(f)" : "失败")")
    } else { print("❌ 取不到窗口坐标") }

case "bounds":
    activate()
    print("前台=\(frontmost())")
    print("屏幕数=\(allScreens.count)  主屏高=\(Int(mainScreenH))")
    for (i, s) in allScreens.enumerated() {
        print(String(format: "  屏%d frame=%@", i, NSStringFromRect(s.frame)))
    }
    if let w = biggest() {
        print(String(format: "窗口: x=%.0f y=%.0f w=%.0f h=%.0f", w.minX, w.minY, w.width, w.height))
        print("全部微信窗口:")
        for (r, l) in windows() {
            print(String(format: "  layer=%d  x=%.0f y=%.0f w=%.0f h=%.0f", l, r.minX, r.minY, r.width, r.height))
        }
    } else { print("❌ 取不到窗口坐标") }

default:
    die("用法: wxctl [key <键> [cmd]] | [click X Y] | [shot] | [bounds]\n")
    exit(5)
}
