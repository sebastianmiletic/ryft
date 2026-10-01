import AppKit
import ApplicationServices

struct TilingWindowObservation {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let frame: CGRect
    let minimized: Bool
    let fullscreen: Bool
    let onScreen: Bool
    let hidden: Bool
}

/// Stable one-to-one CG/AX binding. Never pair a fullscreen CG window with a
/// different standard AX window just because their rectangles are closest.
final class TilingWindowBridge {
    private typealias GetWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private let library: UnsafeMutableRawPointer?
    private let getWindowID: GetWindowID?
    private var bindings: [CGWindowID: (pid_t, AXUIElement)] = [:]

    init() {
        library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
        if let library, let symbol = dlsym(library, "_AXUIElementGetWindow") { getWindowID = unsafeBitCast(symbol, to: GetWindowID.self) }
        else { getWindowID = nil }
    }
    deinit { if let library { dlclose(library) } }

    func snapshot(excluding excluded: [String]) -> (windows: [TilingWindowObservation], existing: Set<CGWindowID>)? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return nil }
        let existing = Set(list.compactMap { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value })
        bindings = bindings.filter { existing.contains($0.key) }
        let records = list.filter { ($0[kCGWindowLayer] as? NSNumber)?.intValue == 0 }
        let byPID = Dictionary(grouping: records, by: { ($0[kCGWindowOwnerPID] as? NSNumber)?.int32Value ?? -1 })
        var result: [TilingWindowObservation] = []
        for pid in byPID.keys.sorted() {
            guard pid != ProcessInfo.processInfo.processIdentifier, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  !excluded.contains(app.bundleIdentifier ?? "") else { continue }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.08)
            let elements: [AXUIElement] = attribute(application, kAXWindowsAttribute as CFString) ?? []
            let candidates = elements.compactMap { element -> (AXUIElement, CGRect, CGWindowID?)? in
                guard (attribute(element, kAXRoleAttribute as CFString) as String?) == kAXWindowRole as String,
                      (attribute(element, kAXSubroleAttribute as CFString) as String?) == kAXStandardWindowSubrole as String,
                      settable(kAXSizeAttribute as CFString, element: element),
                      settable(kAXPositionAttribute as CFString, element: element),
                      let bounds = frame(element) else { return nil }
                var number: CGWindowID = 0
                let id = getWindowID?(element, &number) == .success ? number : (attribute(element, "AXWindowNumber" as CFString) as NSNumber?)?.uint32Value
                return (element, bounds, id)
            }
            var used = Set<Int>()
            for record in (byPID[pid] ?? []).sorted(by: { (($0[kCGWindowNumber] as? NSNumber)?.uint32Value ?? 0) < (($1[kCGWindowNumber] as? NSNumber)?.uint32Value ?? 0) }) {
                guard let id = (record[kCGWindowNumber] as? NSNumber)?.uint32Value,
                      let dictionary = record[kCGWindowBounds] as? NSDictionary,
                      let cgFrame = CGRect(dictionaryRepresentation: dictionary), cgFrame.width >= 120, cgFrame.height >= 80 else { continue }
                let available = candidates.indices.filter { !used.contains($0) }
                let direct = available.first { candidates[$0].2 == id }
                let cached = bindings[id].flatMap { binding in
                    binding.0 == pid ? available.first(where: { CFEqual(candidates[$0].0, binding.1) }) : nil
                }
                let geometric = available.filter { candidates[$0].2 == nil && difference(candidates[$0].1, cgFrame) <= 8 }
                    .min { difference(candidates[$0].1, cgFrame) < difference(candidates[$1].1, cgFrame) }
                guard let index = direct ?? cached ?? geometric else { continue }
                used.insert(index)
                let candidate = candidates[index]
                bindings[id] = (pid, candidate.0)
                result.append(TilingWindowObservation(id: id, pid: pid, element: candidate.0, frame: candidate.1,
                    minimized: attribute(candidate.0, kAXMinimizedAttribute as CFString) as Bool? == true,
                    fullscreen: attribute(candidate.0, "AXFullScreen" as CFString) as Bool? == true,
                    onScreen: (record[kCGWindowIsOnscreen] as? Bool) == true, hidden: app.isHidden))
            }
        }
        return (result, existing)
    }

    func focusedWindowID(in windows: [TilingWindowObservation]) -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let focused: AXUIElement = attribute(app, kAXFocusedWindowAttribute as CFString) else { return nil }
        return windows.first { $0.pid == pid && CFEqual($0.element, focused) }?.id
    }
    func frame(_ element: AXUIElement) -> CGRect? {
        guard let p: AXValue = attribute(element, kAXPositionAttribute as CFString), let s: AXValue = attribute(element, kAXSizeAttribute as CFString) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    func apply(_ frame: CGRect, to element: AXUIElement) -> Bool {
        // Check at the write boundary too: fullscreen may have started since
        // the snapshot. Never manipulate native fullscreen or minimized windows.
        guard attribute(element, "AXFullScreen" as CFString) as Bool? != true,
              attribute(element, kAXMinimizedAttribute as CFString) as Bool? != true else { return false }
        var point = frame.origin, size = frame.size
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return false }
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        return moved == .success && resized == .success
    }
    func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }
    func difference(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }
    private func settable(_ name: CFString, element: AXUIElement) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name, &value) == .success && value.boolValue
    }
}
