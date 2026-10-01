import AppKit
import ApplicationServices
import Combine
import QuartzCore
import RyftWindowLayout

/// Native macOS adapter for a persistent, workspace-local Hyprland-style BSP
/// tree. Layout, native zoom, pointer gestures and AX writes are separate states.
final class DwindleTilingService: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Automatic tiling is off"
    @Published private(set) var managedApplicationCount = 0

    private struct WorkspaceLayout {
        var tree = DwindleTree()
        var focused: CGWindowID?
        var layout = DwindleTree.Layout()
        var area = CGRect.zero
    }
    private struct Original {
        let frame: CGRect
        let element: AXUIElement
    }
    private struct Animation {
        let window: TilingWindowObservation
        let key: TilingLayoutKey
        let from: CGRect
        let to: CGRect
        let requested: CGRect
        let start: CFTimeInterval
    }
    private struct Gesture {
        enum Kind { case title, edge, content }
        let id: CGWindowID
        let key: TilingLayoutKey
        let kind: Kind
        let point: CGPoint
        let frame: CGRect
        var dragged = false
        var releasedAt: CFTimeInterval?
    }

    private let spaces = TilingSpaceContext()
    private let bridge = TilingWindowBridge()
    private var configuration = TilingConfiguration()
    private var bar = BarConfiguration()
    private var enabled = false
    private var fallbackDesktop = 1
    private var layouts: [TilingLayoutKey: WorkspaceLayout] = [:]
    private var assignments: [CGWindowID: TilingLayoutKey] = [:]
    private var originals: [CGWindowID: Original] = [:]
    private var presentations: [CGWindowID: WindowPresentation] = [:]
    private var minimums: [CGWindowID: CGSize] = [:]
    private var nativeTiles = NativeTileMemory()
    private var writeBackoff: [CGWindowID: CFTimeInterval] = [:]
    private var observed: [TilingWindowObservation] = []
    private var contexts: [TilingDisplayContext] = []
    private var gesture: Gesture?
    private var settleUntil: CFTimeInterval = 0
    private var lastTitleDown: (id: CGWindowID, frame: CGRect, at: CFTimeInterval)?
    private let traceURL = ProcessInfo.processInfo.environment["RYFT_TILING_TRACE"].map { URL(fileURLWithPath: $0) }
    private var pendingSignature = ""
    private var stableObservations = 0
    private var timer: Timer?
    private var animationTimer: Timer?
    private var animations: [CGWindowID: Animation] = [:]
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    init() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] in self?.pointerEvent($0) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.spaceChanged() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.spaceChanged() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.spaceChanged() })
    }
    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        timer?.invalidate(); animationTimer?.invalidate()
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; running = value
        if traceURL != nil { NSLog("Ryft tiling enabled: %@", value.description) }
        cancelAnimations()
        if value {
            pendingSignature = ""; stableObservations = 0
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
            refresh()
        } else {
            timer?.invalidate(); timer = nil
            restoreVisibleOriginals()
            reset()
            managedApplicationCount = 0; status = "Automatic tiling is off"
        }
    }
    func updateConfiguration(_ value: TilingConfiguration) {
        guard configuration != value else { return }
        let changedMode = configuration.mode != value.mode
        configuration = value
        cancelAnimations(); gesture = nil
        if changedMode {
            // Keep the tree for switching back to Dwindle, but do not infer a
            // native resize from the old layout's in-flight animation.
            layouts.keys.forEach { layouts[$0]?.layout = DwindleTree.Layout() }
        }
        refresh()
    }
    func updateBarConfiguration(_ value: BarConfiguration) {
        guard bar != value else { return }
        bar = value; cancelAnimations(); refresh()
    }
    func updateActiveDesktop(_ value: Int) { fallbackDesktop = max(1, value); spaceChanged() }
    func shutdown() { setEnabled(false) }
    func openAccessibilitySettings() { WorkspaceController.requestAccessibility() }

    func refresh() {
        guard enabled else { return }
        defer { writeTrace() }
        guard AXIsProcessTrusted() else { status = "Accessibility permission needed"; managedApplicationCount = 0; cancelAnimations(); return }
        let now = CACurrentMediaTime()
        guard now >= settleUntil, let snapshot = bridge.snapshot(excluding: configuration.excludedBundleIdentifiers) else { return }
        contexts = spaces.current(fallbackDesktop: fallbackDesktop)
        observed = snapshot.windows
        pruneClosedWindows(snapshot.existing)
        let groups = Dictionary(uniqueKeysWithValues: contexts.filter { !$0.nativeFullscreen }.map { context in
            (context.key, observed.filter { belongs($0, to: context) })
        })
        let signature = contexts.map { "\($0.key.display):\($0.key.space):\($0.nativeFullscreen)" }.sorted().joined(separator: ",")
            + groups.keys.sorted(by: { $0.display < $1.display }).map { key in
                (groups[key] ?? []).map { "\($0.id):\($0.minimized):\($0.hidden):\($0.fullscreen)" }.sorted().joined(separator: ",")
            }.joined(separator: ";")
        if signature != pendingSignature { pendingSignature = signature; stableObservations = 1; cancelAnimations(); return }
        stableObservations += 1
        guard stableObservations >= 2 else { return }
        let pointerDown = NSEvent.pressedMouseButtons & 1 != 0
        guard !pointerDown else { cancelAnimations(); return }
        let focused = bridge.focusedWindowID(in: observed)
        let cursor = CGEvent(source: nil)?.location
        var count = 0, maximized = 0, floated = 0

        for context in contexts where !context.nativeFullscreen {
            let windows = (groups[context.key] ?? []).sorted { $0.id < $1.id }
            let visible = windows.filter { !$0.minimized && !$0.hidden && !$0.fullscreen && $0.onScreen }
            let area = DisplayLayoutMetrics.workArea(for: context.screen, bar: bar, outerGap: configuration.outerGap)
            var state = layouts[context.key] ?? WorkspaceLayout()
            for window in windows where !window.fullscreen {
                if let oldKey = assignments[window.id], oldKey != context.key { layouts[oldKey]?.tree.remove(window.id) }
                assignments[window.id] = context.key
                if !state.tree.windows.contains(window.id) {
                    if originals[window.id] == nil { originals[window.id] = Original(frame: window.frame, element: window.element) }
                    if minimums[window.id] == nil { minimums[window.id] = CGSize(width: 120, height: 80) }
                    let anchor = configuration.useActiveForSplits ? (state.focused ?? focused.flatMap { $0 != window.id ? $0 : nil }) : nil
                    state.tree.insert(window.id, nextTo: anchor, in: area, cursor: cursor, options: treeOptions)
                    // In a startup batch, open successive windows against the
                    // last inserted leaf, not CGWindow's unpredictable Z-order.
                    state.focused = window.id
                }
            }
            if let focused, state.tree.windows.contains(focused) { state.focused = focused }
            var active = Set(visible.map(\.id))
            func makeLayout() -> DwindleTree.Layout {
                configuration.mode == .dwindle
                    ? state.tree.layout(in: area, active: active, gap: configuration.gap, scale: context.screen.backingScaleFactor, options: treeOptions, minimums: minimums)
                    : DwindleTree.balanced(ids: state.tree.windows.filter { active.contains($0) }, in: area, gap: configuration.gap, scale: context.screen.backingScaleFactor)
            }
            var layout = makeLayout()
            // Honor application minimum sizes. If they physically cannot fit,
            // leave that window floating rather than overlapping its neighbors
            // or issuing the same rejected AX size every animation frame.
            while let id = state.tree.windows.reversed().first(where: { id in
                guard let frame = layout.frames[id], let minimum = minimums[id] else { return false }
                return frame.width + 2 < minimum.width || frame.height + 2 < minimum.height
            }) {
                active.remove(id); floated += 1; layout = makeLayout()
            }
            finishGesture(in: context, windows: visible, state: &state, layout: &layout, now: now)
            let animate = state.area != area || state.layout.frames != layout.frames
            state.layout = layout; state.area = area
            layouts[context.key] = state
            var decisions: [CGWindowID: WindowPresentation.Decision] = [:]
            for window in visible {
                var presentation = presentations[window.id] ?? WindowPresentation()
                decisions[window.id] = presentation.observe(frame: window.frame, nativeFullscreen: window.fullscreen, now: now, pointerDown: false)
                presentations[window.id] = presentation
            }
            // A native maximized window keeps its tree slot, but cannot block
            // corrections or newly opened windows, even on the same desktop.
            // macOS has no compositor-level mechanism to hide sibling tiles.
            for window in visible {
                guard let target = layout.frames[window.id], let decision = decisions[window.id] else { continue }
                count += 1
                switch decision {
                case .maximize:
                    maximized += 1
                    setFrame(area, window: window, key: context.key, animated: false, now: now)
                case .restoreTile:
                    // Explicit tile restoration precedes any corrective poll;
                    // no size-based heuristic can suspend it again.
                    setFrame(target, window: window, key: context.key, animated: false, now: now, bypassBackoff: true)
                case .tile:
                    setFrame(target, window: window, key: context.key, animated: animate, now: now)
                case .waitForNative, .nativeFullscreen: break
                }
            }
        }
        managedApplicationCount = count
        if count == 0 { status = contexts.contains(where: \.nativeFullscreen) ? "Native fullscreen, tiling resumes on return" : "Waiting for an application" }
        else {
            status = configuration.mode == .dwindle ? "Dwindle · \(count) window\(count == 1 ? "" : "s")" : "Sizing & positioning · \(count) window\(count == 1 ? "" : "s")"
            if maximized > 0 { status += " · \(maximized) maximized" }
            if floated > 0 { status += " · \(floated) minimum-size exception" }
        }
    }

    private func writeTrace() {
        guard let traceURL else { return }
        func rectangle(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
        let rows: [[String: Any]] = observed.map { window in
            var row: [String: Any] = ["id": window.id, "bundle": NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? "", "actual": rectangle(window.frame), "fullscreen": window.fullscreen, "minimized": window.minimized, "onScreen": window.onScreen]
            if let key = assignments[window.id], let state = layouts[key] {
                row["space"] = key.space; row["display"] = key.display; row["area"] = rectangle(state.area)
                if let tile = state.layout.frames[window.id] { row["tile"] = rectangle(tile) }
            }
            return row
        }
        let value: [String: Any] = ["status": status, "enabled": enabled, "trusted": AXIsProcessTrusted(), "pointerDown": NSEvent.pressedMouseButtons & 1 != 0, "stableObservations": stableObservations, "settleRemaining": max(0, settleUntil - CACurrentMediaTime()), "windows": rows]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: traceURL, options: .atomic) }
    }

    private var treeOptions: DwindleTree.Options {
        var options = DwindleTree.Options()
        options.preserveSplit = configuration.preserveSplit
        options.widthMultiplier = configuration.splitWidthMultiplier
        options.defaultRatio = configuration.defaultSplitRatio
        switch configuration.newWindowPlacement {
        case .cursor: options.placement = .cursor
        case .before: options.placement = .before
        case .after: options.placement = .after
        }
        return options
    }
    private func belongs(_ window: TilingWindowObservation, to context: TilingDisplayContext) -> Bool {
        if let ids = context.windowIDs, !ids.contains(window.id) { return false }
        if context.windowIDs == nil && !window.onScreen { return false }
        let best = NSScreen.screens.max { a, b in
            func score(_ screen: NSScreen) -> CGFloat {
                let r = window.frame.intersection(DisplayLayoutMetrics.quartzFrame(screen.frame))
                return r.isNull ? 0 : r.width * r.height
            }
            return score(a) < score(b)
        }
        return best.map { DisplayLayoutMetrics.displayID(for: $0) == context.key.display } ?? false
    }
    private func spaceChanged() {
        cancelAnimations(); gesture = nil; lastTitleDown = nil
        pendingSignature = ""; stableObservations = 0
        settleUntil = CACurrentMediaTime() + 0.20
    }
    private func pruneClosedWindows(_ existing: Set<CGWindowID>) {
        for key in Array(layouts.keys) {
            for id in layouts[key]?.tree.windows ?? [] where !existing.contains(id) { layouts[key]?.tree.remove(id) }
        }
        originals = originals.filter { existing.contains($0.key) }
        assignments = assignments.filter { existing.contains($0.key) }
        presentations = presentations.filter { existing.contains($0.key) }
        minimums = minimums.filter { existing.contains($0.key) }
        nativeTiles.retain(existing)
        writeBackoff = writeBackoff.filter { existing.contains($0.key) }
    }

    private func pointerEvent(_ event: NSEvent) {
        guard enabled, let point = event.cgEvent?.location else { return }
        let now = CACurrentMediaTime()
        switch event.type {
        case .leftMouseDown:
            cancelAnimations()
            guard let window = hitWindow(at: point), let key = assignments[window.id], let actual = bridge.frame(window.element) else { gesture = nil; return }
            let edge = min(abs(point.x - actual.minX), abs(point.x - actual.maxX), abs(point.y - actual.minY), abs(point.y - actual.maxY)) <= 7
            let title = isTitleChrome(window: window, frame: actual, at: point)
            gesture = Gesture(id: window.id, key: key, kind: edge ? .edge : title ? .title : .content, point: point, frame: actual)
            if event.clickCount == 1 && title {
                lastTitleDown = (window.id, actual, now)
                if presentations[window.id]?.isNormal != false, let tile = layouts[key]?.layout.frames[window.id] {
                    nativeTiles.record(window.id, requested: tile, actual: actual, tolerance: 1.05)
                }
            }
            if event.clickCount == 2 && title {
                // A global callback can arrive after the second click has
                // already triggered native zoom. Use the first click's frame.
                let first = lastTitleDown.flatMap { $0.id == window.id && now - $0.at <= NSEvent.doubleClickInterval + 0.15 ? $0.frame : nil } ?? window.frame
                var mode = presentations[window.id] ?? WindowPresentation()
                mode.titleBarDoubleClick(frame: first, now: now)
                presentations[window.id] = mode
                gesture = nil; lastTitleDown = nil
            }
        case .leftMouseDragged:
            if let start = gesture?.point, hypot(point.x - start.x, point.y - start.y) > 5 { gesture?.dragged = true }
        case .leftMouseUp: gesture?.releasedAt = now
        default: break
        }
    }
    private func hitWindow(at point: CGPoint) -> TilingWindowObservation? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return nil }
        for entry in list where (entry[kCGWindowLayer] as? NSNumber)?.intValue == 0 {
            guard let dictionary = entry[kCGWindowBounds] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: dictionary), frame.contains(point),
                  let id = (entry[kCGWindowNumber] as? NSNumber)?.uint32Value else { continue }
            // The first hit is the actual foreground window. Never fall through
            // to a tiled window underneath an excluded application or dialog.
            return observed.first { $0.id == id && !$0.fullscreen && !$0.minimized }
        }
        return nil
    }
    private func isTitleChrome(window: TilingWindowObservation, frame: CGRect, at point: CGPoint) -> Bool {
        guard point.y >= frame.minY, point.y <= frame.minY + 104 else { return false }
        var hit: AXUIElement?
        let app = AXUIElementCreateApplication(window.pid)
        var toolbar = false
        if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success {
            for _ in 0..<8 {
                guard let element = hit else { break }
                let role: String = bridge.attribute(element, kAXRoleAttribute as CFString) ?? ""
                if ["AXButton", "AXRadioButton", "AXTextField", "AXSearchField", "AXPopUpButton", "AXLink", "AXTextArea", "AXWebArea"].contains(role) { return false }
                if role == "AXToolbar" { toolbar = true }
                if role == "AXWindow" { break }
                hit = bridge.attribute(element, kAXParentAttribute as CFString)
            }
        }
        return toolbar || point.y <= frame.minY + 36
    }
    private func finishGesture(in context: TilingDisplayContext, windows: [TilingWindowObservation], state: inout WorkspaceLayout, layout: inout DwindleTree.Layout, now: CFTimeInterval) {
        guard let gesture, gesture.key == context.key, let released = gesture.releasedAt, now - released >= 0.08 else { return }
        self.gesture = nil
        guard gesture.dragged, let window = windows.first(where: { $0.id == gesture.id }) else { return }
        if presentations[window.id]?.isNormal == false {
            if gesture.kind != .content { presentations[window.id]?.restore(now: now) }
            return
        }
        guard configuration.mode == .dwindle else { return }
        switch gesture.kind {
        case .edge:
            guard abs(gesture.frame.width - window.frame.width) > 3 || abs(gesture.frame.height - window.frame.height) > 3 else { return }
            state.tree.resize(window.id, from: gesture.frame, to: window.frame, layout: state.layout)
        case .title:
            let point = CGPoint(x: window.frame.midX, y: window.frame.midY)
            if let other = state.layout.frames.keys.sorted().first(where: { $0 != window.id && state.layout.frames[$0]?.contains(point) == true }) { state.tree.swap(window.id, other) }
        case .content: return
        }
        layout = state.tree.layout(in: DisplayLayoutMetrics.workArea(for: context.screen, bar: bar, outerGap: configuration.outerGap), active: Set(windows.map(\.id)), gap: configuration.gap, scale: context.screen.backingScaleFactor, options: treeOptions, minimums: minimums)
    }

    private func setFrame(_ requested: CGRect, window: TilingWindowObservation, key: TilingLayoutKey, animated: Bool, now: CFTimeInterval, bypassBackoff: Bool = false) {
        guard bypassBackoff || now >= (writeBackoff[window.id] ?? 0) else { return }
        let normal = presentations[window.id]?.isNormal != false
        let target = normal ? nativeTiles.resolve(window.id, requested: requested) : requested
        if let animation = animations[window.id], bridge.difference(animation.to, target) < 0.5 { return }
        guard let current = bridge.frame(window.element) else { return }
        guard bridge.difference(current, target) > 0.55 else {
            animations.removeValue(forKey: window.id)
            if normal { nativeTiles.record(window.id, requested: requested, actual: current) }
            return
        }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && presentations[window.id]?.isNormal != false {
            animations[window.id] = Animation(window: window, key: key, from: current, to: target, requested: requested, start: now)
            if animationTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.advanceAnimations() }
                RunLoop.main.add(timer, forMode: .common); animationTimer = timer
            }
        } else {
            animations.removeValue(forKey: window.id)
            if bridge.apply(target, to: window.element) { learnMinimumSize(window, target: requested) }
            else { writeBackoff[window.id] = now + 1 }
        }
    }
    private func advanceAnimations() {
        guard enabled, NSEvent.pressedMouseButtons & 1 == 0, CACurrentMediaTime() >= settleUntil else { cancelAnimations(); return }
        let active = Set(spaces.current(fallbackDesktop: fallbackDesktop).filter { !$0.nativeFullscreen }.map(\.key))
        let now = CACurrentMediaTime()
        for (id, animation) in animations {
            guard active.contains(animation.key), assignments[id] == animation.key, presentations[id]?.isNormal != false else { animations.removeValue(forKey: id); continue }
            let progress = min(1, (now - animation.start) / 0.16)
            let t = CGFloat(1 - pow(1 - progress, 4))
            let a = animation.from, b = animation.to
            let frame = CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t, width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
            if !bridge.apply(frame, to: animation.window.element) { animations.removeValue(forKey: id); writeBackoff[id] = now + 1 }
            else if progress >= 1 { animations.removeValue(forKey: id); learnMinimumSize(animation.window, target: animation.requested) }
        }
        if animations.isEmpty { animationTimer?.invalidate(); animationTimer = nil }
    }
    private func learnMinimumSize(_ window: TilingWindowObservation, target: CGRect) {
        guard let actual = bridge.frame(window.element) else { return }
        if presentations[window.id]?.isNormal != false { nativeTiles.record(window.id, requested: target, actual: actual) }
        var size = minimums[window.id] ?? CGSize(width: 1, height: 1)
        if actual.width > target.width + 2 { size.width = max(size.width, actual.width) }
        if actual.height > target.height + 2 { size.height = max(size.height, actual.height) }
        minimums[window.id] = size
        if bridge.difference(actual, target) > 2 { writeBackoff[window.id] = CACurrentMediaTime() + 0.5 }
    }
    private func cancelAnimations() { animationTimer?.invalidate(); animationTimer = nil; animations.removeAll() }
    private func restoreVisibleOriginals() {
        // Quitting must not move windows on other Spaces or native fullscreen.
        guard AXIsProcessTrusted(), let snapshot = bridge.snapshot(excluding: configuration.excludedBundleIdentifiers) else { return }
        let current = spaces.current(fallbackDesktop: fallbackDesktop)
        for window in snapshot.windows where !window.minimized && !window.fullscreen && !window.hidden && window.onScreen {
            guard current.contains(where: { !$0.nativeFullscreen && belongs(window, to: $0) }), let original = originals[window.id], presentations[window.id]?.isNormal != false else { continue }
            _ = bridge.apply(original.frame, to: original.element)
        }
    }
    private func reset() {
        layouts.removeAll(); assignments.removeAll(); originals.removeAll(); presentations.removeAll()
        minimums.removeAll(); nativeTiles = NativeTileMemory(); writeBackoff.removeAll(); observed.removeAll(); contexts.removeAll(); gesture = nil; lastTitleDown = nil
    }
}
