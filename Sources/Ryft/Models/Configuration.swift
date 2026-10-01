import AppKit
import SwiftUI

struct ThemePalette: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var source: String
    var background: String
    var surface: String
    var foreground: String
    var muted: String
    var accent: String
    var success: String

    static let classic = ThemePalette(id: "source-classic", name: "Classic", source: "Ryft", background: "#141313", surface: "#2D2A2F", foreground: "#E6E1E1", muted: "#948F94", accent: "#CBC4CB", success: "#B5CCBA")
    static let graphite = ThemePalette(id: "graphite", name: "Graphite", source: "Ryft", background: "#17191C", surface: "#282C31", foreground: "#F0F1F2", muted: "#969CA5", accent: "#F0A35B", success: "#7DBD8B")
    static let paper = ThemePalette(id: "paper", name: "Paper", source: "Ryft", background: "#F1EFEA", surface: "#DDD9D0", foreground: "#242321", muted: "#6D6962", accent: "#B84D3C", success: "#46745A")
    static let trueBlack = ThemePalette(id: "true-black", name: "True Black", source: "Ryft", background: "#000000", surface: "#151515", foreground: "#F2F2F2", muted: "#A0A0A0", accent: "#D0D0D0", success: "#8CCF9B")
}

enum BarPresentation: String, Codable, CaseIterable, Identifiable {
    case floating = "Floating", edges = "Touching edges", top = "Flush with edges"
    var id: String { rawValue }
    var settingsLabel: String {
        switch self { case .floating: "Floating"; case .edges: "Full width"; case .top: "Flush" }
    }
}
enum BarPosition: String, Codable, CaseIterable, Identifiable {
    case top = "Top", bottom = "Bottom", left = "Left", right = "Right"
    var id: String { rawValue }
    var isVertical: Bool { self == .left || self == .right }
    var popoverEdge: Edge { switch self { case .top: .top; case .bottom: .bottom; case .left: .leading; case .right: .trailing } }
}
enum BarBlurStyle: String, Codable, CaseIterable, Identifiable { case thin = "Thin", regular = "Regular", thick = "Thick"; var id: String { rawValue } }
enum BuiltInBarStyle: String, CaseIterable, Identifiable {
    case sourceExact = "Classic · Exact"
    case source = "Classic", islands = "Module islands", minimal = "Minimal line"
    case compact = "Compact", catppuccin = "Catppuccin", nord = "Nord"
    case pillOnly = "Pills only", monochrome = "Monochrome", rose = "Rose garden", solarized = "Solarized", outline = "Outline"
    var id: String { rawValue }
    var subtitle: String {
        switch self {
        case .source: "Balanced source layout"; case .islands: "Every module floats"; case .minimal: "Quiet and transparent"
        case .compact: "Dense, narrow controls"; case .catppuccin: "Mauve Mocha palette"; case .nord: "Frosted arctic palette"
        case .sourceExact: "Original geometry and palette"
        case .pillOnly: "No bar surface, only modules"; case .monochrome: "Pure neutral utility"; case .rose: "Muted rose and sage"; case .solarized: "Classic precision colors"; case .outline: "Transparent outlined modules"
        }
    }
}

enum TilingLayoutMode: String, Codable, CaseIterable, Identifiable {
    case placementOnly = "Sizing & positioning"
    case dwindle = "Hyprland Dwindle"
    var id: String { rawValue }
    var description: String {
        switch self {
        case .placementOnly: "Automatically sizes and positions windows in a balanced layout without Hyprland recursion, pane ratios, or swapping."
        case .dwindle: "Keeps a binary tree per desktop. New windows split the focused or cursor-selected pane, with native maximize and exact tile restoration."
        }
    }
}

enum DwindleWindowPlacement: String, Codable, CaseIterable, Identifiable {
    case cursor = "Follow cursor", before = "Left or top", after = "Right or bottom"
    var id: String { rawValue }
}

struct TilingConfiguration: Codable, Equatable {
    var enabled = false
    var mode: TilingLayoutMode = .dwindle
    var preserveSplit = false
    var useActiveForSplits = true
    var splitWidthMultiplier: Double = 1
    var defaultSplitRatio: Double = 1
    var newWindowPlacement: DwindleWindowPlacement = .cursor
    var excludedBundleIdentifiers: [String] = []
    var gap: Double = 10
    var outerGap: Double = 8

    enum CodingKeys: String, CodingKey { case enabled, mode, preserveSplit, useActiveForSplits, splitWidthMultiplier, defaultSplitRatio, newWindowPlacement, excludedBundleIdentifiers, gap, outerGap }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mode = try c.decodeIfPresent(TilingLayoutMode.self, forKey: .mode) ?? .dwindle
        preserveSplit = try c.decodeIfPresent(Bool.self, forKey: .preserveSplit) ?? false
        useActiveForSplits = try c.decodeIfPresent(Bool.self, forKey: .useActiveForSplits) ?? true
        splitWidthMultiplier = min(3, max(0.1, try c.decodeIfPresent(Double.self, forKey: .splitWidthMultiplier) ?? 1))
        defaultSplitRatio = min(1.9, max(0.1, try c.decodeIfPresent(Double.self, forKey: .defaultSplitRatio) ?? 1))
        newWindowPlacement = try c.decodeIfPresent(DwindleWindowPlacement.self, forKey: .newWindowPlacement) ?? .cursor
        excludedBundleIdentifiers = try c.decodeIfPresent([String].self, forKey: .excludedBundleIdentifiers) ?? []
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 10
        outerGap = try c.decodeIfPresent(Double.self, forKey: .outerGap) ?? 8
    }
}

struct NamedBarProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var bar: BarConfiguration
}
enum WidgetPlacement: String, Codable, CaseIterable, Identifiable {
    case leading = "Far left", beforeNotch = "Before notch", afterNotch = "After notch", trailing = "Far right"
    var id: String { rawValue }
    var shortName: String {
        switch self { case .leading: "Left"; case .beforeNotch: "Center left"; case .afterNotch: "Center right"; case .trailing: "Right" }
    }
}
enum WidgetStyle: String, Codable, CaseIterable, Identifiable { case plain = "Plain", pill = "Filled pill", outlined = "Outlined pill"; var id: String { rawValue } }
enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case leftSidebar = "Left sidebar", wallpaper = "Wallpaper", activeApp = "Active app", workspaces = "Workspaces", clock = "Clock", wifi = "Wi-Fi", battery = "Battery", volume = "Volume", uptime = "Uptime", rightSidebar = "Right sidebar", settings = "Settings", customScript = "Shell widget", spacer = "Flexible space"
    var id: String { rawValue }
    var defaultIcon: String {
        switch self { case .leftSidebar: "sparkles"; case .wallpaper: "photo.on.rectangle.angled"; case .activeApp: "macwindow"; case .workspaces: "square.grid.3x1.fill"; case .clock: "clock"; case .wifi: "wifi"; case .battery: "battery.75percent"; case .volume: "speaker.wave.2"; case .uptime: "cpu"; case .rightSidebar: "switch.2"; case .settings: "gearshape.fill"; case .customScript: "terminal"; case .spacer: "arrow.left.and.right" }
    }
}
enum WidgetClickAction: String, Codable, CaseIterable, Identifiable {
    case none = "Nothing", leftSidebar = "Toggle left sidebar", rightSidebar = "Toggle right sidebar", settings = "Open Ryft", wallpapers = "Wallpaper gallery", randomWallpaper = "Random wallpaper", shell = "Run shell command"
    var id: String { rawValue }
}

struct WidgetConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: WidgetKind
    var name: String
    var enabled = true
    var placement: WidgetPlacement
    var icon: String
    var showIcon = true
    var showLabel = true
    var style: WidgetStyle = .plain
    var fontSize: Double = 12.5
    var horizontalPadding: Double = 9
    var cornerRadius: Double = 14
    var foreground: String? = nil
    var background: String? = nil
    var script = "echo hello"
    var refreshInterval: Double = 10
    var clickAction: WidgetClickAction = .none
    var clickCommand = ""

    init(id: UUID = UUID(), kind: WidgetKind, name: String, enabled: Bool = true, placement: WidgetPlacement, icon: String, showIcon: Bool = true, showLabel: Bool = true, style: WidgetStyle = .plain, fontSize: Double = 12.5, horizontalPadding: Double = 9, cornerRadius: Double = 12, foreground: String? = nil, background: String? = nil, script: String = "echo hello", refreshInterval: Double = 10, clickAction: WidgetClickAction = .none, clickCommand: String = "") {
        self.id = id; self.kind = kind; self.name = name; self.enabled = enabled; self.placement = placement; self.icon = icon
        self.showIcon = showIcon; self.showLabel = showLabel; self.style = style; self.fontSize = fontSize; self.horizontalPadding = horizontalPadding; self.cornerRadius = cornerRadius
        self.foreground = foreground; self.background = background; self.script = script; self.refreshInterval = refreshInterval; self.clickAction = clickAction; self.clickCommand = clickCommand
    }
    enum CodingKeys: String, CodingKey { case id, kind, name, enabled, placement, icon, showIcon, showLabel, style, fontSize, horizontalPadding, cornerRadius, foreground, background, script, refreshInterval, clickAction, clickCommand }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(WidgetKind.self, forKey: .kind)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? kind.rawValue
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        placement = try c.decodeIfPresent(WidgetPlacement.self, forKey: .placement) ?? .trailing
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? kind.defaultIcon
        showIcon = try c.decodeIfPresent(Bool.self, forKey: .showIcon) ?? true
        showLabel = try c.decodeIfPresent(Bool.self, forKey: .showLabel) ?? true
        style = try c.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? .plain
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 12.5
        horizontalPadding = try c.decodeIfPresent(Double.self, forKey: .horizontalPadding) ?? 9
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 12
        foreground = try c.decodeIfPresent(String.self, forKey: .foreground)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? "echo hello"
        refreshInterval = try c.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 10
        clickAction = try c.decodeIfPresent(WidgetClickAction.self, forKey: .clickAction) ?? .none
        clickCommand = try c.decodeIfPresent(String.self, forKey: .clickCommand) ?? ""
    }

    static let defaults: [WidgetConfiguration] = [
        .init(kind: .leftSidebar, name: "Tools", placement: .leading, icon: "sparkle", showLabel: false, style: .plain, clickAction: .leftSidebar),
        .init(kind: .wallpaper, name: "Wallpapers", placement: .leading, icon: "photo.on.rectangle.angled", showLabel: false, style: .pill, clickAction: .none),
        .init(kind: .activeApp, name: "Active app", placement: .leading, icon: "macwindow", style: .plain),
        .init(kind: .uptime, name: "Resources", placement: .beforeNotch, icon: "cpu", style: .pill, horizontalPadding: 5),
        .init(kind: .workspaces, name: "Desktops", placement: .beforeNotch, icon: "square.grid.3x1.fill", style: .pill, horizontalPadding: 5),
        .init(kind: .clock, name: "Date and time", placement: .afterNotch, icon: "clock", style: .plain, clickAction: .rightSidebar),
        .init(kind: .wifi, name: "Wi-Fi", placement: .trailing, icon: "wifi", showLabel: false, clickAction: .rightSidebar),
        .init(kind: .volume, name: "Volume", placement: .trailing, icon: "speaker.wave.2", clickAction: .rightSidebar),
        .init(kind: .battery, name: "Battery", placement: .trailing, icon: "battery.75percent", clickAction: .rightSidebar),
        .init(kind: .rightSidebar, name: "Control center", placement: .trailing, icon: "switch.2", showLabel: false, style: .pill, clickAction: .rightSidebar),
        .init(kind: .settings, name: "Ryft settings", placement: .trailing, icon: "gearshape.fill", showLabel: false, clickAction: .settings)
    ]
}

struct BarConfiguration: Codable, Equatable {
    var enabled = true
    var height: Double = 42
    var horizontalInset: Double = 12
    var outerInset: Double = 5
    var itemSpacing: Double = 5
    var cornerRadius: Double = 18
    var opacity: Double = 0.82
    var showBackground = true
    var sourceExact = false
    var blurEnabled = false
    var blurStyle: BarBlurStyle = .regular
    var panelBlurEnabled = true
    var panelOpacity: Double = 0.88
    var presentation: BarPresentation = .floating
    var position: BarPosition = .top
    var showOnAllDisplays = true
    var reserveNotchSpace = true
    var splitAroundNotch = true
    var notchMaskEnabled = false
    var notchMaskHeight: Double = 0
    var notchShelfCornerRadius: Double = 14
    var roundBottomDisplayCorners = false
    var displayCornerRadius: Double = 18
    var manualNotchWidth: Double = 0
    var workspaceCount = 5
    var showWorkspaceAppIcons = true
    var palette: ThemePalette = .classic
    var widgets: [WidgetConfiguration] = WidgetConfiguration.defaults

    enum CodingKeys: String, CodingKey { case enabled, height, horizontalInset, outerInset, itemSpacing, cornerRadius, opacity, showBackground, sourceExact, blurEnabled, blurStyle, panelBlurEnabled, panelOpacity, presentation, position, showOnAllDisplays, reserveNotchSpace, splitAroundNotch, notchMaskEnabled, notchMaskHeight, notchShelfCornerRadius, roundBottomDisplayCorners, displayCornerRadius, manualNotchWidth, workspaceCount, showWorkspaceAppIcons, palette, widgets }
    enum LegacyCodingKeys: String, CodingKey { case floating, connectedPanel }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 42
        horizontalInset = try c.decodeIfPresent(Double.self, forKey: .horizontalInset) ?? 12
        outerInset = try c.decodeIfPresent(Double.self, forKey: .outerInset) ?? 5
        itemSpacing = try c.decodeIfPresent(Double.self, forKey: .itemSpacing) ?? 5
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 18
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.82
        showBackground = try c.decodeIfPresent(Bool.self, forKey: .showBackground) ?? true
        sourceExact = try c.decodeIfPresent(Bool.self, forKey: .sourceExact) ?? false
        blurEnabled = try c.decodeIfPresent(Bool.self, forKey: .blurEnabled) ?? false
        blurStyle = try c.decodeIfPresent(BarBlurStyle.self, forKey: .blurStyle) ?? .regular
        panelBlurEnabled = try c.decodeIfPresent(Bool.self, forKey: .panelBlurEnabled) ?? true
        panelOpacity = try c.decodeIfPresent(Double.self, forKey: .panelOpacity) ?? 0.88
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let decoded = try c.decodeIfPresent(BarPresentation.self, forKey: .presentation) { presentation = decoded }
        else if try legacy.decodeIfPresent(Bool.self, forKey: .connectedPanel) == true { presentation = .top }
        else if try legacy.decodeIfPresent(Bool.self, forKey: .floating) == false { presentation = .edges }
        else { presentation = .floating }
        position = try c.decodeIfPresent(BarPosition.self, forKey: .position) ?? .top
        showOnAllDisplays = try c.decodeIfPresent(Bool.self, forKey: .showOnAllDisplays) ?? true
        reserveNotchSpace = try c.decodeIfPresent(Bool.self, forKey: .reserveNotchSpace) ?? true
        splitAroundNotch = try c.decodeIfPresent(Bool.self, forKey: .splitAroundNotch) ?? true
        notchMaskEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchMaskEnabled) ?? false
        notchMaskHeight = try c.decodeIfPresent(Double.self, forKey: .notchMaskHeight) ?? 0
        notchShelfCornerRadius = try c.decodeIfPresent(Double.self, forKey: .notchShelfCornerRadius) ?? 14
        roundBottomDisplayCorners = try c.decodeIfPresent(Bool.self, forKey: .roundBottomDisplayCorners) ?? false
        displayCornerRadius = try c.decodeIfPresent(Double.self, forKey: .displayCornerRadius) ?? 18
        manualNotchWidth = try c.decodeIfPresent(Double.self, forKey: .manualNotchWidth) ?? 0
        workspaceCount = try c.decodeIfPresent(Int.self, forKey: .workspaceCount) ?? 5
        showWorkspaceAppIcons = try c.decodeIfPresent(Bool.self, forKey: .showWorkspaceAppIcons) ?? true
        palette = try c.decodeIfPresent(ThemePalette.self, forKey: .palette) ?? .classic
        widgets = try c.decodeIfPresent([WidgetConfiguration].self, forKey: .widgets) ?? WidgetConfiguration.defaults
    }
}

extension BarConfiguration {
    mutating func apply(_ style: BuiltInBarStyle) {
        showBackground = true
        sourceExact = false
        presentation = .floating
        for index in widgets.indices { widgets[index].enabled = true }
        switch style {
        case .source:
            height = 42; horizontalInset = 12; outerInset = 5; cornerRadius = 18; presentation = .floating; splitAroundNotch = true; blurEnabled = false; opacity = 0.72
            for index in widgets.indices { widgets[index].style = [.uptime, .workspaces, .rightSidebar].contains(widgets[index].kind) ? .pill : .plain }
        case .sourceExact:
            sourceExact = true; height = 42; horizontalInset = 5; outerInset = 5; itemSpacing = 4; cornerRadius = 18; presentation = .floating; reserveNotchSpace = false; splitAroundNotch = false; showBackground = true; blurEnabled = false; opacity = 1
            palette = .classic; widgets = WidgetConfiguration.defaults
            for index in widgets.indices {
                widgets[index].fontSize = 13; widgets[index].cornerRadius = 17
                widgets[index].style = [.uptime, .workspaces, .clock, .rightSidebar].contains(widgets[index].kind) ? .pill : .plain
                if [.wifi, .volume, .battery, .settings].contains(widgets[index].kind) { widgets[index].enabled = false }
            }
        case .islands:
            height = 44; horizontalInset = 16; outerInset = 7; cornerRadius = 18; presentation = .floating; splitAroundNotch = true; showBackground = false; blurEnabled = false; opacity = 1
            for index in widgets.indices { widgets[index].style = .pill; widgets[index].horizontalPadding = 10 }
        case .minimal:
            height = 34; horizontalInset = 18; outerInset = 4; cornerRadius = 8; presentation = .floating; splitAroundNotch = true; blurEnabled = false; opacity = 0.42
            for index in widgets.indices { widgets[index].style = .plain; widgets[index].fontSize = 11 }
        case .compact:
            height = 34; horizontalInset = 20; outerInset = 4; cornerRadius = 12; presentation = .floating; splitAroundNotch = true; blurEnabled = false; opacity = 0.78; itemSpacing = 2
            for index in widgets.indices { widgets[index].fontSize = 10.5; widgets[index].horizontalPadding = 5; widgets[index].cornerRadius = 9 }
        case .catppuccin:
            height = 42; horizontalInset = 14; outerInset = 6; cornerRadius = 18; presentation = .floating; splitAroundNotch = true; blurEnabled = false; opacity = 0.88
            palette = ThemePalette(id: "catppuccin", name: "Catppuccin Mocha", source: "Ryft", background: "#1E1E2E", surface: "#313244", foreground: "#CDD6F4", muted: "#A6ADC8", accent: "#CBA6F7", success: "#A6E3A1")
            for index in widgets.indices { widgets[index].style = [.uptime, .workspaces, .rightSidebar].contains(widgets[index].kind) ? .pill : .plain }
        case .nord:
            height = 40; horizontalInset = 16; outerInset = 6; cornerRadius = 14; presentation = .floating; splitAroundNotch = true; showBackground = false; blurEnabled = false; opacity = 1
            palette = ThemePalette(id: "nord", name: "Nord", source: "Ryft", background: "#2E3440", surface: "#3B4252", foreground: "#ECEFF4", muted: "#D8DEE9", accent: "#88C0D0", success: "#A3BE8C")
            for index in widgets.indices { widgets[index].style = .outlined }
        case .pillOnly:
            height = 40; horizontalInset = 14; outerInset = 6; presentation = .floating; splitAroundNotch = true; showBackground = false; blurEnabled = false; itemSpacing = 7
            for index in widgets.indices {
                widgets[index].style = .pill
                widgets[index].horizontalPadding = [.wifi, .settings].contains(widgets[index].kind) ? 7 : 9; widgets[index].cornerRadius = 12
                if [.wifi, .volume, .battery].contains(widgets[index].kind) { widgets[index].enabled = true }
                if widgets[index].kind == .rightSidebar { widgets[index].enabled = true; widgets[index].icon = "slider.horizontal.3"; widgets[index].showIcon = true; widgets[index].showLabel = false }
                if widgets[index].kind == .settings { widgets[index].enabled = true }
            }
        case .monochrome:
            height = 38; horizontalInset = 18; outerInset = 5; cornerRadius = 10; opacity = 0.9; blurEnabled = false
            palette = ThemePalette(id: "monochrome", name: "Monochrome", source: "Ryft", background: "#101010", surface: "#292929", foreground: "#F0F0F0", muted: "#A0A0A0", accent: "#D4D4D4", success: "#D4D4D4")
            for index in widgets.indices { widgets[index].style = .plain }
        case .rose:
            height = 44; horizontalInset = 16; outerInset = 7; cornerRadius = 20; opacity = 0.92; blurEnabled = false
            palette = ThemePalette(id: "rose", name: "Rose Garden", source: "Ryft", background: "#271C21", surface: "#49323D", foreground: "#F4E7EC", muted: "#C6A8B4", accent: "#E49AB0", success: "#AFC7A0")
            for index in widgets.indices { widgets[index].style = [.workspaces, .clock, .rightSidebar].contains(widgets[index].kind) ? .pill : .plain }
        case .solarized:
            height = 40; horizontalInset = 12; outerInset = 5; cornerRadius = 12; opacity = 0.94; blurEnabled = false
            palette = ThemePalette(id: "solarized", name: "Solarized Dark", source: "Ryft", background: "#002B36", surface: "#073642", foreground: "#EEE8D5", muted: "#93A1A1", accent: "#2AA198", success: "#859900")
            for index in widgets.indices { widgets[index].style = .pill }
        case .outline:
            height = 40; horizontalInset = 16; outerInset = 6; presentation = .floating; splitAroundNotch = true; showBackground = false; blurEnabled = false; itemSpacing = 6
            for index in widgets.indices { widgets[index].style = .outlined; widgets[index].horizontalPadding = 8; widgets[index].cornerRadius = 10 }
        }
    }
}

enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case wallpaper = "Wallpaper gallery", toggleBar = "Toggle bar", settings = "Open settings", randomWallpaper = "Random wallpaper", openFinder = "Open Finder", openApplication = "Open application", runCommand = "Run command", leftSidebar = "Open AI sidebar", rightSidebar = "Open control sidebar", screenAnswer = "Answer visible question", termatica = "Open or control Termatica", quitFrontmost = "Quit frontmost app"
    var id: String { rawValue }
}

struct ShortcutConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var action: ShortcutAction
    var key: String
    var option = true
    var command = false
    var control = false
    var shift = false
    var target: String? = nil
    var display: String { (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased() }
}

struct TodoConfiguration: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var date: Date

    init(id: UUID = UUID(), title: String, date: Date) {
        self.id = id; self.title = title; self.date = Calendar.current.startOfDay(for: date)
    }
    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self.init(title: legacy, date: Date())
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            title: try c.decode(String.self, forKey: .title),
            date: try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        )
    }
    enum CodingKeys: String, CodingKey { case id, title, date }
}

struct RyftConfiguration: Codable, Equatable {
    var bar = BarConfiguration()
    var shortcuts = [ShortcutConfiguration(action: .openFinder, key: "e", option: false, command: true), ShortcutConfiguration(action: .quitFrontmost, key: "q", option: false, command: true)]
    var wallpaperFolders = [NSHomeDirectory() + "/Pictures"]
    var wallpaperFiles: [String] = []
    var favoriteWallpapers: [String] = []
    var currentWallpaper: String = ""
    var adaptColorsToWallpaper = true
    var todos: [TodoConfiguration] = []
    var savedBars: [NamedBarProfile] = []
    var sourcePresetVersion = 18
    var launchAtLogin = false
    var hasCompletedOnboarding = false
    var tiling = TilingConfiguration()
    var useHyprlandCursor = false
    var experimentalWorkspaceTransitions = true
    var termaticaShortcutEnabled = true

    enum CodingKeys: String, CodingKey { case bar, shortcuts, wallpaperFolders, wallpaperFiles, favoriteWallpapers, currentWallpaper, adaptColorsToWallpaper, todos, savedBars, sourcePresetVersion, launchAtLogin, hasCompletedOnboarding, tiling, useHyprlandCursor, experimentalWorkspaceTransitions, termaticaShortcutEnabled }
    enum LegacyCodingKeys: String, CodingKey { case omniWMTiling }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bar = try c.decodeIfPresent(BarConfiguration.self, forKey: .bar) ?? BarConfiguration()
        shortcuts = try c.decodeIfPresent([ShortcutConfiguration].self, forKey: .shortcuts) ?? [ShortcutConfiguration(action: .openFinder, key: "e", option: false, command: true), ShortcutConfiguration(action: .quitFrontmost, key: "q", option: false, command: true)]
        wallpaperFolders = try c.decodeIfPresent([String].self, forKey: .wallpaperFolders) ?? [NSHomeDirectory() + "/Pictures"]
        wallpaperFiles = try c.decodeIfPresent([String].self, forKey: .wallpaperFiles) ?? []
        favoriteWallpapers = try c.decodeIfPresent([String].self, forKey: .favoriteWallpapers) ?? []
        currentWallpaper = try c.decodeIfPresent(String.self, forKey: .currentWallpaper) ?? ""
        adaptColorsToWallpaper = try c.decodeIfPresent(Bool.self, forKey: .adaptColorsToWallpaper) ?? true
        todos = try c.decodeIfPresent([TodoConfiguration].self, forKey: .todos) ?? []
        savedBars = try c.decodeIfPresent([NamedBarProfile].self, forKey: .savedBars) ?? []
        sourcePresetVersion = try c.decodeIfPresent(Int.self, forKey: .sourcePresetVersion) ?? 0
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        // Existing installations have already reached the product. Only a
        // genuinely new configuration enters first-run onboarding.
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? true
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        tiling = try c.decodeIfPresent(TilingConfiguration.self, forKey: .tiling)
            ?? legacy.decodeIfPresent(TilingConfiguration.self, forKey: .omniWMTiling)
            ?? TilingConfiguration()
        useHyprlandCursor = try c.decodeIfPresent(Bool.self, forKey: .useHyprlandCursor) ?? false
        experimentalWorkspaceTransitions = try c.decodeIfPresent(Bool.self, forKey: .experimentalWorkspaceTransitions) ?? true
        termaticaShortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .termaticaShortcutEnabled) ?? true
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var integer: UInt64 = 0; Scanner(string: value).scanHexInt64(&integer)
        let r, g, b: UInt64
        if value.count == 6 { (r, g, b) = (integer >> 16, integer >> 8 & 0xFF, integer & 0xFF) } else { (r, g, b) = (20, 19, 19) }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}
extension NSColor {
    var hexString: String { guard let c = usingColorSpace(.sRGB) else { return "#141313" }; return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)) }
}
