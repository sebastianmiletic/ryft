import SwiftUI
import UniformTypeIdentifiers
import Darwin

private final class SettingsHoverState: ObservableObject { @Published var hovered = false }
private extension View {
    @ViewBuilder func hidingSystemSidebarToggle() -> some View {
        if #available(macOS 14.0, *) { self.toolbar(removing: .sidebarToggle) }
        else { self }
    }
}

struct SettingsHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body { Body(configuration: configuration) }
    struct Body: View {
        let configuration: ButtonStyleConfiguration
        @StateObject private var state = SettingsHoverState()
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.985 : (state.hovered ? 1.012 : 1))
                .opacity(configuration.isPressed ? 0.82 : 1)
                .animation(.easeOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14), value: state.hovered)
                .animation(.easeOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1), value: configuration.isPressed)
                .onHover { state.hovered = $0 }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var notifications: NotificationDaemon
    @ObservedObject private var permissions: RyftPermissionMonitor
    init(model: AppModel) {
        self.model = model
        notifications = model.notifications
        permissions = model.permissions
    }

    private var missingPermissionCount: Int {
        permissions.missingCount(notificationStatus: notifications.authorizationStatus)
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 5) {
                Button { model.selectedSection = .home } label: {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 40, height: 40)
                        .padding(3)
                        .background(model.selectedSection == .home ? Color(hex: model.configuration.bar.palette.accent).opacity(0.14) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(SettingsHoverButtonStyle())
                .help("Open desktop overview")
                .accessibilityLabel("Ryft overview")
                .padding(.horizontal, 7).padding(.bottom, 7)
                ForEach(AppSection.allCases.filter { section in
                    section != .home && section != .permissions && section != .guide
                }) { section in
                    Button { model.selectedSection = section } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbol).frame(width: 18)
                            Text(section.rawValue)
                            Spacer()
                            if section == .general && missingPermissionCount > 0 {
                                Circle().fill(Color.red).frame(width: 7, height: 7)
                                    .help("\(missingPermissionCount) permissions need attention")
                                    .accessibilityLabel("Permissions need attention")
                                    .accessibilityValue("\(missingPermissionCount) missing")
                            }
                        }
                            .padding(.horizontal, 11).frame(height: 36)
                            .background(model.selectedSection == section ? Color(hex: model.configuration.bar.palette.accent).opacity(0.18) : .clear)
                            .foregroundStyle(model.selectedSection == section ? Color.primary : Color.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }.buttonStyle(SettingsHoverButtonStyle())
                }
                Spacer()
                HStack { Circle().fill(Color(hex: model.configuration.bar.palette.success)).frame(width: 7, height: 7); Text(model.statusMessage).lineLimit(1); Spacer() }
                    .font(.caption).foregroundStyle(.secondary).padding(10).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 9))
            }.padding(10).frame(minWidth: 174).background(.ultraThinMaterial)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        PageHeader(section: model.selectedSection)
                        page
                    }
                    .padding(22)
                    .frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }.background(Color.primary.opacity(0.018))
        }
        .hidingSystemSidebarToggle()
        .background(.regularMaterial)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { notifications.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifications.refreshAuthorization()
        }
    }

    @ViewBuilder private var page: some View {
        switch model.selectedSection {
        case .home: HomeSettingsView(model: model)
        case .permissions: PermissionsSettingsView(model: model)
        case .guide: QuickStartSettingsView(model: model)
        case .waybar: WaybarSettingsView(model: model)
        case .tiling: TilingSettingsView(model: model)
        case .assistant: AssistantSettingsView(model: model)
        case .shortcuts: ShortcutSettingsView(model: model)
        case .wallpapers: WallpaperGalleryView(model: model, standalone: false)
        case .general: GeneralSettingsView(model: model)
        }
    }
}

private struct PageHeader: View {
    let section: AppSection
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(section.rawValue).font(.system(size: 27, weight: .bold, design: .rounded))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
    private var subtitle: String {
        switch section {
        case .home: "Your desktop, wallpaper, and Mac at a glance."
        case .permissions: "Control exactly which macOS features Ryft can access."
        case .guide: "The essential controls, shortcuts, and everyday workflow."
        case .waybar: "Configure the bar, themes, geometry, and widgets in one place."
        case .tiling: "Automatically size and position windows with balanced or optional Dwindle layouts."
        case .assistant: "Configure Gemini, selected-text answers, model routing, and privacy."
        case .shortcuts: "Map global controls that work from any app."
        case .wallpapers: "Pick an image for every connected display."
        case .general: "Profiles, permissions, and startup behavior."
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.7)
            content
        }.padding(16).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.075)))
    }
}

struct TilingSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var engine: DwindleTilingService
    @ObservedObject private var permissions: RyftPermissionMonitor

    init(model: AppModel) {
        self.model = model
        engine = model.tiling
        permissions = model.permissions
    }

    private var statusColor: Color {
        if !permissions.accessibilityGranted { return .red }
        if engine.managedApplicationCount >= 1 { return Color(hex: model.configuration.bar.palette.success) }
        return Color(hex: model.configuration.bar.palette.accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Automatic window layout") {
                Toggle("Size and position windows automatically", isOn: $model.configuration.tiling.enabled)
                    .toggleStyle(.switch)
                Picker("Layout behavior", selection: $model.configuration.tiling.mode) {
                    ForEach(TilingLayoutMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented)
                Text(model.configuration.tiling.mode.description)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Circle().fill(model.configuration.tiling.enabled ? statusColor : Color.secondary.opacity(0.45)).frame(width: 8, height: 8)
                    Text(engine.status).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.configuration.tiling.enabled && !permissions.accessibilityGranted {
                        Button("Review Accessibility") { engine.openAccessibilitySettings() }.buttonStyle(.bordered)
                    }
                }
                Text("Both modes are built directly into Ryft. Sizing & positioning provides automatic balanced placement without Hyprland behavior; Dwindle remains available as an optional advanced layout.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup("Layout tuning") {
                ValueSlider("Window gap", value: $model.configuration.tiling.gap, range: 0...32, suffix: "pt")
                ValueSlider("Display edge gap", value: $model.configuration.tiling.outerGap, range: 0...32, suffix: "pt")
            }
            SettingsGroup("Application exceptions") {
                if model.configuration.tiling.excludedBundleIdentifiers.isEmpty {
                    Text("Every resizable application can be tiled.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.configuration.tiling.excludedBundleIdentifiers, id: \.self) { identifier in
                        HStack {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().frame(width: 24, height: 24); Text(url.deletingPathExtension().lastPathComponent) }
                            else { Image(systemName: "app"); Text(identifier) }
                            Spacer(); Button { model.configuration.tiling.excludedBundleIdentifiers.removeAll { $0 == identifier } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(SettingsHoverButtonStyle())
                        }
                    }
                }
                Button { addException() } label: { Label("Add application exception", systemImage: "plus") }.buttonStyle(SettingsHoverButtonStyle())
                Text("Excluded apps keep their own position and size and do not occupy an automatic layout slot.").font(.caption).foregroundStyle(.secondary)
            }
            SettingsGroup("When Ryft rearranges windows") {
                Label("One visible window fills the complete safe work area.", systemImage: "rectangle")
                Label("A second window creates equal halves, even when both belong to the same application.", systemImage: "rectangle.split.2x1")
                if model.configuration.tiling.mode == .placementOnly {
                    Label("Additional windows form balanced rows and columns.", systemImage: "rectangle.grid.2x2")
                    Label("Ryft controls only automatic size and position—recursive splits, pane ratios, and slot swapping are off.", systemImage: "move.3d")
                } else {
                    Label("A third window splits the right pane; later windows recursively split the remainder.", systemImage: "rectangle.split.2x2")
                    Label("Drag a tiled edge to resize neighboring panes, or drag a title bar into another pane to swap them.", systemImage: "arrow.triangle.swap")
                }
                Label("The bar, Dock, display edges, fullscreen, minimized, and fixed-size windows stay clear.", systemImage: "arrow.down.right.and.arrow.up.left")
                Label("Closing back to one application restores its original frame.", systemImage: "arrow.uturn.backward")
                Text("Ryft manages every resizable standard window visible on each display of the active Mission Control desktop, including multiple windows from one application. Changing the bar edge or size immediately reflows all windows so none overlap the bar, Dock, or display boundary. Turn automatic layout off to restore original frames.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { permissions.refresh(); engine.refresh() }
    }

    private func addException() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let identifier = Bundle(url: url)?.bundleIdentifier, !model.configuration.tiling.excludedBundleIdentifiers.contains(identifier) else { continue }
            model.configuration.tiling.excludedBundleIdentifiers.append(identifier)
        }
    }
}

struct HomeSettingsView: View {
    @ObservedObject var model: AppModel
    private var palette: ThemePalette { model.configuration.bar.palette }
    private var wallpaperName: String { URL(fileURLWithPath: model.configuration.currentWallpaper).deletingPathExtension().lastPathComponent }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { model.selectedSection = .wallpapers } label: {
                ZStack(alignment: .bottomLeading) {
                    if let image = NSImage(contentsOfFile: model.configuration.currentWallpaper) { Image(nsImage: image).resizable().scaledToFill() }
                    else { Color(hex: palette.surface) }
                    LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("WALLPAPER").font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(.white.opacity(0.68))
                            Text(wallpaperName.isEmpty ? "Desktop" : wallpaperName).font(.title3.weight(.semibold)).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).padding(8).background(.black.opacity(0.35)).clipShape(Circle())
                    }.foregroundStyle(.white).padding(16)
                }
                .frame(height: 210).clipped().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }.buttonStyle(SettingsHoverButtonStyle()).help("Open wallpaper library")

            Text("THIS MAC").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8).padding(.top, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                spec("Model", DeviceDetails.model, "laptopcomputer")
                spec("macOS", ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: ""), "apple.logo")
                spec("Memory", ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory), "memorychip")
                spec("Processor", "\(ProcessInfo.processInfo.processorCount) cores", "cpu")
                spec("Display", DeviceDetails.display, "display")
                spec("Uptime", model.system.uptime, "clock.arrow.circlepath")
            }
        }
    }
    private func spec(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Image(systemName: icon).foregroundStyle(Color(hex: palette.accent)); Spacer(); Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
            Text(value).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).frame(minHeight: 76).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private enum DeviceDetails {
    static var model: String { sysctlString("hw.model") ?? Host.current().localizedName ?? "Mac" }
    static var display: String { guard let screen = NSScreen.main else { return "Unknown" }; return "\(Int(screen.frame.width)) × \(Int(screen.frame.height))" }
    private static func sysctlString(_ name: String) -> String? {
        var size = 0; guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size); guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}

private struct CurrentBarInspector: View {
    @ObservedObject var model: AppModel
    private var bar: BarConfiguration { model.configuration.bar }
    private var screenWidth: CGFloat { NSScreen.main?.frame.width ?? 1440 }
    private var notchWidth: CGFloat {
        guard (bar.reserveNotchSpace || bar.splitAroundNotch), !bar.notchMaskEnabled, let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return bar.manualNotchWidth }
        return bar.manualNotchWidth > 0 ? CGFloat(bar.manualNotchWidth) : max(0, right.minX - left.maxX)
    }
    private var shelfHeight: CGFloat { bar.notchMaskEnabled ? (bar.notchMaskHeight > 0 ? CGFloat(bar.notchMaskHeight) : max(NSScreen.main?.safeAreaInsets.top ?? 0, 32)) : 0 }
    private var barInsets: CGFloat { bar.presentation == .top ? 0 : bar.outerInset * 2 }
    private var previewWidth: CGFloat { bar.position.isVertical ? bar.height + barInsets : screenWidth }
    private var previewHeight: CGFloat { bar.position.isVertical ? min(NSScreen.main?.frame.height ?? 900, 520) : bar.height + barInsets + shelfHeight }
    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            BarView(model: model, notchWidth: notchWidth, topReservedHeight: bar.position == .top ? shelfHeight : 0)
                .frame(width: previewWidth, height: previewHeight)
                .allowsHitTesting(false)
                .frame(maxWidth: bar.position.isVertical ? .infinity : nil, alignment: bar.position == .right ? .trailing : .leading)
        }
        .frame(height: bar.position.isVertical ? 300 : previewHeight + 12)
        .background(Color(hex: "#202124"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
    }
}

private struct BarStylePreview: View {
    @ObservedObject var model: AppModel
    let style: BuiltInBarStyle
    private var preview: BarConfiguration {
        var value = model.barConfiguration(for: style)
        value.position = .top
        return value
    }
    var body: some View {
        Button { model.applyBarStyle(style) } label: {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { proxy in
                    let sourceWidth: CGFloat = 1280
                    let scale = min(1, (proxy.size.width - 16) / sourceWidth)
                    ZStack {
                        LinearGradient(colors: [Color(hex: preview.palette.muted).opacity(0.3), Color(hex: preview.palette.background).opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        BarView(model: model, notchWidth: (preview.reserveNotchSpace || preview.splitAroundNotch) ? 160 : 0, topReservedHeight: 0, configurationOverride: preview)
                            .frame(width: sourceWidth, height: preview.height + (preview.presentation == .top ? 0 : preview.outerInset * 2))
                            .scaleEffect(scale, anchor: .center)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            .allowsHitTesting(false)
                    }.clipped()
                }
                .frame(height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(style.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                Text(style.subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(Color.primary.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09)))
        }.buttonStyle(SettingsHoverButtonStyle()).help("Apply \(style.rawValue)")
    }
}

struct WaybarSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        BarSettingsView(model: model)
        ThemeSettingsView(model: model)
        ModuleSettingsView(model: model)
    }
}

struct BarSettingsView: View {
    @ObservedObject var model: AppModel
    private var placementDescription: String {
        let edge: String
        switch model.configuration.bar.presentation {
        case .floating: edge = "Floating leaves breathing room around the bar."
        case .edges: edge = "Full width spans the display while keeping a gap from the selected edge."
        case .top: edge = "Flush removes all outer gaps and attaches directly to the display edge."
        }
        return "\(model.configuration.bar.position.rawValue) edge. \(edge) Tiled windows automatically use the remaining work area."
    }
    var body: some View {
        SettingsGroup("Style library") {
            LazyVStack(spacing: 12) {
                ForEach(BuiltInBarStyle.allCases) { style in BarStylePreview(model: model, style: style) }
            }
            Divider()
            HStack {
                TextField("Profile name", text: $model.barProfileName).frame(maxWidth: 180)
                Button("Save current bar") { model.saveBarProfile() }.buttonStyle(.borderedProminent)
                if !model.configuration.savedBars.isEmpty {
                    Menu("Saved bars") {
                        ForEach(model.configuration.savedBars) { profile in Button(profile.name) { model.applyBarProfile(profile) } }
                        Divider(); Button("Remove all saved bars", role: .destructive) { model.configuration.savedBars.removeAll() }
                    }
                }
            }
            Label("Every change is saved automatically", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color(hex: model.configuration.bar.palette.success))
            Text("Preview a style before applying it. Saved named bars preserve every color, icon, widget, transparency, blur, and position.").font(.caption).foregroundStyle(.secondary)
        }
        HStack(alignment: .top, spacing: 16) {
            SettingsGroup("Placement") {
                Toggle("Show desktop bar", isOn: $model.configuration.bar.enabled)
                Picker("Display edge", selection: $model.configuration.bar.position) { ForEach(BarPosition.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Picker("Bar fit", selection: $model.configuration.bar.presentation) { ForEach(BarPresentation.allCases) { Text($0.settingsLabel).tag($0) } }.pickerStyle(.segmented)
                Text(placementDescription).font(.caption).foregroundStyle(.secondary)
                Toggle("Show on every display", isOn: $model.configuration.bar.showOnAllDisplays)
                if model.configuration.bar.position == .top {
                    Toggle("Black notch shelf", isOn: Binding(get: { model.configuration.bar.notchMaskEnabled }, set: { enabled in
                        model.configuration.bar.notchMaskEnabled = enabled
                        if enabled { model.configuration.bar.presentation = .top; model.configuration.bar.reserveNotchSpace = false }
                    }))
                    if model.configuration.bar.notchMaskEnabled {
                        ValueSlider("Shelf height override", value: $model.configuration.bar.notchMaskHeight, range: 0...60, suffix: "pt")
                        Text(model.configuration.bar.notchMaskHeight == 0 ? "Uses the MacBook safe-area height automatically. The shelf is a full-width, square-edged RGB 0,0,0 mask and the bar begins below it." : "The true-black shelf uses the chosen height and the bar begins immediately below it.").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Widgets avoid notch", isOn: $model.configuration.bar.reserveNotchSpace).disabled(model.configuration.bar.notchMaskEnabled)
                    Toggle("Bar avoids notch", isOn: $model.configuration.bar.splitAroundNotch).disabled(model.configuration.bar.notchMaskEnabled)
                    if (model.configuration.bar.reserveNotchSpace || model.configuration.bar.splitAroundNotch) && !model.configuration.bar.notchMaskEnabled {
                        ValueSlider("Notch width override", value: $model.configuration.bar.manualNotchWidth, range: 0...260, suffix: "pt")
                        Text(model.configuration.bar.splitAroundNotch ? "The complete bar splits around the camera area, including its surface and widgets." : "Only widgets move clear of the camera area; the bar surface remains continuous.").font(.caption).foregroundStyle(.secondary)
                        Text(model.configuration.bar.manualNotchWidth == 0 ? "Auto detects each display. Style previews show the spacing without drawing a notch." : "Manual width replaces safe-area detection on every display.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("The macOS menu bar remains hidden and wallpaper-covered at the top.", systemImage: "menubar.rectangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Toggle("Round bottom display corners", isOn: $model.configuration.bar.roundBottomDisplayCorners)
                if model.configuration.bar.roundBottomDisplayCorners {
                    ValueSlider("Display corner radius", value: $model.configuration.bar.displayCornerRadius, range: 6...48, suffix: "pt")
                    Text("Adds true-black masks to the lower-left and lower-right corners on each active display.").font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsGroup("Geometry") {
                ValueSlider(model.configuration.bar.position.isVertical ? "Width" : "Height", value: $model.configuration.bar.height, range: 28...64, suffix: "pt")
                ValueSlider("Corner radius", value: $model.configuration.bar.cornerRadius, range: 0...30, suffix: "pt")
                ValueSlider("Edge inset", value: $model.configuration.bar.horizontalInset, range: 0...30, suffix: "pt")
                ValueSlider("Widget spacing", value: $model.configuration.bar.itemSpacing, range: 0...18, suffix: "pt")
                Toggle("Bar background", isOn: $model.configuration.bar.showBackground)
                Toggle("Blur", isOn: $model.configuration.bar.blurEnabled).disabled(!model.configuration.bar.showBackground)
                if model.configuration.bar.blurEnabled {
                    Picker("Blur material", selection: $model.configuration.bar.blurStyle) { ForEach(BarBlurStyle.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                }
                ValueSlider("Transparency", value: Binding(get: { 1 - model.configuration.bar.opacity }, set: { model.configuration.bar.opacity = 1 - $0 }), range: 0...1, suffix: "")
                Text("0% is fully opaque. 100% is fully transparent. Blur uses a stable wallpaper-backed image so Space gestures cannot change its material emphasis or turn it black.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Blur sidebars and wallpaper gallery", isOn: $model.configuration.bar.panelBlurEnabled)
                ValueSlider("Panel transparency", value: Binding(get: { 1 - model.configuration.bar.panelOpacity }, set: { model.configuration.bar.panelOpacity = 1 - $0 }), range: 0...1, suffix: "")
                Text("0% is opaque. 100% reveals the desktop behind side panels and popovers.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ValueSlider: View {
    let name: String; @Binding var value: Double; let range: ClosedRange<Double>; let suffix: String
    init(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) { self.name = name; _value = value; self.range = range; self.suffix = suffix }
    var body: some View {
        VStack(spacing: 5) {
            HStack { Text(name); Spacer(); Text(suffix.isEmpty ? String(format: "%.0f%%", value * 100) : "\(Int(value)) \(suffix)").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $value, in: range)
        }
    }
}

struct ThemeSettingsView: View {
    @ObservedObject var model: AppModel
    private let themes: [ThemePalette] = [.classic, .trueBlack, .graphite, .paper]
    var body: some View {
        SettingsGroup("Presets") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(themes) { theme in
                    Button { model.configuration.bar.palette = theme } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 0) { ForEach([theme.background, theme.surface, theme.accent, theme.success], id: \.self) { Color(hex: $0).frame(height: 28) } }.clipShape(RoundedRectangle(cornerRadius: 7))
                            Text(theme.name).fontWeight(.semibold).foregroundStyle(.primary)
                            Text(theme.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.configuration.bar.palette.id == theme.id ? Color.accentColor.opacity(0.1) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(model.configuration.bar.palette.id == theme.id ? Color.accentColor : .primary.opacity(0.08)))
                    }.buttonStyle(SettingsHoverButtonStyle())
                }
            }
        }
        SettingsGroup("Custom palette") {
            ColorRow("Background", hex: paletteBinding(\.background))
            ColorRow("Raised surface", hex: paletteBinding(\.surface))
            ColorRow("Text", hex: paletteBinding(\.foreground))
            ColorRow("Muted text", hex: paletteBinding(\.muted))
            ColorRow("Accent", hex: paletteBinding(\.accent))
            ColorRow("Success", hex: paletteBinding(\.success))
        }
    }
    private func paletteBinding(_ keyPath: WritableKeyPath<ThemePalette, String>) -> Binding<String> {
        Binding(get: { model.configuration.bar.palette[keyPath: keyPath] }, set: { model.configuration.bar.palette.id = "custom"; model.configuration.bar.palette.name = "Custom"; model.configuration.bar.palette[keyPath: keyPath] = $0 })
    }
}

struct ColorRow: View {
    let name: String; @Binding var hex: String
    init(_ name: String, hex: Binding<String>) { self.name = name; _hex = hex }
    var body: some View {
        HStack { Text(name); Spacer(); Text(hex).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary); ColorPicker("", selection: Binding(get: { Color(hex: hex) }, set: { hex = NSColor($0).hexString })).labelsHidden() }
    }
}

struct ModuleSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            Text("Arrange widgets with the detailed controls below; changes appear on the desktop bar immediately.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu("Add widget", systemImage: "plus") {
                ForEach(WidgetKind.allCases.filter { $0 != .spacer }) { kind in Button(kind.rawValue) { add(kind) } }
                Divider()
                Button("Flexible space") { add(.spacer) }
            }
        }
        SettingsGroup("Widget layout") {
            if model.configuration.bar.widgets.isEmpty { Text("Add a widget to begin.").foregroundStyle(.secondary) }
            ForEach(Array(model.configuration.bar.widgets.indices), id: \.self) { index in
                WidgetEditor(model: model, index: index, selected: model.configuration.bar.widgets[index].id == model.selectedEditorWidget)
                if index < model.configuration.bar.widgets.count - 1 { Divider() }
            }
        }
        SettingsGroup("Desktop buttons") {
            Stepper("Number of desktops: \(model.configuration.bar.workspaceCount)", value: $model.configuration.bar.workspaceCount, in: 1...9)
            Toggle("Show app icons instead of numbers", isOn: $model.configuration.bar.showWorkspaceAppIcons)
            Text("A desktop with an application shows its frontmost app icon in a circular button. Empty desktops keep their number.").font(.caption).foregroundStyle(.secondary)
            Text("Desktop buttons send macOS Control+Number. Enable matching shortcuts in System Settings, Keyboard, Keyboard Shortcuts, Mission Control.").font(.caption).foregroundStyle(.secondary)
            Button("Open Mission Control Shortcuts") { WorkspaceController.openMissionControlShortcuts() }
        }
    }
    private func add(_ kind: WidgetKind) {
        model.configuration.bar.widgets.append(WidgetConfiguration(kind: kind, name: kind.rawValue, placement: .trailing, icon: kind.defaultIcon, style: kind == .customScript ? .pill : .plain))
    }
}

private struct WidgetEditor: View {
    @ObservedObject var model: AppModel
    let index: Int
    let selected: Bool
    private let icons = ["macwindow", "clock", "calendar", "wifi", "antenna.radiowaves.left.and.right", "battery.75percent", "bolt.fill", "speaker.wave.2", "music.note", "cpu", "memorychip", "terminal", "folder", "photo", "cloud.sun", "bell", "lock", "shield", "slider.horizontal.3", "circle.fill"]
    private var widget: WidgetConfiguration { model.configuration.bar.widgets[index] }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Position", selection: $model.configuration.bar.widgets[index].placement) { ForEach(WidgetPlacement.allCases) { Text($0.shortName).tag($0) } }
                    Picker("Look", selection: $model.configuration.bar.widgets[index].style) { ForEach(WidgetStyle.allCases) { Text($0.rawValue).tag($0) } }
                }
                HStack {
                    TextField("Widget name", text: $model.configuration.bar.widgets[index].name)
                    TextField("SF Symbol, text:☁︎, or image path", text: $model.configuration.bar.widgets[index].icon).font(.system(.body, design: .monospaced))
                    Menu {
                        ForEach(icons, id: \.self) { icon in Button { model.configuration.bar.widgets[index].icon = icon } label: { Label(icon, systemImage: icon) } }
                        Divider()
                        ForEach(["", "●", "◆", "☀︎", "☁︎"], id: \.self) { glyph in Button(glyph) { model.configuration.bar.widgets[index].icon = "text:\(glyph)" } }
                        Divider()
                        Button("Choose image…") { chooseImage() }
                    } label: { WidgetIcon(value: widget.icon).frame(width: 24) }
                }
                HStack { Toggle("Icon", isOn: $model.configuration.bar.widgets[index].showIcon); Toggle("Value", isOn: $model.configuration.bar.widgets[index].showLabel); Spacer() }
                HStack {
                    ValueSlider("Type size", value: $model.configuration.bar.widgets[index].fontSize, range: 9...22, suffix: "pt")
                    ValueSlider("Padding", value: $model.configuration.bar.widgets[index].horizontalPadding, range: 0...24, suffix: "pt")
                    ValueSlider("Radius", value: $model.configuration.bar.widgets[index].cornerRadius, range: 0...20, suffix: "pt")
                }
                OptionalColorRow(label: "Widget text", value: $model.configuration.bar.widgets[index].foreground)
                OptionalColorRow(label: "Widget background", value: $model.configuration.bar.widgets[index].background)
                if widget.kind == .customScript {
                    TextField("Shell command that prints a value", text: $model.configuration.bar.widgets[index].script)
                    ValueSlider("Refresh", value: $model.configuration.bar.widgets[index].refreshInterval, range: 2...300, suffix: "sec")
                }
                Picker("When clicked", selection: $model.configuration.bar.widgets[index].clickAction) { ForEach(WidgetClickAction.allCases) { Text($0.rawValue).tag($0) } }
                if widget.clickAction == .shell { TextField("Command to run", text: $model.configuration.bar.widgets[index].clickCommand) }
                HStack {
                    Button("Duplicate") { var copy = widget; copy.id = UUID(); copy.name += " copy"; model.configuration.bar.widgets.insert(copy, at: index + 1) }
                    Spacer()
                    Button("Remove", role: .destructive) { model.configuration.bar.widgets.remove(at: index) }
                }
            }.padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Toggle("", isOn: $model.configuration.bar.widgets[index].enabled).labelsHidden()
                WidgetIcon(value: widget.icon).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) { Text(widget.name).fontWeight(.medium); Text(widget.placement.shortName).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(index == 0)
                Button { move(1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(index >= model.configuration.bar.widgets.count - 1)
            }
        }
        .padding(selected ? 8 : 0)
        .background(selected ? Color.accentColor.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18), value: selected)
    }
    private func move(_ offset: Int) { model.configuration.bar.widgets.swapAt(index, index + offset) }
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let path = panel.url?.path { model.configuration.bar.widgets[index].icon = path }
    }
}

private struct OptionalColorRow: View {
    let label: String; @Binding var value: String?
    var body: some View {
        HStack {
            Toggle("Custom \(label.lowercased())", isOn: Binding(get: { value != nil }, set: { value = $0 ? "#CBC4CB" : nil }))
            Spacer()
            if let current = value {
                Text(current).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                ColorPicker("", selection: Binding(get: { Color(hex: current) }, set: { value = NSColor($0).hexString })).labelsHidden()
            }
        }
    }
}
