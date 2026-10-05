import Cocoa
import Darwin

// 微信 Accessibility 扫描核心（无 UI，供 CLI 与 App 共用）

public enum WX {
    public static let bundleID = "com.tencent.xinWeChat"
    public static let proj = "/Users/Xprears/WorkBuddy/Touch Bar项目"
    public static var lastWindowBounds: CGRect? = nil

    public static func log(_ s: String) {
        let line = "[wxscan] " + s + "\n"
        guard let d = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(d)
    }

    public static func write(_ path: String, _ s: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try s.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log("写入失败 \(path): \(error)")
        }
    }

    // MARK: - AX 基础读取

    static func s(_ el: AXUIElement, _ key: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return "" }
        if let r = v as? String { return r }
        if let a = v as? [String] { return a.joined(separator: " | ") }
        return ""
    }

    static func i(_ el: AXUIElement, _ key: String) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    static func kids(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        if let a = v as? [AXUIElement] { return a }
        return []
    }

    static func els(_ el: AXUIElement, _ key: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return [] }
        if let a = v as? [AXUIElement] { return a }
        return []
    }

    static func attrNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success,
              let a = names as? [String] else { return [] }
        return a.sorted()
    }

    // 微信这类自绘界面有时只在私有 "AXBounds" 里给位置
    static func axBounds(_ el: AXUIElement) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXBounds" as CFString, &v) == .success else { return "" }
        if let r = v as? NSValue {
            let rect = r.rectValue
            return String(format: "x=%.0f y=%.0f w=%.0f h=%.0f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
        }
        return ""
    }

    // 优先用标准 AXPosition/AXSize，退化到私有 AXBounds
    static func rect(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
           let p = pv as? NSValue {
            var r = NSRect(origin: p.pointValue, size: .zero)
            if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
               let z = sv as? NSValue { r.size = z.sizeValue }
            if r.size.width > 1 { return CGRect(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height) }
        }
        let s = axBounds(el)
        let parts = s.split(separator: " ").compactMap { Double($0.split(separator: "=").last ?? "") }
        if parts.count == 4, parts[2] > 1, parts[3] > 1 {
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        return nil
    }


    static func geom(_ el: AXUIElement) -> String {
        var pv: CFTypeRef?, sv: CFTypeRef?
        var out = ""
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
           let p = pv as? NSValue { out += String(format: "x=%.0f y=%.0f ", p.pointValue.x, p.pointValue.y) }
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
           let z = sv as? NSValue { out += String(format: "w=%.0f h=%.0f", z.sizeValue.width, z.sizeValue.height) }
        return out
    }

    static func mods(_ m: Int) -> String {
        var r = ""
        if m & 0x100 != 0 { r += "CMD+" }
        if m & 0x200 != 0 { r += "SHIFT+" }
        if m & 0x400 != 0 { r += "CTRL+" }
        if m & 0x800 != 0 { r += "ALT+" }
        return r
    }

    // MARK: - 扫描

    public static func scan(maxDepth: Int = 9, budget: Int = 4000) -> (ax: Int, keys: [String], menu: [String], text: String) {
        var n = budget
        var pressable = 0
        var keys: [String] = []
        var menu: [String] = []
        var out = ""

        func walk(_ el: AXUIElement, _ depth: Int) {
            if n <= 0 { return }
            n -= 1
            let role = s(el, kAXRoleAttribute as String)
            let sub = s(el, kAXSubroleAttribute as String)
            let title = s(el, kAXTitleAttribute as String)
            let desc = s(el, kAXDescriptionAttribute as String)
            let value = s(el, kAXValueAttribute as String)
            let help = s(el, kAXHelpAttribute as String)

            if role == "AXMenuBarItem" && (title == "Apple" || sub == "AXMenuExtra") { return }
            if role == "AXMenuExtra" { return }

            let ind = String(repeating: "  ", count: depth)
            var line = "\(ind)\(role.isEmpty ? "?" : role)"
            if !sub.isEmpty { line += "/\(sub)" }
            if !title.isEmpty { line += "  title=\"\(title)\"" }
            if !desc.isEmpty { line += "  desc=\"\(desc)\"" }
            if !value.isEmpty && value != title { line += "  value=\"\(value)\"" }
            if !help.isEmpty { line += "  help=\"\(help)\"" }

            if role == "AXWindow" {
                let g = geom(el)
                if !g.isEmpty { line += "  [\(g)]" }
                line += "  <子元素=\(kids(el).count)>"
            }

            if role == "AXMenuItem" {
                let ch = s(el, "AXMenuItemCmdChar")
                let md = i(el, "AXMenuItemCmdModifiers")
                var key = ""
                if let md = md, !ch.isEmpty { key = "\(mods(md))\(ch)" }
                if !key.isEmpty {
                    line += "  ⌨=\(key)"
                    keys.append("\(title)\t\(key)")
                }
                var tmp: CFTypeRef?
                let canPress = AXUIElementCopyAttributeValue(el, "AXPress" as CFString, &tmp) == .success
                if canPress { pressable += 1; line += "  [可AXPress]" }
                menu.append("\(title)\t\(key.isEmpty ? "无" : key)\t\(canPress)")
            }

            out += line + "\n"
            if depth < maxDepth { for c in kids(el) { walk(c, depth + 1) } }
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return (0, [], [], "微信未运行\n")
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let isFront = front == bundleID
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        out = "=== 微信 Accessibility 扫描 ===\npid: \(app.processIdentifier)\n微信在前台: \(isFront)\n\n"

        walk(appEl, 0)

        // 窗口清单（含私有 AXBounds，用来定位侧边栏做坐标点击）
        out += "\n=== 窗口清单 ===\n"
        let wins = els(appEl, kAXWindowsAttribute as String)
        if wins.isEmpty { out += "(AXWindows 为空)\n" }
        for w in wins {
            let t = s(w, kAXTitleAttribute as String)
            let sub = s(w, kAXSubroleAttribute as String)
            let b = axBounds(w)
            let g = geom(w)
            let layer = i(w, "AXWindowLayer")
            out += "  title=\"\(t)\" subrole=\(sub) layer=\(layer ?? -1)"
            out += b.isEmpty ? " \(g)" : " AXBounds[\(b)]"
            out += " 子元素=\(kids(w).count)\n"
            if lastWindowBounds == nil, let r = rect(w) { lastWindowBounds = r }
        }

        // 应用级属性全量转储：自绘界面有时把入口藏在非标准属性里
        out += "\n=== 应用级 AX 属性 ===\n"
        for a in attrNames(appEl) {
            if a == "AXChildren" || a == "AXWindows" { continue }
            let v = s(appEl, a)
            if v.isEmpty { out += "  \(a) = (空)\n" } else { out += "  \(a) = \(v.prefix(200))\n" }
        }

        out += "\n=== 汇总 ===\nAXPress 元素: \(pressable)\n带快捷键菜单项: \(keys.count)\n"
        for k in keys { out += "  \(k.replacingOccurrences(of: "\t", with: " → "))\n" }
        return (pressable, keys, menu, out)
    }
}
