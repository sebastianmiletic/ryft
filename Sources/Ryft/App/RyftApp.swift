import SwiftUI
import Combine
import QuartzCore

@main
struct RyftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Ryft") { SettingsView(model: model) }
            .defaultSize(width: 930, height: 640)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Toggle Desktop Bar") { model.configuration.bar.enabled.toggle() }.keyboardShortcut("b", modifiers: [.option])
                }
                CommandGroup(replacing: .newItem) { }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var barController: BarPanelController?
    private var wallpaperController: WallpaperWindowController?
    private var sidePanelController: SidePanelController?
    private var cursorTheme: CursorThemeService?
    private var hotkeys: GlobalHotkeyManager?
    private var cancellable: AnyCancellable?
    private var cursorCancellable: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var settingsAnimationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel.shared
        // Measure before hiding Apple's menu. Thin bars and secondary displays
        // still need the real native boundary, not a post-hide zero inset.
        NSScreen.screens.forEach { _ = DisplayLayoutMetrics.menuBarHeight(for: $0) }
        // Hide Apple's menu surface before creating any Ryft panels.
        NSMenu.setMenuBarVisible(false)
        _ = model.notifications
        barController = BarPanelController(model: model)
        wallpaperController = WallpaperWindowController(model: model)
        sidePanelController = SidePanelController(model: model)
        let cursorTheme = CursorThemeService.shared; cursorTheme.setEnabled(model.configuration.useHyprlandCursor); self.cursorTheme = cursorTheme
        cursorCancellable = model.$configuration.map(\.useHyprlandCursor).removeDuplicates().dropFirst().sink { [weak cursorTheme] in cursorTheme?.setEnabled($0) }
        let manager = GlobalHotkeyManager()
        manager.onShortcut = { [weak self] shortcut in self?.perform(shortcut) }
        manager.onWorkspace = { number in model.workspaces.switchTo(number) { model.statusMessage = $0 } }
        if TermaticaIntegrationService.isInstalled { TermaticaIntegrationService.stopLegacyCommandLauncher() }
        manager.register(model.configuration.shortcuts, termaticaEnabled: model.configuration.termaticaShortcutEnabled)
        hotkeys = manager
        cancellable = model.$configuration
            .removeDuplicates { lhs, rhs in lhs.shortcuts == rhs.shortcuts && lhs.termaticaShortcutEnabled == rhs.termaticaShortcutEnabled }
            .dropFirst()
            .sink { [weak manager] configuration in
                let enabled = configuration.termaticaShortcutEnabled
                if TermaticaIntegrationService.isInstalled { TermaticaIntegrationService.stopLegacyCommandLauncher() }
                manager?.register(configuration.shortcuts, termaticaEnabled: enabled)
            }
        observers.append(NotificationCenter.default.addObserver(forName: .ryftShowWallpapers, object: nil, queue: .main) { [weak self] _ in self?.showWallpaperGallery() })
        observers.append(NotificationCenter.default.addObserver(forName: .ryftShowSettings, object: nil, queue: .main) { [weak self] _ in self?.showSettings() })
        observers.append(NotificationCenter.default.addObserver(forName: .ryftToggleLeftSidebar, object: nil, queue: .main) { [weak self] _ in self?.sidePanelController?.toggleLeft() })
        observers.append(NotificationCenter.default.addObserver(forName: .ryftToggleRightSidebar, object: nil, queue: .main) { [weak self] note in self?.sidePanelController?.toggleRight(detail: note.object as? String ?? "") })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in NSMenu.setMenuBarVisible(false) })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            NSMenu.setMenuBarVisible(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSMenu.setMenuBarVisible(false)
                self?.hideSettingsAfterSpaceChange()
            }
        })
        installStatusItem()
        NSMenu.setMenuBarVisible(false)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.captureSettingsWindow()
            if !model.configuration.hasCompletedOnboarding {
                model.selectedSection = .general
                if self.settingsWindow?.isVisible != true { self.showSettings() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillResignActive(_ notification: Notification) { AppModel.shared.save() }
    func applicationWillTerminate(_ notification: Notification) { cursorTheme?.setEnabled(false); AppModel.shared.tiling.shutdown(); NSMenu.setMenuBarVisible(true); AppModel.shared.save() }
    func showWallpaperGallery() { wallpaperController?.show() }
    func showSettings() {
        captureSettingsWindow()
        guard let settingsWindow, !settingsAnimationInProgress else { return }
        if settingsWindow.isVisible { hideSettings(); return }
        if AppModel.shared.configuration.hasCompletedOnboarding { AppModel.shared.selectedSection = .home }
        else { AppModel.shared.selectedSection = .general }
        NSApp.activate(ignoringOtherApps: true)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            settingsWindow.alphaValue = 1; settingsWindow.makeKeyAndOrderFront(nil); settingsWindow.orderFrontRegardless()
            return
        }
        settingsAnimationInProgress = true
        settingsWindow.contentView?.wantsLayer = true
        let layer = settingsWindow.contentView?.layer
        let startTransform = CATransform3DConcat(CATransform3DMakeScale(0.992, 0.992, 1), CATransform3DMakeTranslation(0, -7, 0))
        layer?.transform = CATransform3DIdentity
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: startTransform); transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        transform.duration = 0.22; transform.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        layer?.add(transform, forKey: "ryft.settings.open")
        settingsWindow.alphaValue = 0
        settingsWindow.makeKeyAndOrderFront(nil); settingsWindow.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2; context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            settingsWindow.animator().alphaValue = 1
        } completionHandler: { [weak self] in self?.settingsAnimationInProgress = false }
    }

    private func captureSettingsWindow() {
        if settingsWindow == nil {
            settingsWindow = NSApp.windows.first(where: { !($0 is NSPanel) && $0.title != "Wallpaper gallery" }) ?? NSApp.windows.first(where: { $0.title == "Ryft" })
        }
        guard let settingsWindow else { return }
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.level = .floating
        settingsWindow.hidesOnDeactivate = false
        settingsWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let compactFrameKey = "RyftAppliedCompactSettingsFrame"
        if !UserDefaults.standard.bool(forKey: compactFrameKey) {
            settingsWindow.setContentSize(NSSize(width: 930, height: 640)); settingsWindow.center()
            UserDefaults.standard.set(true, forKey: compactFrameKey)
        }
        settingsWindow.isOpaque = false
        settingsWindow.backgroundColor = .clear
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.titleVisibility = .hidden
        settingsWindow.standardWindowButton(.closeButton)?.target = self
        settingsWindow.standardWindowButton(.closeButton)?.action = #selector(closeSettingsWindow)
    }

    @objc private func closeSettingsWindow() { hideSettings() }
    private func hideSettingsAfterSpaceChange() {
        guard settingsWindow?.isVisible == true else { return }
        if settingsAnimationInProgress {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.hideSettingsAfterSpaceChange() }
        } else { hideSettings() }
    }
    private func hideSettings() {
        guard let settingsWindow, settingsWindow.isVisible, !settingsAnimationInProgress else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { settingsWindow.orderOut(nil); return }
        settingsAnimationInProgress = true
        settingsWindow.contentView?.wantsLayer = true
        let layer = settingsWindow.contentView?.layer
        let endTransform = CATransform3DConcat(CATransform3DMakeScale(0.994, 0.994, 1), CATransform3DMakeTranslation(0, -5, 0))
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: CATransform3DIdentity); transform.toValue = NSValue(caTransform3D: endTransform)
        transform.duration = 0.15; transform.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1)
        layer?.add(transform, forKey: "ryft.settings.close")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15; context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            settingsWindow.animator().alphaValue = 0
        } completionHandler: { [weak self, weak settingsWindow] in
            settingsWindow?.orderOut(nil); settingsWindow?.alphaValue = 1
            settingsWindow?.contentView?.layer?.removeAllAnimations()
            self?.settingsAnimationInProgress = false
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Ryft")
            button.image?.isTemplate = true
            button.toolTip = "Ryft"
        }
        let menu = NSMenu()
        menu.addItem(menuItem("Open Ryft Settings", action: #selector(openSettingsFromMenu)))
        menu.addItem(menuItem("Open Tools Sidebar", action: #selector(leftSidebarFromMenu)))
        menu.addItem(menuItem("Open Control Center", action: #selector(rightSidebarFromMenu)))
        menu.addItem(menuItem("Toggle Desktop Bar", action: #selector(toggleBarFromMenu)))
        menu.addItem(menuItem("Enable System-wide Shortcuts…", action: #selector(openInputMonitoringFromMenu)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Ryft", action: #selector(quitFromMenu)))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; return item
    }
    @objc private func openSettingsFromMenu() { showSettings() }
    @objc private func leftSidebarFromMenu() { sidePanelController?.toggleLeft() }
    @objc private func rightSidebarFromMenu() { sidePanelController?.toggleRight() }
    @objc private func toggleBarFromMenu() { AppModel.shared.configuration.bar.enabled.toggle() }
    @objc private func openInputMonitoringFromMenu() { WorkspaceController.openPrivacyPane("Privacy_ListenEvent") }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    func perform(_ shortcut: ShortcutConfiguration) {
        let model = AppModel.shared
        switch shortcut.action {
        case .wallpaper: showWallpaperGallery()
        case .toggleBar: model.configuration.bar.enabled.toggle()
        case .settings: showSettings()
        case .randomWallpaper: model.randomWallpaper()
        case .openFinder:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: .init())
        case .openApplication:
            if let path = shortcut.target, !path.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        case .runCommand:
            guard let command = shortcut.target, !command.isEmpty else { return }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-lc", command]
            try? process.run()
        case .leftSidebar: sidePanelController?.toggleLeft()
        case .rightSidebar: sidePanelController?.toggleRight()
        case .screenAnswer: model.answerQuestionOnScreen()
        case .termatica: TermaticaIntegrationService.openOrControl()
        case .quitFrontmost:
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { NSApp.terminate(nil) }
            else { _ = app.terminate() }
        }
    }
}
