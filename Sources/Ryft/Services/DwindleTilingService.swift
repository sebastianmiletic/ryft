import AppKit
import ApplicationServices
import Combine
import QuartzCore

/// Ryft-owned automatic Dwindle tiling. The engine manages every resizable
/// standard window visible on the active desktop, including multiple windows
/// from one application. Each additional window recursively splits the layout.
final class DwindleTilingService: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Automatic tiling is off"
    @Published private(set) var managedApplicationCount = 0

    private struct ManagedWindow {
        let id: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        let frame: CGRect
        let screen: NSScreen
    }

    private struct OriginalWindow {
        let frame: CGRect
        let element: AXUIElement
    }

    private struct FrameAnimation {
        let element: AXUIElement
        let from: CGRect
        let to: CGRect
        let startedAt: CFTimeInterval
        let duration: CFTimeInterval
    }

    private enum SplitAxis { case horizontal, vertical }
    private struct LayoutKey: Hashable {
        let display: CGDirectDisplayID
        let desktop: Int
    }
    private struct LayoutSplit {
        let index: Int
        let axis: SplitAxis
        let container: CGRect
        let boundary: CGFloat
    }

    private var enabled = false
    private var timer: Timer?
    private var animationTimer: Timer?
    private var animations: [CGWindowID: FrameAnimation] = [:]
    private var bar = BarConfiguration()
    private var configuration = TilingConfiguration()
    private var originalWindows: [CGWindowID: OriginalWindow] = [:]
    private var zoomSuspendedWindowIDs = Set<CGWindowID>()
    private var zoomSuspendedAt: [CGWindowID: CFTimeInterval] = [:]
    private var pendingNativeZoomWindowID: CGWindowID?
    private var pendingNativeZoomAt: CFTimeInterval = 0
    private var doubleClickMonitor: Any?
    private var windowOrder: [CGWindowID: Int] = [:]
    private var nextOrder = 0
    private var appliedLayoutSignature: [String] = []
    private var pendingLayoutSignature: [String] = []
    private var pendingLayoutObservations = 0
    private var forceNextLayout = true
    private var expectedFrames: [CGWindowID: CGRect] = [:]
    private var splitRatios: [LayoutKey: [CGFloat]] = [:]
    private var activeDesktop = 1
    private var pointerWasDown = false
    private var pointerInteractionActive = false
    private var pointerBaseline: [CGWindowID: CGRect] = [:]

    init() {
        doubleClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard event.clickCount >= 2, let point = event.cgEvent?.location else { return }
            self?.recordNativeTitleBarDoubleClick(at: point)
        }
    }

    deinit {
        if let doubleClickMonitor { NSEvent.removeMonitor(doubleClickMonitor) }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value {
            forceNextLayout = true
            running = true
            status = AXIsProcessTrusted() ? "Waiting for an application" : "Accessibility permission needed"
            startTimer()
            tileVisibleApplications()
        } else {
            restoreManagedWindows(animated: true)
            timer?.invalidate(); timer = nil
            expectedFrames.removeAll(); splitRatios.removeAll(); zoomSuspendedWindowIDs.removeAll(); zoomSuspendedAt.removeAll(); pendingNativeZoomWindowID = nil; pointerWasDown = false; pointerInteractionActive = false; pointerBaseline.removeAll()
            running = false
            managedApplicationCount = 0
            status = "Automatic tiling is off"
        }
    }

    func updateBarConfiguration(_ configuration: BarConfiguration) {
        guard bar != configuration else { return }
        bar = configuration
        forceNextLayout = true
        if enabled { tileVisibleApplications() }
    }

    func updateConfiguration(_ configuration: TilingConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        forceNextLayout = true
        if enabled { tileVisibleApplications() }
    }

    func refresh() {
        guard enabled else { return }
        tileVisibleApplications()
    }

    func updateActiveDesktop(_ desktop: Int) {
        let desktop = max(1, desktop)
        guard activeDesktop != desktop else { return }
        activeDesktop = desktop
        forceNextLayout = true
        expectedFrames.removeAll()
        pointerWasDown = false
        pointerInteractionActive = false
        pointerBaseline.removeAll()
        if enabled { tileVisibleApplications() }
    }

    func shutdown() {
        guard enabled else { return }
        restoreManagedWindows(animated: false)
        timer?.invalidate(); timer = nil
        animationTimer?.invalidate(); animationTimer = nil
        animations.removeAll()
        expectedFrames.removeAll(); splitRatios.removeAll(); zoomSuspendedWindowIDs.removeAll(); zoomSuspendedAt.removeAll(); pendingNativeZoomWindowID = nil; pointerWasDown = false; pointerInteractionActive = false; pointerBaseline.removeAll()
        enabled = false
    }

    func openAccessibilitySettings() {
        WorkspaceController.requestAccessibility()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tileVisibleApplications() }
    }

    private func tileVisibleApplications() {
        guard enabled else { return }
        guard AXIsProcessTrusted() else {
            managedApplicationCount = 0
            status = "Accessibility permission needed"
            return
        }

        let windows = visibleApplicationWindows()
        let signature = windows
            .map { "\($0.id):\(displayID(for: $0.screen))" }
            .sorted()
        if !forceNextLayout, signature != appliedLayoutSignature {
            if signature == pendingLayoutSignature {
                pendingLayoutObservations += 1
            } else {
                pendingLayoutSignature = signature
                pendingLayoutObservations = 1
            }
            // Ignore one-off CGWindowList omissions and transient windows. A
            // membership/display change must survive two consecutive polls.
            guard pendingLayoutObservations >= 2 else { return }
        }
        forceNextLayout = false
        appliedLayoutSignature = signature
        pendingLayoutSignature = []
        pendingLayoutObservations = 0

        let interactionGroups = Dictionary(grouping: windows, by: { displayID(for: $0.screen) })

        // While the pointer is down, let the native window edge or title bar
        // track the pointer without Ryft fighting AppKit. On release, translate
        // the gesture into either a divider ratio or a slot swap.
        let pointerDown = NSEvent.pressedMouseButtons & 1 != 0
        let suspendedBeforeGestureEnd = zoomSuspendedWindowIDs
        if !pointerDown { updateZoomSuspensions(windows) }
        let newlyZoomed = !zoomSuspendedWindowIDs.subtracting(suspendedBeforeGestureEnd).isEmpty
        if pointerDown {
            if !pointerWasDown {
                pointerWasDown = true
                animationTimer?.invalidate(); animationTimer = nil
                animations.removeAll()
                pointerBaseline = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
            } else if windows.contains(where: { window in
                pointerBaseline[window.id].map { frameDifference(window.frame, $0) > 3 } ?? false
            }) {
                pointerInteractionActive = true
            }
            // Pausing corrective writes during a left-button gesture keeps
            // native edge and title-bar tracking smooth and race-free.
            return
        } else if pointerWasDown {
            pointerWasDown = false
            pointerBaseline.removeAll()
            if pointerInteractionActive {
                pointerInteractionActive = false
                if !newlyZoomed { absorbPointerInteraction(windows: windows, grouped: interactionGroups) }
            }
        }

        // Keep maximized windows in their existing layout slots. Their frames
        // are skipped below, while every other window continues receiving its
        // normal target. This avoids both layout collapse and a stale maximize
        // state disabling the entire tiler.
        let grouped = Dictionary(grouping: windows, by: { displayID(for: $0.screen) })

        var tiledIDs = Set<CGWindowID>()
        var tiledApplicationCount = 0
        var nextExpectedFrames: [CGWindowID: CGRect] = [:]

        for (display, displayWindows) in grouped {
            let ordered = displayWindows.sorted { order(for: $0.id) < order(for: $1.id) }
            guard let screen = ordered.first?.screen else { continue }

            tiledApplicationCount += ordered.count
            let frame = availableFrame(for: screen)
            let ratios = ratios(for: LayoutKey(display: display, desktop: activeDesktop), count: ordered.count)
            let frames = dwindleLayout(count: ordered.count, in: frame, ratios: ratios).frames
            for (window, target) in zip(ordered, frames) {
                if originalWindows[window.id] == nil { originalWindows[window.id] = OriginalWindow(frame: window.frame, element: window.element) }
                nextExpectedFrames[window.id] = target
                tiledIDs.insert(window.id)
                if !zoomSuspendedWindowIDs.contains(window.id) {
                    setFrame(target, for: window.element, id: window.id)
                }
            }
        }

        // A window that was tiled and is now the only application on its
        // visible display returns to the frame it had before Ryft touched it.
        for window in windows where originalWindows[window.id] != nil && !tiledIDs.contains(window.id) && !zoomSuspendedWindowIDs.contains(window.id) { restore([window]) }
        let existingIDs = allWindowIDs()
        originalWindows = originalWindows.filter { existingIDs.contains($0.key) }
        windowOrder = windowOrder.filter { existingIDs.contains($0.key) }
        zoomSuspendedWindowIDs.formIntersection(existingIDs)
        expectedFrames = nextExpectedFrames

        managedApplicationCount = tiledApplicationCount
        let suspended = zoomSuspendedWindowIDs.count
        switch (tiledApplicationCount, suspended) {
        case (0, _): status = "Waiting for an application"
        case (1, 0): status = "Filling the display with 1 window"
        case (let count, 0): status = "Tiling \(count) windows"
        case (let count, let maximized): status = "Tiling \(count) windows · \(maximized) maximized"
        }
    }

    private func updateZoomSuspensions(_ windows: [ManagedWindow]) {
        let now = CACurrentMediaTime()
        if now - pendingNativeZoomAt > 1.4 { pendingNativeZoomWindowID = nil }
        for window in windows {
            let available = availableFrame(for: window.screen)
            let coversDisplay = window.frame.width >= available.width * 0.88
                && window.frame.height >= available.height * 0.88
                && abs(window.frame.midX - available.midX) <= 36
                && abs(window.frame.midY - available.midY) <= 36
            if zoomSuspendedWindowIDs.contains(window.id) {
                // macOS owns the maximized frame. A second native title-bar
                // double-click restores it; only then does tiling resume.
                if !coversDisplay, now - (zoomSuspendedAt[window.id] ?? 0) > 0.75 {
                    zoomSuspendedWindowIDs.remove(window.id)
                    zoomSuspendedAt.removeValue(forKey: window.id)
                }
            } else if let expected = expectedFrames[window.id], coversDisplay,
                      frameDifference(window.frame, expected) > 40 {
                // Fallback for systems where the global mouse monitor is not
                // delivered: observe macOS's completed zoom frame before this
                // layout pass can overwrite it.
                animationTimer?.invalidate(); animationTimer = nil
                animations.removeValue(forKey: window.id)
                zoomSuspendedWindowIDs.insert(window.id)
                zoomSuspendedAt[window.id] = now
                pendingNativeZoomWindowID = nil
            }
        }
    }

    private func recordNativeTitleBarDoubleClick(at point: CGPoint) {
        guard enabled,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  pid != ownPID,
                  (info[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.contains(point),
                  let number = info[kCGWindowNumber] as? NSNumber else { continue }
            let titleHeight = min(58, max(30, frame.height * 0.10))
            // CGWindow and CGEvent both use Quartz's top-left display space.
            // Restrict this to title/tab chrome so page double-clicks never
            // suspend a browser from tiling.
            guard point.y <= frame.minY + titleHeight else { continue }
            let id = CGWindowID(number.uint32Value)
            pendingNativeZoomWindowID = id
            pendingNativeZoomAt = CACurrentMediaTime()
            if !zoomSuspendedWindowIDs.contains(id) {
                // Suspend immediately, before macOS finishes its zoom
                // animation, so the 250 ms layout pass cannot snap it back.
                zoomSuspendedWindowIDs.insert(id)
                zoomSuspendedAt[id] = CACurrentMediaTime()
                animationTimer?.invalidate(); animationTimer = nil
                animations.removeValue(forKey: id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in self?.fillDisplayAfterNativeZoom(id) }
            } else {
                // The second native double-click means restore. Resume the
                // existing Dwindle slot even if an app does not restore its
                // pre-zoom frame consistently.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                    guard let self else { return }
                    self.zoomSuspendedWindowIDs.remove(id)
                    self.zoomSuspendedAt.removeValue(forKey: id)
                    self.pendingNativeZoomWindowID = nil
                    self.forceNextLayout = true
                    self.tileVisibleApplications()
                }
            }
            return
        }
    }

    private func fillDisplayAfterNativeZoom(_ id: CGWindowID) {
        guard enabled, zoomSuspendedWindowIDs.contains(id),
              let window = visibleApplicationWindows().first(where: { $0.id == id }) else { return }
        let available = availableFrame(for: window.screen)
        // Native title-bar zoom varies by application (Safari and Chrome may
        // choose an "ideal" content size). Ryft preserves the native action but
        // normalizes the result to the same safe full-display frame used when
        // a desktop contains one tiled window.
        if frameDifference(window.frame, available) > 3 { setFrame(available, for: window.element, id: id) }
    }

    private func allWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber] as? NSNumber).map { CGWindowID($0.uint32Value) } })
    }

    private func visibleApplicationWindows() -> [ManagedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else { return [] }
        // Keep managing the same window when an application temporarily raises
        // another standard panel or reorders its CG window list.
        let list = rawList.enumerated().sorted { lhs, rhs in
            let lhsID = (lhs.element[kCGWindowNumber] as? NSNumber).map { CGWindowID($0.uint32Value) }
            let rhsID = (rhs.element[kCGWindowNumber] as? NSNumber).map { CGWindowID($0.uint32Value) }
            let lhsKnown = lhsID.map { windowOrder[$0] != nil } ?? false
            let rhsKnown = rhsID.map { windowOrder[$0] != nil } ?? false
            return lhsKnown == rhsKnown ? lhs.offset < rhs.offset : lhsKnown
        }.map(\.element)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [ManagedWindow] = []
        var accessibleByPID: [pid_t: [(element: AXUIElement, frame: CGRect)]] = [:]
        var usedAccessibleIndices: [pid_t: Set<Int>] = [:]

        for info in list {
            guard let pidNumber = info[kCGWindowOwnerPID] as? NSNumber,
                  let layer = info[kCGWindowLayer] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: boundsDictionary),
                  let windowNumber = info[kCGWindowNumber] as? NSNumber else { continue }
            let pid = pidNumber.int32Value
            guard pid != ownPID, layer.intValue == 0, cgFrame.width >= 180, cgFrame.height >= 100 else { continue }
            if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, configuration.excludedBundleIdentifiers.contains(bundleID) { continue }
            let candidates: [(element: AXUIElement, frame: CGRect)]
            if let cached = accessibleByPID[pid] { candidates = cached }
            else {
                let loaded = accessibleWindows(for: pid)
                accessibleByPID[pid] = loaded
                candidates = loaded
            }
            let used = usedAccessibleIndices[pid] ?? []
            guard let matchIndex = candidates.indices.filter({ !used.contains($0) }).min(by: {
                frameDistance(candidates[$0].frame, cgFrame) < frameDistance(candidates[$1].frame, cgFrame)
            }), let screen = screen(containing: cgFrame) else { continue }
            usedAccessibleIndices[pid, default: []].insert(matchIndex)
            let match = candidates[matchIndex]
            result.append(ManagedWindow(id: CGWindowID(windowNumber.uint32Value), pid: pid, element: match.element, frame: match.frame, screen: screen))
        }
        return result
    }

    private func accessibleWindows(for pid: pid_t) -> [(element: AXUIElement, frame: CGRect)] {
        let application = AXUIElementCreateApplication(pid)
        guard let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute as CFString) else { return [] }
        return windows.compactMap { window in
            guard (attribute(window, kAXRoleAttribute as CFString) as String?) == (kAXWindowRole as String),
                  (attribute(window, kAXSubroleAttribute as CFString) as String?) == (kAXStandardWindowSubrole as String),
                  attribute(window, kAXMinimizedAttribute as CFString) as Bool? != true,
                  attribute(window, "AXFullScreen" as CFString) as Bool? != true,
                  isSettable(kAXPositionAttribute as CFString, on: window),
                  isSettable(kAXSizeAttribute as CFString, on: window),
                  let frame = frame(of: window) else { return nil }
            return (window, frame)
        }
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY) + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func isSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute as CFString),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute as CFString) else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }

    private func setFrame(_ target: CGRect, for element: AXUIElement, id: CGWindowID, animated: Bool = true) {
        if animated, let animation = animations[id], frameDifference(animation.to, target) < 1 { return }
        guard let current = frame(of: element), frameDifference(current, target) > 1 else {
            animations.removeValue(forKey: id)
            return
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            animations.removeValue(forKey: id)
            applyFrame(target, to: element)
            return
        }
        animations[id] = FrameAnimation(element: element, from: current, to: target.integral, startedAt: CACurrentMediaTime(), duration: 0.20)
        startAnimationTimerIfNeeded()
    }

    private func startAnimationTimerIfNeeded() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.advanceAnimations() }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func advanceAnimations() {
        let now = CACurrentMediaTime()
        var completed: [CGWindowID] = []
        for (id, animation) in animations {
            let progress = min(1, max(0, (now - animation.startedAt) / animation.duration))
            let eased = 1 - pow(1 - progress, 5) // decisive ease-out-quint
            let frame = interpolate(from: animation.from, to: animation.to, progress: CGFloat(eased))
            applyFrame(frame, to: animation.element)
            if progress >= 1 { completed.append(id) }
        }
        for id in completed { animations.removeValue(forKey: id) }
        if animations.isEmpty { animationTimer?.invalidate(); animationTimer = nil }
    }

    private func interpolate(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * progress,
            y: from.minY + (to.minY - from.minY) * progress,
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress
        )
    }

    private func applyFrame(_ frame: CGRect, to element: AXUIElement) {
        var point = frame.origin; var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // Move before resizing so AppKit does not briefly grow the window from
        // its old top edge. Reasserting position after size handles apps that
        // apply minimum-size constraints without producing a visible jump.
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
    }

    private func frameDifference(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(abs(lhs.minX - rhs.minX), abs(lhs.minY - rhs.minY), abs(lhs.width - rhs.width), abs(lhs.height - rhs.height))
    }

    private func restore(_ windows: [ManagedWindow]) {
        for window in windows {
            guard let original = originalWindows.removeValue(forKey: window.id) else { continue }
            setFrame(original.frame, for: original.element, id: window.id)
        }
    }

    private func restoreManagedWindows(animated: Bool) {
        for (id, original) in originalWindows { setFrame(original.frame, for: original.element, id: id, animated: animated) }
        originalWindows.removeAll()
        windowOrder.removeAll()
    }

    private func order(for id: CGWindowID) -> Int {
        if let order = windowOrder[id] { return order }
        let order = nextOrder; nextOrder += 1; windowOrder[id] = order
        return order
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        // CG can briefly report a visible window just beyond an edge while a
        // Space or application transition settles. Keep it assigned to the
        // nearest display so the next layout frame clamps it safely on-screen.
        NSScreen.screens.max { lhs, rhs in
            screenScore(for: lhs, window: frame) < screenScore(for: rhs, window: frame)
        }
    }

    private func screenScore(for screen: NSScreen, window: CGRect) -> CGFloat {
        let bounds = displayBounds(for: screen)
        let overlap = intersectionArea(window, bounds)
        if overlap > 0 { return 1_000_000_000 + overlap }
        let dx = window.midX - bounds.midX
        let dy = window.midY - bounds.midY
        return -(dx * dx + dy * dy)
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func displayBounds(for screen: NSScreen) -> CGRect {
        CGDisplayBounds(displayID(for: screen))
    }

    private func availableFrame(for screen: NSScreen) -> CGRect {
        let display = displayBounds(for: screen)
        let mainMaxY = CGDisplayBounds(CGMainDisplayID()).maxY
        // A hidden Dock can change visibleFrame whenever the pointer reaches
        // its edge. Auto-hide must not continuously resize every tiled window.
        let dockAutoHides = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        let visible = dockAutoHides ? screen.frame : screen.visibleFrame
        let visibleTop = mainMaxY - visible.maxY
        let visibleBottom = mainMaxY - visible.minY
        var frame = CGRect(
            x: max(display.minX, visible.minX),
            y: max(display.minY, visibleTop),
            width: min(display.maxX, visible.maxX) - max(display.minX, visible.minX),
            height: min(display.maxY, visibleBottom) - max(display.minY, visibleTop)
        )

        let shouldReserveBar = bar.enabled && (bar.showOnAllDisplays || screen == NSScreen.main)
        if shouldReserveBar && bar.position != .top {
            // The native menu bar remains hidden, but Ryft keeps its exact
            // wallpaper strip visible. Windows must begin where that strip ends.
            let coverBottom = display.minY + DisplayLayoutMetrics.menuBarHeight(for: screen)
            let removed = max(0, coverBottom - frame.minY)
            frame.origin.y += removed; frame.size.height -= removed
        }
        if shouldReserveBar {
            let insets = bar.presentation == .top ? 0 : bar.outerInset * 2
            let shelf: CGFloat = bar.position == .top && bar.notchMaskEnabled
                ? (bar.notchMaskHeight > 0 ? bar.notchMaskHeight : ((screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil) ? max(screen.safeAreaInsets.top, 32) : 0))
                : 0
            let reserved = CGFloat(bar.height + insets) + shelf
            switch bar.position {
            case .top:
                let edge = display.minY + reserved
                let removed = max(0, edge - frame.minY)
                frame.origin.y += removed; frame.size.height -= removed
            case .bottom:
                frame.size.height = max(0, min(frame.maxY, display.maxY - reserved) - frame.minY)
            case .left:
                let edge = display.minX + reserved
                let removed = max(0, edge - frame.minX)
                frame.origin.x += removed; frame.size.width -= removed
            case .right:
                frame.size.width = max(0, min(frame.maxX, display.maxX - reserved) - frame.minX)
            }
        }
        let gap = max(0, min(configuration.outerGap, 40))
        return frame.insetBy(dx: gap, dy: gap)
    }

    private func ratios(for key: LayoutKey, count: Int) -> [CGFloat] {
        let needed = max(0, count - 1)
        var values = splitRatios[key] ?? []
        if values.count > needed { values.removeLast(values.count - needed) }
        if values.count < needed { values.append(contentsOf: repeatElement(0.5, count: needed - values.count)) }
        splitRatios[key] = values
        return values
    }

    private func absorbPointerInteraction(
        windows: [ManagedWindow],
        grouped: [CGDirectDisplayID: [ManagedWindow]]
    ) {
        for (display, displayWindows) in grouped {
            let ordered = displayWindows.sorted { order(for: $0.id) < order(for: $1.id) }
            guard ordered.count > 1, let screen = ordered.first?.screen else { continue }
            let available = availableFrame(for: screen)
            let key = LayoutKey(display: display, desktop: activeDesktop)
            var ratios = ratios(for: key, count: ordered.count)
            let layout = dwindleLayout(count: ordered.count, in: available, ratios: ratios)
            guard let changedIndex = ordered.indices.max(by: {
                frameDifference(ordered[$0].frame, layout.frames[$0]) < frameDifference(ordered[$1].frame, layout.frames[$1])
            }), frameDifference(ordered[changedIndex].frame, layout.frames[changedIndex]) > 5 else { continue }

            let actual = ordered[changedIndex].frame
            let expected = layout.frames[changedIndex]
            let movedDistance = hypot(actual.midX - expected.midX, actual.midY - expected.midY)
            let sizeDifference = max(abs(actual.width - expected.width), abs(actual.height - expected.height))

            // A title-bar drag into another slot swaps the two applications.
            // Reordering the stable slot indices means the following layout
            // animates both windows simultaneously rather than chasing them.
            if movedDistance > 24, sizeDifference < 40,
               let destination = layout.frames.indices.first(where: { $0 != changedIndex && layout.frames[$0].contains(CGPoint(x: actual.midX, y: actual.midY)) }) {
                let firstOrder = order(for: ordered[changedIndex].id)
                let secondOrder = order(for: ordered[destination].id)
                windowOrder[ordered[changedIndex].id] = secondOrder
                windowOrder[ordered[destination].id] = firstOrder
                status = "Swapped applications"
                continue
            }

            // An edge drag changes the nearest Dwindle separator. Every window
            // on the opposite side is resized from the same ratio, preserving
            // gaps and preventing overlap even in deeper recursive layouts.
            let gap = CGFloat(max(0, min(configuration.gap, 40)))
            var best: (split: LayoutSplit, boundary: CGFloat, delta: CGFloat)?
            for split in layout.splits where changedIndex >= split.index {
                let oldEdge: CGFloat
                let newEdge: CGFloat
                switch split.axis {
                case .horizontal:
                    if changedIndex == split.index { oldEdge = expected.maxX; newEdge = actual.maxX }
                    else { oldEdge = expected.minX - gap; newEdge = actual.minX - gap }
                case .vertical:
                    if changedIndex == split.index { oldEdge = expected.maxY; newEdge = actual.maxY }
                    else { oldEdge = expected.minY - gap; newEdge = actual.minY - gap }
                }
                guard abs(oldEdge - split.boundary) <= 3 else { continue }
                let delta = abs(newEdge - split.boundary)
                if delta > (best?.delta ?? 5) { best = (split, newEdge, delta) }
            }
            guard let best else { continue }
            let usable: CGFloat
            let consumed: CGFloat
            switch best.split.axis {
            case .horizontal:
                usable = best.split.container.width - gap
                consumed = best.boundary - best.split.container.minX
            case .vertical:
                usable = best.split.container.height - gap
                consumed = best.boundary - best.split.container.minY
            }
            guard usable > 1 else { continue }
            ratios[best.split.index] = min(0.82, max(0.18, consumed / usable))
            splitRatios[key] = ratios
            status = "Adjusted tile split"
        }
    }

    private func dwindleLayout(count: Int, in frame: CGRect, ratios: [CGFloat]) -> (frames: [CGRect], splits: [LayoutSplit]) {
        guard count > 1 else { return ([frame.integral], []) }
        let gap = CGFloat(max(0, min(configuration.gap, 40)))
        var frames: [CGRect] = []
        var splits: [LayoutSplit] = []
        var remainder = frame

        for index in 0..<count {
            let remaining = count - index
            if remaining == 1 {
                frames.append(remainder.integral)
                break
            }
            let ratio = min(0.82, max(0.18, ratios.indices.contains(index) ? ratios[index] : 0.5))
            if remainder.width >= remainder.height {
                let firstWidth = floor((remainder.width - gap) * ratio)
                let first = CGRect(x: remainder.minX, y: remainder.minY, width: firstWidth, height: remainder.height)
                frames.append(first.integral)
                splits.append(LayoutSplit(index: index, axis: .horizontal, container: remainder, boundary: first.maxX))
                remainder = CGRect(x: first.maxX + gap, y: remainder.minY, width: remainder.width - firstWidth - gap, height: remainder.height)
            } else {
                let firstHeight = floor((remainder.height - gap) * ratio)
                let first = CGRect(x: remainder.minX, y: remainder.minY, width: remainder.width, height: firstHeight)
                frames.append(first.integral)
                splits.append(LayoutSplit(index: index, axis: .vertical, container: remainder, boundary: first.maxY))
                remainder = CGRect(x: remainder.minX, y: first.maxY + gap, width: remainder.width, height: remainder.height - firstHeight - gap)
            }
        }
        return (frames, splits)
    }
}
