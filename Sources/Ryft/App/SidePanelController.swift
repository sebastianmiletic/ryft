import AppKit
import SwiftUI
import QuartzCore
import Combine

final class SidePanelController {
    private let model: AppModel
    private var leftPanel: FloatingPanel?
    private var rightPanel: FloatingPanel?
    private var activityMonitor: Any?
    private var outsideClickMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var lockCancellable: AnyCancellable?
    private var inactivityTask: DispatchWorkItem?
    init(model: AppModel) {
        self.model = model
        // Build both trees once at launch. The first click now only positions
        // and animates an existing panel instead of compiling a large SwiftUI tree.
        self.leftPanel = makePanel(side: .left)
        self.rightPanel = makePanel(side: .right)
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if self.rightPanel?.isVisible == true { self.resetControlsInactivityTimer() }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if let panel = self.rightPanel, panel.isVisible, event.window !== panel { self.dismiss(panel, side: .right) }
                if let panel = self.leftPanel, panel.isVisible, event.window !== panel, !self.model.assistantPanelLocked { self.dismiss(panel, side: .left) }
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if let panel = self.rightPanel, panel.isVisible { self.dismiss(panel, side: .right) }
            if let panel = self.leftPanel, panel.isVisible, !self.model.assistantPanelLocked { self.dismiss(panel, side: .left) }
        }
        lockCancellable = model.$assistantPanelLocked.removeDuplicates().sink { [weak self] locked in
            guard locked, let self, let panel = self.leftPanel else { return }
            self.attachToEveryDesktop(panel)
            panel.orderFrontRegardless()
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.model.assistantPanelLocked, let panel = self.leftPanel else { return }
            // A locked assistant is a stationary shell surface. Reassert its
            // frame and ordering on every Space transition so Mission Control
            // can never strand it on the outgoing desktop.
            panel.setFrame(self.targetFrame(side: .left), display: true)
            self.attachToEveryDesktop(panel)
            panel.orderFrontRegardless()
            for delay in [0.03, 0.12, 0.28] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard self.model.assistantPanelLocked else { return }
                    panel.orderFrontRegardless()
                }
            }
        }
    }

    deinit {
        inactivityTask?.cancel()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }

    func toggleLeft() {
        if let rightPanel, rightPanel.isVisible { dismiss(rightPanel, side: .right) }
        if let leftPanel, leftPanel.isVisible {
            if !model.assistantPanelLocked { dismiss(leftPanel, side: .left) }
            return
        }
        let panel = leftPanel ?? makePanel(side: .left)
        leftPanel = panel; present(panel, side: .left)
    }
    func toggleRight(detail: String = "") {
        if let leftPanel, leftPanel.isVisible, !model.assistantPanelLocked { dismiss(leftPanel, side: .left) }
        if let rightPanel, rightPanel.isVisible && model.rightSidebarDetail == detail { dismiss(rightPanel, side: .right); return }
        model.rightSidebarDetail = detail
        switch detail { case "Wi-Fi": model.controls.prepareWiFiMenu(); case "Sound": model.controls.prepareSoundMenu(); case "Battery": model.controls.operationMessage = ""; model.controls.refreshPowerState(); default: model.controls.operationMessage = ""; model.controls.refreshAll() }
        let panel = rightPanel ?? makePanel(side: .right)
        rightPanel = panel; present(panel, side: .right)
    }

    private func resetControlsInactivityTimer() {
        inactivityTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, let rightPanel = self.rightPanel, rightPanel.isVisible else { return }
            self.dismiss(rightPanel, side: .right)
        }
        inactivityTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: task)
    }

    private func attachToEveryDesktop(_ panel: NSPanel) {
        typealias MainConnection = @convention(c) () -> UInt32
        typealias CopySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
        typealias AddWindows = @convention(c) (UInt32, CFArray, CFArray) -> Void
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let mainSymbol = dlsym(library, "CGSMainConnectionID"),
              let copySymbol = dlsym(library, "CGSCopyManagedDisplaySpaces"),
              let addSymbol = dlsym(library, "SLSAddWindowsToSpaces") else { return }
        defer { dlclose(library) }
        let main = unsafeBitCast(mainSymbol, to: MainConnection.self)
        let copy = unsafeBitCast(copySymbol, to: CopySpaces.self)
        let add = unsafeBitCast(addSymbol, to: AddWindows.self)
        let connection = main()
        guard let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return }
        let ids = displays.flatMap { ($0["Spaces"] as? [[String: Any]] ?? []) }
            .filter { ($0["type"] as? NSNumber)?.intValue == 0 }
            .compactMap { ($0["ManagedSpaceID"] as? NSNumber).map { NSNumber(value: $0.uint64Value) } }
        guard !ids.isEmpty else { return }
        add(connection, [NSNumber(value: panel.windowNumber)] as CFArray, ids as CFArray)
    }

    private enum Side { case left, right }
    private func makePanel(side: Side) -> FloatingPanel {
        let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true; panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]; panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self, weak panel] in if let self, let panel { self.dismiss(panel, side: side) } }
        let close = { [weak self, weak panel] in if let self, let panel { self.dismiss(panel, side: side) } }
        panel.contentView = NSHostingView(rootView: side == .left ? AnyView(LeftSidebarView(model: model, close: close)) : AnyView(RightSidebarView(model: model, close: close)))
        return panel
    }
    private func targetFrame(side: Side) -> NSRect {
        guard let screen = NSScreen.main else { return .zero }
        var usable = screen.visibleFrame
        let margin: CGFloat = 7
        let bar = model.configuration.bar
        if bar.enabled && bar.position != .top {
            let coverBottom = screen.frame.maxY - DisplayLayoutMetrics.menuBarHeight(for: screen)
            usable.size.height = max(0, min(usable.maxY, coverBottom) - usable.minY)
        }
        if bar.enabled {
            let frame = DisplayLayoutMetrics.barFrame(for: screen, bar: bar)
            let thickness = bar.position.isVertical ? frame.width : frame.height
            let reserved = (bar.position == .top ? max(thickness, DisplayLayoutMetrics.menuBarCoverFrame(for: screen, bar: bar).height) : thickness) + 6
            switch bar.position {
            case .top: usable.size.height = max(0, min(usable.maxY, screen.frame.maxY - reserved) - usable.minY)
            case .bottom:
                let edge = screen.frame.minY + reserved; let removed = max(0, edge - usable.minY)
                usable.origin.y += removed; usable.size.height -= removed
            case .left:
                let edge = screen.frame.minX + reserved; let removed = max(0, edge - usable.minX)
                usable.origin.x += removed; usable.size.width -= removed
            case .right: usable.size.width = max(0, min(usable.maxX, screen.frame.maxX - reserved) - usable.minX)
            }
        }
        let width = min(CGFloat(420), max(320, usable.width - margin * 2))
        let x = side == .left ? usable.minX + margin : usable.maxX - width - margin
        return NSRect(x: x, y: usable.minY + margin, width: width, height: max(320, usable.height - margin * 2))
    }
    private func present(_ panel: FloatingPanel, side: Side) {
        let target = targetFrame(side: side)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transitionID = UUID(); panel.transitionID = transitionID
        panel.setFrame(target, display: true)
        panel.contentView?.wantsLayer = true
        guard let layer = panel.contentView?.layer else { panel.makeKeyAndOrderFront(nil); return }
        layer.removeAllAnimations()
        let startTransform = CATransform3DMakeTranslation(side == .left ? -24 : 24, 0, 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = reduced ? CATransform3DIdentity : startTransform
        layer.opacity = reduced ? 1 : 0
        CATransaction.commit()
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
        if side == .right { resetControlsInactivityTimer() } else { inactivityTask?.cancel() }
        guard !reduced, panel.transitionID == transitionID else { return }
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        let movement = CABasicAnimation(keyPath: "transform")
        movement.fromValue = NSValue(caTransform3D: startTransform); movement.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        movement.duration = 0.24; movement.timingFunction = timing
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.18; fade.timingFunction = timing
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity; layer.opacity = 1
        CATransaction.commit()
        layer.add(movement, forKey: "ryft.panel.open.transform"); layer.add(fade, forKey: "ryft.panel.open.opacity")
    }
    private func dismiss(_ panel: FloatingPanel, side: Side) {
        guard panel.isVisible else { return }
        inactivityTask?.cancel()
        let transitionID = UUID(); panel.transitionID = transitionID
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = panel.contentView?.layer else { panel.orderOut(nil); return }
        let currentTransform = layer.presentation()?.transform ?? layer.transform
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAllAnimations()
        let endTransform = CATransform3DMakeTranslation(side == .left ? -18 : 18, 0, 0)
        let timing = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1)
        let movement = CABasicAnimation(keyPath: "transform")
        movement.fromValue = NSValue(caTransform3D: currentTransform); movement.toValue = NSValue(caTransform3D: endTransform)
        movement.duration = 0.17; movement.timingFunction = timing
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity; fade.toValue = 0; fade.duration = 0.15; fade.timingFunction = timing
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = endTransform; layer.opacity = 0
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            guard panel.transitionID == transitionID else { return }
            panel.orderOut(nil); layer.removeAllAnimations()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity; layer.opacity = 1
            CATransaction.commit()
        }
        layer.add(movement, forKey: "ryft.panel.close.transform"); layer.add(fade, forKey: "ryft.panel.close.opacity")
        CATransaction.commit()
    }
}

final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    var transitionID = UUID()
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
