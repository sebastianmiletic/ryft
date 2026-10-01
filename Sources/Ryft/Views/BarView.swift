import SwiftUI
import UniformTypeIdentifiers
import RyftWindowLayout

private enum BarImageCache {
    static let images = NSCache<NSString, NSImage>()
    static func image(at path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = images.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        images.setObject(image, forKey: path as NSString); return image
    }
}

struct BarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var system: SystemMonitor
    @ObservedObject private var workspaces: WorkspaceService
    @Environment(\.displayScale) private var displayScale
    let notchWidth: Double
    let topReservedHeight: Double
    let configurationOverride: BarConfiguration?
    let interactionID: UUID?
    let editing: Bool
    let onSelectWidget: ((UUID) -> Void)?

    init(model: AppModel, notchWidth: Double = 0, topReservedHeight: Double = 0, configurationOverride: BarConfiguration? = nil, interactionID: UUID? = nil, editing: Bool = false, onSelectWidget: ((UUID) -> Void)? = nil) {
        self.model = model; self.system = model.system; self.workspaces = model.workspaces; self.notchWidth = notchWidth; self.topReservedHeight = topReservedHeight; self.configurationOverride = configurationOverride; self.interactionID = interactionID; self.editing = editing; self.onSelectWidget = onSelectWidget
    }
    private var config: BarConfiguration { configurationOverride ?? model.configuration.bar }
    private var palette: ThemePalette { config.palette }
    private func widgets(_ placement: WidgetPlacement) -> [WidgetConfiguration] { config.widgets.filter { $0.enabled && $0.placement == placement } }

    var body: some View {
        GeometryReader { proxy in
            if config.position.isVertical { verticalBar(in: proxy.size) }
            else { horizontalBar(in: proxy.size) }
        }
        .font(.system(size: 12.5, weight: .medium, design: .rounded))
        .foregroundStyle(Color(hex: palette.foreground))
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.22), value: model.screenAnswer)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16), value: model.screenAnswerLoading)
    }

    private func horizontalBar(in size: CGSize) -> some View {
        let contentInset: Double = 12
        let outerX = config.presentation == .floating ? config.horizontalInset : 0
        let verticalInset = config.presentation == .top ? 0 : PixelGrid.ceil(config.outerInset, scale: displayScale)
        let barWidth = max(0, size.width - outerX * 2)
        let barHeight = max(0, size.height - topReservedHeight - verticalInset * (config.position == .top ? 1 : 2))
        let sideWidth = max(0, (barWidth - contentInset * 2 - effectiveNotchWidth) / 2)
        return ZStack(alignment: .top) {
            if topReservedHeight > 0 { TrueBlackView().frame(width: size.width, height: topReservedHeight) }
            ZStack {
                barBackground
                HStack(spacing: 0) {
                    HStack(spacing: config.itemSpacing) { zone(.leading); Spacer(minLength: 3); zone(.beforeNotch) }
                        .frame(width: sideWidth, alignment: .leading)
                    Color.clear.frame(width: effectiveNotchWidth).accessibilityHidden(true)
                    HStack(spacing: config.itemSpacing) { zone(.afterNotch); Spacer(minLength: 3); zone(.trailing) }
                        .frame(width: sideWidth, alignment: .trailing)
                }.padding(.horizontal, contentInset)
            }
            .frame(width: barWidth, height: barHeight)
            .position(x: size.width / 2, y: topReservedHeight + barHeight / 2 + verticalInset)
        }
    }

    private func verticalBar(in size: CGSize) -> some View {
        let longInset = config.presentation == .floating ? config.horizontalInset : 0
        let edgeInset = config.presentation == .top ? 0 : config.outerInset
        let barWidth = max(0, size.width - edgeInset * 2)
        let barHeight = max(0, size.height - longInset * 2)
        return ZStack {
            barSurface
            VStack(spacing: config.itemSpacing) {
                verticalZone(.leading)
                Spacer(minLength: 4)
                verticalZone(.beforeNotch)
                Spacer(minLength: 8)
                verticalZone(.afterNotch)
                Spacer(minLength: 4)
                verticalZone(.trailing)
            }.padding(.vertical, 10).frame(maxWidth: .infinity)
        }
        .frame(width: barWidth, height: barHeight)
        .position(x: size.width / 2, y: size.height / 2)
    }

    private var effectiveNotchWidth: Double { config.position == .top && notchWidth > 0 ? notchWidth + 16 : 8 }
    private var barShape: RoundedRectangle { RoundedRectangle(cornerRadius: config.presentation == .floating ? config.cornerRadius : 0, style: .continuous) }
    @ViewBuilder private var barSurface: some View {
        if config.blurEnabled {
            ZStack {
                if let image = BarImageCache.image(at: model.configuration.currentWallpaper) {
                    Image(nsImage: image).resizable().scaledToFill().blur(radius: blurRadius).scaleEffect(1.08)
                } else { Color(hex: palette.background) }
                Color(hex: palette.background).opacity(config.opacity)
            }.clipShape(barShape)
                .overlay(barShape.stroke(Color(hex: palette.muted).opacity(0.3), lineWidth: config.presentation == .floating ? 1 : 0))
        } else {
            barShape.fill(Color(hex: palette.background).opacity(config.opacity))
                .overlay(barShape.stroke(Color(hex: palette.muted).opacity(0.22), lineWidth: config.presentation == .floating ? 1 : 0))
        }
    }
    private var blurRadius: CGFloat { switch config.blurStyle { case .thin: 8; case .regular: 16; case .thick: 28 } }
    @ViewBuilder private var barBackground: some View {
        if !config.showBackground {
            Color.clear
        } else if config.splitAroundNotch && notchWidth > 0 {
            HStack(spacing: effectiveNotchWidth) { barSurface; barSurface }
        } else { barSurface }
    }

    private func verticalZone(_ placement: WidgetPlacement) -> some View {
        VStack(spacing: config.itemSpacing) {
            ForEach(widgets(placement)) { widget in
                if widget.kind == .spacer { Spacer(minLength: 8) }
                else if editing {
                    WidgetView(model: model, system: system, controls: model.controls, workspaces: workspaces, widget: widget, interactionID: nil, actionEnabled: false)
                        .contentShape(Rectangle()).onTapGesture { onSelectWidget?(widget.id) }
                        .onDrag { NSItemProvider(object: widget.id.uuidString as NSString) }
                        .onDrop(of: [UTType.text], delegate: WidgetZoneDropDelegate(model: model, placement: placement, before: widget.id, enabled: true))
                } else {
                    WidgetView(model: model, system: system, controls: model.controls, workspaces: workspaces, widget: widget, interactionID: interactionID, actionEnabled: interactionID != nil)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .modifier(ZoneDropModifier(model: model, placement: placement, enabled: editing))
    }

    private func zone(_ placement: WidgetPlacement) -> some View {
        HStack(spacing: config.itemSpacing) {
            ForEach(widgets(placement)) { widget in
                if widget.kind == .spacer { Spacer(minLength: 8) }
                else if editing {
                    WidgetView(model: model, system: system, controls: model.controls, workspaces: workspaces, widget: widget, interactionID: nil, actionEnabled: false)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelectWidget?(widget.id) }
                        .onDrag { NSItemProvider(object: widget.id.uuidString as NSString) }
                        .onDrop(of: [UTType.text], delegate: WidgetZoneDropDelegate(model: model, placement: placement, before: widget.id, enabled: true))
                } else {
                    WidgetView(model: model, system: system, controls: model.controls, workspaces: workspaces, widget: widget, interactionID: interactionID, actionEnabled: interactionID != nil)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .frame(minHeight: 34)
        .contentShape(Rectangle())
        .modifier(ZoneDropModifier(model: model, placement: placement, enabled: editing))
    }
}

private struct ZoneDropModifier: ViewModifier {
    let model: AppModel
    let placement: WidgetPlacement
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.onDrop(of: [UTType.text], delegate: WidgetZoneDropDelegate(model: model, placement: placement, enabled: true)) }
        else { content }
    }
}

private struct WidgetZoneDropDelegate: DropDelegate {
    let model: AppModel
    let placement: WidgetPlacement
    var before: UUID? = nil
    let enabled: Bool

    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [UTType.text]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard enabled, let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? NSString, let id = UUID(uuidString: value as String) else { return }
            DispatchQueue.main.async {
                let changes = {
                    guard let source = model.configuration.bar.widgets.firstIndex(where: { $0.id == id }) else { return }
                    var moved = model.configuration.bar.widgets.remove(at: source)
                    moved.placement = placement
                    if let before, let target = model.configuration.bar.widgets.firstIndex(where: { $0.id == before }) {
                        model.configuration.bar.widgets.insert(moved, at: target)
                    } else {
                        let lastInZone = model.configuration.bar.widgets.lastIndex(where: { $0.placement == placement })
                        model.configuration.bar.widgets.insert(moved, at: lastInZone.map { $0 + 1 } ?? model.configuration.bar.widgets.endIndex)
                    }
                }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { changes() }
                else { withAnimation(.easeOut(duration: 0.2), changes) }
            }
        }
        return true
    }
}

private struct MarqueeAnswerText: View {
    let text: String
    let startedAt: Date
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var textWidth: CGFloat { ScreenAnswerMarqueeMetrics.textWidth(text) }

    var body: some View {
        Group {
            if !ScreenAnswerMarqueeMetrics.isLong(text) {
                answerLabel
            } else if reduceMotion {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: ScreenAnswerMarqueeMetrics.viewportWidth, alignment: .leading)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    let elapsed = context.date.timeIntervalSince(startedAt)
                    let active = max(0, elapsed - ScreenAnswerMarqueeMetrics.initialPause)
                    let distance = textWidth + ScreenAnswerMarqueeMetrics.gap
                    let cycle = TimeInterval(distance / ScreenAnswerMarqueeMetrics.speed)
                    let finished = active >= cycle * Double(ScreenAnswerMarqueeMetrics.repetitions)
                    let progress = cycle > 0 ? active.truncatingRemainder(dividingBy: cycle) / cycle : 0
                    HStack(spacing: ScreenAnswerMarqueeMetrics.gap) {
                        answerLabel
                        answerLabel.accessibilityHidden(true)
                    }
                    .offset(x: -CGFloat(progress) * distance)
                    .opacity(finished ? 0 : 1)
                }
                .frame(width: ScreenAnswerMarqueeMetrics.viewportWidth, alignment: .leading)
                .clipped()
            }
        }
        .accessibilityLabel(text)
    }

    private var answerLabel: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PulsingSparkle: View {
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            let pulse = (sin(phase * .pi * 2) + 1) / 2
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .semibold))
                .scaleEffect(reduceMotion ? 1 : 0.88 + pulse * 0.14)
                .opacity(reduceMotion ? 1 : 0.58 + pulse * 0.42)
                .frame(width: 20, height: 20)
        }
        .accessibilityLabel("Gemini is reading the screen")
    }
}

private struct BatteryGaugeIcon: View {
    let level: Int
    let charging: Bool
    let color: Color
    let background: Color

    private var step: Int {
        guard level >= 0 else { return 0 }
        return max(0, min(100, Int((Double(level) / 5).rounded()) * 5))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                .stroke(color, lineWidth: 1.35)
                .frame(width: 19, height: 11)
            RoundedRectangle(cornerRadius: 1.35, style: .continuous)
                .fill(color)
                .frame(width: 15.5 * CGFloat(step) / 100, height: 7)
                .offset(x: 2)
            Capsule().fill(color).frame(width: 2.2, height: 5).offset(x: 20)
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 6.5, weight: .black))
                    .foregroundStyle(step >= 50 ? background : color)
                    .frame(width: 19, height: 11)
            }
        }
        .frame(width: 23, height: 12)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16), value: step)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12), value: charging)
        .accessibilityLabel("Battery \(max(level, 0)) percent\(charging ? ", charging" : "")")
    }
}

private struct WidgetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var system: SystemMonitor
    @ObservedObject var controls: SystemControlService
    @ObservedObject var workspaces: WorkspaceService
    let widget: WidgetConfiguration
    let interactionID: UUID?
    let actionEnabled: Bool
    private var palette: ThemePalette { model.configuration.bar.palette }
    private var workspaceLayout: AnyLayout {
        model.configuration.bar.position.isVertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
    }

    @ViewBuilder var body: some View {
        if widget.kind == .workspaces {
            content.modifier(WidgetChrome(widget: widget, palette: palette)).accessibilityLabel(widget.name).help(widget.name)
        } else if widget.kind == .leftSidebar && !model.screenAnswer.isEmpty {
            Button { model.copyScreenAnswer() } label: { content.modifier(WidgetChrome(widget: widget, palette: palette)) }
                .buttonStyle(SourcePressButtonStyle()).accessibilityLabel("Copy AI answer").help("Copy answer")
        } else if widget.kind == .rightSidebar && model.configuration.bar.sourceExact {
            content.modifier(WidgetChrome(widget: widget, palette: palette)).accessibilityLabel(widget.name).help(widget.name)
        } else if widget.kind == .rightSidebar {
            Button { if actionEnabled { performAction() } } label: { content.modifier(WidgetChrome(widget: widget, palette: palette)) }
                .buttonStyle(SourcePressButtonStyle()).accessibilityLabel(widget.name).help(widget.name)
        } else if widget.kind == .wallpaper || widget.kind == .uptime || widget.kind == .clock {
            Button { if actionEnabled { showStatusPopover(for: widget.kind) } } label: { content.modifier(WidgetChrome(widget: widget, palette: palette)) }
                .buttonStyle(SourcePressButtonStyle()).accessibilityLabel(widget.name).help(widget.kind == .wallpaper ? "Choose wallpaper" : "Application resource usage")
                .popover(isPresented: popoverPresented, arrowEdge: model.configuration.bar.position.popoverEdge) { statusPopover }
        } else if widget.kind == .battery {
            Button { if actionEnabled { controls.setLowPowerMode(!controls.lowPowerMode) } } label: { content.modifier(WidgetChrome(widget: widget, palette: palette)) }
                .buttonStyle(SourcePressButtonStyle()).accessibilityLabel("Toggle Low Power Mode").help("Left-click toggles Low Power Mode. Right-click opens battery controls.")
                .background(RightClickCapture { showStatusPopover(for: .battery) })
                .popover(isPresented: popoverPresented, arrowEdge: model.configuration.bar.position.popoverEdge) { statusPopover }
        } else if [.wifi, .volume].contains(widget.kind) {
            Button { if actionEnabled { showStatusPopover(for: widget.kind) } } label: { content.modifier(WidgetChrome(widget: widget, palette: palette)) }
                .buttonStyle(SourcePressButtonStyle()).accessibilityLabel(widget.name).help(widget.name)
                .popover(isPresented: popoverPresented, arrowEdge: model.configuration.bar.position.popoverEdge) { statusPopover }
        } else if widget.clickAction != .none {
            Button { if actionEnabled { performAction() } } label: { content.modifier(WidgetChrome(widget: widget, palette: palette)) }
                .buttonStyle(SourcePressButtonStyle()).accessibilityLabel(widget.name).help(widget.name)
        } else {
            content.modifier(WidgetChrome(widget: widget, palette: palette)).accessibilityLabel(widget.name).help(widget.name)
        }
    }

    @ViewBuilder private var content: some View {
        switch widget.kind {
        case .workspaces:
            workspaceLayout {
                ForEach(1...max(workspaces.canReadSpaces ? workspaces.desktopCount : model.configuration.bar.workspaceCount, 1), id: \.self) { number in
                    Button {
                        if actionEnabled { workspaces.switchTo(number) { model.statusMessage = $0 } }
                    } label: {
                        ZStack {
                            Circle().fill(number == workspaces.currentDesktop ? Color(hex: palette.accent) : .clear)
                            if model.configuration.bar.showWorkspaceAppIcons, let icon = workspaces.icon(forDesktop: number) {
                                Image(nsImage: icon).resizable().scaledToFit().padding(2).clipShape(Circle())
                                    .id("\(number)-\(workspaces.desktopApplications[number]?.bundlePath ?? "app")")
                                    .transition(.scale(scale: 0.72).combined(with: .opacity))
                            } else {
                                Text("\(number)").font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(number == workspaces.currentDesktop ? Color(hex: palette.background) : Color(hex: palette.muted))
                                    .id("\(number)-number")
                                    .transition(.scale(scale: 0.72).combined(with: .opacity))
                            }
                        }
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(number == workspaces.currentDesktop ? Color(hex: palette.accent) : .clear, lineWidth: 1.5))
                        .frame(width: 26, height: 26)
                    }.buttonStyle(SourcePressButtonStyle())
                        .transition(.scale(scale: 0.78).combined(with: .opacity))
                        .accessibilityLabel(workspaces.desktopApplications[number].map { "Desktop \(number), \($0.name)" } ?? "Desktop \(number)")
                        .help(workspaces.desktopApplications[number].map { "Desktop \(number) · \($0.name)" } ?? "Desktop \(number)")
                }
            }
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18), value: workspaces.desktopCount)
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16), value: workspaces.desktopApplications)
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.14), value: workspaces.currentDesktop)
        case .clock:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if model.configuration.bar.position.isVertical {
                    VStack(spacing: 1) {
                        Text(context.date.formatted(.dateTime.hour().minute())).font(.system(size: 10, weight: .semibold, design: .rounded))
                        Text(context.date.formatted(.dateTime.weekday(.narrow))).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color(hex: palette.muted))
                    }.monospacedDigit()
                } else { widgetLabel(context.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit() }
            }
        case .leftSidebar:
            if model.screenAnswerLoading {
                PulsingSparkle().foregroundStyle(.white)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            } else if !model.screenAnswer.isEmpty {
                if model.screenAnswerIsChoice {
                    Text(model.screenAnswer).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(minWidth: 18).transition(.scale(scale: 0.72).combined(with: .opacity))
                } else {
                    HStack(spacing: 7) {
                        WidgetIcon(value: "sparkle")
                        MarqueeAnswerText(text: model.screenAnswer, startedAt: model.screenAnswerStartedAt)
                            .id(model.screenAnswer)
                    }
                    .foregroundStyle(.white).frame(maxWidth: 205, alignment: .leading).clipped()
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            } else { widgetLabel("Tools").foregroundStyle(.white) }
        case .wallpaper: widgetLabel("Wallpapers")
        case .activeApp: widgetLabel(system.activeApp)
        case .wifi: widgetLabel(system.wifi)
        case .battery:
            HStack(spacing: 5) {
                if widget.showIcon {
                    BatteryGaugeIcon(level: controls.batteryLevel, charging: controls.batteryCharging, color: batteryColor, background: Color(hex: palette.background))
                }
                if widget.showLabel && !model.configuration.bar.position.isVertical { Text(controls.batteryPercent).lineLimit(1) }
            }
        case .volume: widgetLabel("\(Int(controls.outputVolume))%")
        case .uptime: widgetLabel("CPU \(system.cpu) · RAM \(system.memory)")
        case .rightSidebar:
            if model.configuration.bar.position.isVertical { widgetLabel("Controls") }
            else if model.configuration.bar.sourceExact {
                HStack(spacing: 12) {
                    batteryDetailButton
                    detailButton("keyboard", detail: "")
                    detailButton("wifi", detail: "Wi-Fi")
                    detailButton(controls.outputVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", detail: "Sound")
                }.font(.system(size: 13, weight: .medium))
            } else { widgetLabel("Controls") }
        case .settings: widgetLabel("Settings")
        case .customScript: ScriptWidgetLabel(widget: widget, palette: palette)
        case .spacer: EmptyView()
        }
    }

    private var batteryColor: Color { controls.lowPowerMode ? .yellow : .white }
    private var popoverPresented: Binding<Bool> {
        Binding(get: { model.statusPopoverWidgetID == widget.id && model.statusPopoverInteractionID == interactionID }, set: { if !$0 { model.statusPopoverWidgetID = nil; model.statusPopoverInteractionID = nil; model.statusPopoverDetail = "" } })
    }
    @ViewBuilder private var statusPopover: some View {
        if model.statusPopoverWidgetID == widget.id && model.statusPopoverInteractionID == interactionID {
            if model.statusPopoverDetail == "Wallpapers" { WallpaperBarPopover(model: model).frame(width: 520) }
            else if model.statusPopoverDetail == "Resources" { ResourceUsagePopover(model: model).frame(width: 390) }
            else if model.statusPopoverDetail == "Calendar" { CalendarTodoPopover(model: model).frame(width: 560) }
            else { StatusQuickPopover(model: model, detail: model.statusPopoverDetail).frame(width: 300) }
        }
    }
    private func showStatusPopover(for kind: WidgetKind) {
        switch kind {
        case .wallpaper: model.statusPopoverDetail = "Wallpapers"; model.statusPopoverInteractionID = interactionID; model.statusPopoverWidgetID = widget.id
        case .uptime: model.statusPopoverDetail = "Resources"; model.statusPopoverInteractionID = interactionID; model.statusPopoverWidgetID = widget.id; system.refresh()
        case .clock: model.statusPopoverDetail = "Calendar"; model.statusPopoverInteractionID = interactionID; model.statusPopoverWidgetID = widget.id
        case .wifi: model.statusPopoverDetail = "Wi-Fi"; model.statusPopoverInteractionID = interactionID; model.statusPopoverWidgetID = widget.id; controls.prepareWiFiMenu()
        case .volume: model.statusPopoverDetail = "Sound"; model.statusPopoverInteractionID = interactionID; model.statusPopoverWidgetID = widget.id; controls.prepareSoundMenu()
        case .battery: model.statusPopoverDetail = "Battery"; model.statusPopoverInteractionID = interactionID; model.statusPopoverWidgetID = widget.id; controls.refreshPowerState()
        default: break
        }
    }
    private var batteryDetailButton: some View {
        Button {
            guard actionEnabled else { return }
            controls.setLowPowerMode(!controls.lowPowerMode)
        } label: {
            BatteryGaugeIcon(level: controls.batteryLevel, charging: controls.batteryCharging, color: batteryColor, background: Color(hex: palette.background))
                .frame(width: 25, height: 24)
        }
        .buttonStyle(SourcePressButtonStyle()).help("Battery")
        .background(RightClickCapture { showStatusPopover(for: .battery) })
    }
    private func detailButton(_ icon: String, detail: String, color: Color? = nil) -> some View {
        Button {
            guard actionEnabled else { return }
            if detail == "Battery" { controls.setLowPowerMode(!controls.lowPowerMode) }
            else if detail.isEmpty { NotificationCenter.default.post(name: .ryftToggleRightSidebar, object: nil) }
            else { model.statusPopoverDetail = detail; model.statusPopoverInteractionID = interactionID; model.statusPopoverWidgetID = widget.id; if detail == "Wi-Fi" { controls.prepareWiFiMenu() }; if detail == "Sound" { controls.prepareSoundMenu() } }
        } label: {
            Image(systemName: icon).foregroundStyle(color ?? Color(hex: palette.foreground)).frame(width: 18, height: 24)
        }
            .buttonStyle(SourcePressButtonStyle()).help(detail.isEmpty ? "Control center" : detail)
    }
    private func widgetLabel(_ value: String) -> some View {
        HStack(spacing: 6) {
            if widget.showIcon { WidgetIcon(value: widget.icon) }
            if widget.showLabel && !model.configuration.bar.position.isVertical { Text(value).lineLimit(1) }
        }
    }
    private func performAction() {
        switch widget.clickAction {
        case .none: break
        case .leftSidebar: NotificationCenter.default.post(name: .ryftToggleLeftSidebar, object: nil)
        case .rightSidebar:
            let detail: String
            switch widget.kind { case .wifi: detail = "Wi-Fi"; case .volume: detail = "Sound"; case .battery: detail = "Battery"; default: detail = "" }
            NotificationCenter.default.post(name: .ryftToggleRightSidebar, object: detail)
        case .settings: NotificationCenter.default.post(name: .ryftShowSettings, object: nil)
        case .wallpapers: NotificationCenter.default.post(name: .ryftShowWallpapers, object: nil)
        case .randomWallpaper: model.randomWallpaper()
        case .shell: ScriptWidgetRunner.runAction(widget.clickCommand)
        }
    }
}

private final class CalendarPopoverState: ObservableObject {
    @Published var visibleMonth = Date()
    @Published var selectedDate = Date()
    @Published var showAllTasks = false
}

private struct CalendarTodoPopover: View {
    @ObservedObject var model: AppModel
    @StateObject private var state = CalendarPopoverState()
    private let calendar = Calendar.current
    private var palette: ThemePalette { model.configuration.bar.palette }
    private var monthTitle: String { state.visibleMonth.formatted(.dateTime.month(.wide).year()) }
    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: state.visibleMonth),
              let range = calendar.range(of: .day, in: .month, for: state.visibleMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: interval.start) }
    }
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let split = calendar.firstWeekday - 1
        return Array(symbols[split...] + symbols[..<split])
    }
    private var visibleTodos: [(offset: Int, element: TodoConfiguration)] {
        Array(model.configuration.todos.enumerated()).filter { state.showAllTasks || calendar.isDate($0.element.date, inSameDayAs: state.selectedDate) }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(SourcePressButtonStyle())
                    Spacer(); Text(monthTitle).font(.system(size: 16, weight: .semibold, design: .rounded)); Spacer()
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(SourcePressButtonStyle())
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                    ForEach(weekdaySymbols, id: \.self) { Text($0.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: palette.muted)) }
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        if let day {
                            Button { state.selectedDate = day } label: {
                                Text("\(calendar.component(.day, from: day))").font(.system(size: 11, weight: calendar.isDateInToday(day) ? .bold : .medium, design: .rounded))
                                    .frame(width: 29, height: 29)
                                    .background(calendar.isDate(day, inSameDayAs: state.selectedDate) ? Color(hex: palette.accent) : Color.clear)
                                    .foregroundStyle(calendar.isDate(day, inSameDayAs: state.selectedDate) ? Color(hex: palette.background) : Color(hex: palette.foreground))
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(calendar.isDateInToday(day) ? Color(hex: palette.accent) : .clear, lineWidth: 1))
                            }.buttonStyle(SourcePressButtonStyle())
                        } else { Color.clear.frame(height: 29) }
                    }
                }
                Button("Today") { state.visibleMonth = Date(); state.selectedDate = Date() }.buttonStyle(QuickPopoverButtonStyle(palette: palette))
            }.padding(16).frame(width: 295)
            Rectangle().fill(Color(hex: palette.muted).opacity(0.22)).frame(width: 1).padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TASKS").font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(Color(hex: palette.muted))
                        Text(state.showAllTasks ? "All tasks" : state.selectedDate.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                    }
                    Spacer()
                    Button(state.showAllTasks ? "Selected day" : "All tasks") { state.showAllTasks.toggle() }
                        .buttonStyle(QuickPopoverButtonStyle(palette: palette))
                    Text("\(visibleTodos.count)").font(.caption.monospacedDigit()).padding(6).background(Color(hex: palette.surface)).clipShape(Circle())
                }
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        if visibleTodos.isEmpty {
                            Text(state.showAllTasks ? "No tasks yet" : "No tasks for this day").font(.caption).foregroundStyle(Color(hex: palette.muted)).frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        ForEach(visibleTodos, id: \.element.id) { index, todo in
                            HStack(spacing: 8) {
                                Button { removeTodo(index) } label: { Image(systemName: "circle").foregroundStyle(Color(hex: palette.accent)) }.buttonStyle(SourcePressButtonStyle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(todo.title).font(.caption).lineLimit(2)
                                    if state.showAllTasks { Text(todo.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(Color(hex: palette.muted)) }
                                }
                                Spacer()
                            }.padding(9).background(Color(hex: palette.surface)).clipShape(RoundedRectangle(cornerRadius: 10))
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                        }
                    }
                }
                HStack(spacing: 7) {
                    TextField("Add a task", text: $model.todoDraft).textFieldStyle(.plain).onSubmit { addTodo() }
                    Button { addTodo() } label: { Image(systemName: "plus").frame(width: 25, height: 25).background(Color(hex: palette.accent)).foregroundStyle(Color(hex: palette.background)).clipShape(Circle()) }.buttonStyle(SourcePressButtonStyle())
                }.padding(9).background(Color(hex: palette.surface)).clipShape(RoundedRectangle(cornerRadius: 11))
            }.padding(16).frame(maxWidth: .infinity)
        }
        .background(Color(hex: palette.background)).foregroundStyle(Color(hex: palette.foreground))
        .background(OutsideClickDismissMonitor { model.statusPopoverWidgetID = nil; model.statusPopoverInteractionID = nil; model.statusPopoverDetail = "" })
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18), value: state.visibleMonth)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16), value: model.configuration.todos)
    }
    private func moveMonth(_ amount: Int) { if let date = calendar.date(byAdding: .month, value: amount, to: state.visibleMonth) { state.visibleMonth = date } }
    private func addTodo() { withAnimation(.easeOut(duration: 0.16)) { model.addTodo(on: state.selectedDate) } }
    private func removeTodo(_ index: Int) { withAnimation(.easeOut(duration: 0.14)) { guard model.configuration.todos.indices.contains(index) else { return }; model.configuration.todos.remove(at: index) } }
}

private struct ResourceUsagePopover: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var system: SystemMonitor
    private var palette: ThemePalette { model.configuration.bar.palette }
    init(model: AppModel) { self.model = model; self.system = model.system }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                summary("CPU", system.cpu, "cpu")
                summary("RAM", system.memory, "memorychip")
            }
            if system.appUsage.isEmpty {
                Text("Collecting application usage…").font(.caption).foregroundStyle(Color(hex: palette.muted)).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 5) {
                    HStack { Text("APPLICATION"); Spacer(); Text("CPU").frame(width: 52, alignment: .trailing); Text("RAM").frame(width: 72, alignment: .trailing) }
                        .font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(Color(hex: palette.muted)).padding(.horizontal, 7)
                    ForEach(Array(system.appUsage.prefix(8))) { app in
                        HStack(spacing: 9) {
                            Group {
                                if let icon = system.icon(for: app) { Image(nsImage: icon).resizable().scaledToFit() }
                                else { Text(String(app.name.prefix(1)).uppercased()).font(.caption.bold()).foregroundStyle(Color(hex: palette.accent)) }
                            }.frame(width: 28, height: 28).background(Color(hex: palette.accent).opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).font(.caption.weight(.semibold)).lineLimit(1)
                                GeometryReader { proxy in
                                    HStack(spacing: 2) {
                                        Capsule().fill(Color(hex: palette.accent)).frame(width: proxy.size.width * min(app.cpu / 100, 1))
                                        Spacer(minLength: 0)
                                    }
                                }.frame(height: 3).background(Color(hex: palette.muted).opacity(0.18)).clipShape(Capsule())
                            }
                            Text(String(format: "%.1f%%", app.cpu)).font(.caption2.monospacedDigit()).frame(width: 52, alignment: .trailing)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(ByteCountFormatter.string(fromByteCount: app.memoryBytes, countStyle: .memory)).font(.caption2.monospacedDigit())
                                Text(String(format: "%.1f%%", app.memory)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color(hex: palette.muted))
                            }.frame(width: 72, alignment: .trailing)
                        }.padding(.horizontal, 7).frame(height: 39).background(Color(hex: palette.surface).opacity(0.62)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(12).background(LinearGradient(colors: [Color(hex: palette.background), Color(hex: palette.surface).opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)).foregroundStyle(Color(hex: palette.foreground))
        .onAppear { system.refresh() }
    }
    private func summary(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) { Image(systemName: icon).foregroundStyle(Color(hex: palette.accent)); VStack(alignment: .leading, spacing: 1) { Text(title).font(.caption2).foregroundStyle(Color(hex: palette.muted)); Text(value).font(.headline.monospacedDigit()) }; Spacer() }.padding(10).frame(maxWidth: .infinity).background(Color(hex: palette.surface)).clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

private struct RightClickCapture: NSViewRepresentable {
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.install(view: view) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.action = action
        DispatchQueue.main.async { context.coordinator.install(view: view) }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator {
        var action: () -> Void
        weak var view: NSView?
        private var monitor: Any?
        init(action: @escaping () -> Void) { self.action = action }
        func install(view: NSView) {
            guard self.view !== view else { return }
            remove(); self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, let view = self.view, event.window === view.window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                DispatchQueue.main.async { self.action() }
                return nil
            }
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; view = nil }
    }
}

private struct OutsideClickDismissMonitor: NSViewRepresentable {
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.install(for: view.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.dismiss = dismiss
        DispatchQueue.main.async { context.coordinator.install(for: view.window) }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        var dismiss: () -> Void
        weak var hostWindow: NSWindow?
        private var localMonitor: Any?
        private var globalMonitor: Any?
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func install(for window: NSWindow?) {
            guard let window, hostWindow !== window else { return }
            remove(); hostWindow = window
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if event.window !== self?.hostWindow { DispatchQueue.main.async { self?.dismiss() } }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                DispatchQueue.main.async { self?.dismiss() }
            }
        }
        func remove() {
            if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
            hostWindow = nil
        }
    }
}

private struct WallpaperBarPopover: View {
    @ObservedObject var model: AppModel
    private var palette: ThemePalette { model.configuration.bar.palette }
    private var selected: Int { min(max(model.wallpaperSelectionIndex, 0), max(choices.count - 1, 0)) }
    private var choices: [URL] { Array(model.wallpapers.prefix(120)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if choices.isEmpty {
                VStack(spacing: 8) { Image(systemName: "photo.badge.plus").font(.title); Text("Add wallpaper folders in Ryft Settings").font(.caption) }.frame(maxWidth: .infinity, minHeight: 120).foregroundStyle(Color(hex: palette.muted))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 9) {
                            ForEach(Array(choices.enumerated()), id: \.element) { index, url in
                                WallpaperBarCard(url: url, selected: index == selected) { model.wallpaperFocusArea = 0; model.wallpaperSelectionIndex = index }.id(index)
                            }
                        }.padding(3)
                    }.onChange(of: model.wallpaperSelectionIndex) { _ in withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(selected, anchor: .center) } }
                }.frame(height: 118)
                HStack(spacing: 8) {
                    applyButton("Apply to desktop", icon: "desktopcomputer", index: 0) { model.wallpaperApplySelection = 0; apply(allDesktops: false) }
                    applyButton("Apply to all desktops", icon: "rectangle.3.group", index: 1) { model.wallpaperApplySelection = 1; apply(allDesktops: true) }
                }
            }
            WallpaperKeyboardCapture(left: { moveHorizontal(-1) }, right: { moveHorizontal(1) }, up: { model.wallpaperFocusArea = 0 }, down: { model.wallpaperFocusArea = 1 }, enter: { activateSelection() }).frame(width: 0, height: 0)
        }
        .padding(12)
        .background(LinearGradient(colors: [Color(hex: palette.background), Color(hex: palette.surface).opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(Color(hex: palette.foreground)).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(OutsideClickDismissMonitor { model.statusPopoverWidgetID = nil; model.statusPopoverInteractionID = nil; model.statusPopoverDetail = "" })
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: palette.muted).opacity(0.3)))
        .onAppear { model.wallpaperSelectionIndex = max(0, choices.firstIndex { $0.path == model.configuration.currentWallpaper } ?? 0); model.wallpaperFocusArea = 0; model.wallpaperApplySelection = 0 }
    }
    private func moveHorizontal(_ amount: Int) {
        if model.wallpaperFocusArea == 1 { model.wallpaperApplySelection = min(max(model.wallpaperApplySelection + amount, 0), 1) }
        else if !choices.isEmpty { model.wallpaperSelectionIndex = min(max(selected + amount, 0), choices.count - 1) }
    }
    private func activateSelection() { apply(allDesktops: model.wallpaperFocusArea == 1 && model.wallpaperApplySelection == 1) }
    private func apply(allDesktops: Bool) { guard choices.indices.contains(selected) else { return }; model.setWallpaper(choices[selected], allDesktops: allDesktops) }
    private func applyButton(_ title: String, icon: String, index: Int, action: @escaping () -> Void) -> some View {
        let focused = model.wallpaperFocusArea == 1 && model.wallpaperApplySelection == index
        return Button(action: action) { Label(title, systemImage: icon).font(.caption.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 34).background(index == 0 ? Color(hex: palette.accent) : Color(hex: palette.surface)).foregroundStyle(index == 0 ? Color(hex: palette.background) : Color(hex: palette.foreground)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Color.white : Color.clear, lineWidth: 2)) }.buttonStyle(SourcePressButtonStyle())
    }
}

private struct WallpaperBarCard: View {
    let url: URL
    let selected: Bool
    let action: () -> Void
    @StateObject private var thumbnail: WallpaperThumbnailLoader
    init(url: URL, selected: Bool, action: @escaping () -> Void) { self.url = url; self.selected = selected; self.action = action; _thumbnail = StateObject(wrappedValue: WallpaperThumbnailLoader(url: url, size: CGSize(width: 180, height: 110))) }
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let image = thumbnail.image { Image(nsImage: image).resizable().scaledToFill() } else { Color.black.opacity(0.18); Image(systemName: "photo").foregroundStyle(.white.opacity(0.45)) }
            }.frame(width: selected ? 166 : 150, height: selected ? 108 : 96).clipped().clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(selected ? 0.95 : 0.15), lineWidth: selected ? 3 : 1))
                .animation(.easeOut(duration: 0.16), value: selected)
        }.buttonStyle(SourcePressButtonStyle())
    }
}

private struct WallpaperKeyboardCapture: NSViewRepresentable {
    let left: () -> Void
    let right: () -> Void
    let up: () -> Void
    let down: () -> Void
    let enter: () -> Void
    func makeNSView(context: Context) -> WallpaperKeyView {
        let view = WallpaperKeyView(); view.left = left; view.right = right; view.up = up; view.down = down; view.enter = enter
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: WallpaperKeyView, context: Context) {
        view.left = left; view.right = right; view.up = up; view.down = down; view.enter = enter
        DispatchQueue.main.async { if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) } }
    }
}

private final class WallpaperKeyView: NSView {
    var left: () -> Void = {}
    var right: () -> Void = {}
    var up: () -> Void = {}
    var down: () -> Void = {}
    var enter: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { self.window?.makeFirstResponder(self) } }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode { case 123: left(); case 124: right(); case 126: up(); case 125: down(); case 36, 76: enter(); default: super.keyDown(with: event) }
    }
}

private struct StatusQuickPopover: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var controls: SystemControlService
    let detail: String
    private var palette: ThemePalette { model.configuration.bar.palette }
    init(model: AppModel, detail: String) { self.model = model; self.controls = model.controls; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if detail == "Battery" {
                    BatteryGaugeIcon(level: controls.batteryLevel, charging: controls.batteryCharging, color: iconColor, background: Color(hex: palette.surface))
                        .frame(width: 30, height: 26).background(Color(hex: palette.surface)).clipShape(Circle())
                } else {
                    Image(systemName: icon).foregroundStyle(iconColor).frame(width: 26, height: 26).background(Color(hex: palette.surface)).clipShape(Circle())
                }
                Text(detail == "Wi-Fi" && controls.connectedSSID != "Not connected" ? "WI-FI - \(controls.connectedSSID)" : detail).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1); Spacer()
            }
            Rectangle().fill(Color(hex: palette.muted).opacity(0.25)).frame(height: 1)
            if detail == "Wi-Fi" { wifiContent }
            else if detail == "Sound" { soundContent }
            else { batteryContent }
            if !controls.operationMessage.isEmpty { Text(controls.operationMessage).font(.caption).foregroundStyle(Color(hex: palette.muted)).lineLimit(2).transition(.opacity) }
        }
        .padding(16).background(Color(hex: palette.background)).foregroundStyle(Color(hex: palette.foreground))
        .background(OutsideClickDismissMonitor { model.statusPopoverWidgetID = nil; model.statusPopoverInteractionID = nil; model.statusPopoverDetail = "" })
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16), value: controls.operationMessage)
    }
    private var iconColor: Color {
        guard detail == "Battery" else { return Color(hex: palette.accent) }
        return controls.lowPowerMode ? .yellow : .white
    }
    private var icon: String { detail == "Wi-Fi" ? "wifi" : "speaker.wave.2.fill" }
    private var wifiContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Toggle("Wi-Fi", isOn: Binding(get: { controls.wifiEnabled }, set: controls.setWiFiEnabled)).toggleStyle(.switch).tint(Color(hex: palette.accent))
                Spacer(); Button { controls.requestWiFiAccessAndScan() } label: { if controls.scanningWiFi { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") } }.buttonStyle(.plain)
            }
            HStack {
                if controls.connectedSSID != "Not connected" { Button("Disconnect") { controls.disconnectWiFi() }.buttonStyle(QuickPopoverButtonStyle(palette: palette)) }
                Spacer()
                Button("Other Network…") { model.selectedWiFiID = model.selectedWiFiID == "__other__" ? "" : "__other__" }.buttonStyle(QuickPopoverButtonStyle(palette: palette))
            }
            if model.selectedWiFiID == "__other__" {
                VStack(spacing: 7) {
                    TextField("Network name", text: $model.wifiSSID).textFieldStyle(.plain)
                    SecureField("Password (if required)", text: $model.wifiPassword).textFieldStyle(.plain)
                    Button("Join Network") { controls.connectHiddenNetwork(ssid: model.wifiSSID, password: model.wifiPassword) }
                        .buttonStyle(QuickPopoverButtonStyle(palette: palette))
                        .disabled(model.wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(9).background(Color(hex: palette.surface)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if controls.wifiNetworks.isEmpty && !controls.scanningWiFi {
                Button("Review Location Access…") { WorkspaceController.openPrivacyPane("Privacy_LocationServices") }.buttonStyle(QuickPopoverButtonStyle(palette: palette))
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(controls.wifiNetworks) { network in
                        VStack(spacing: 6) {
                            Button {
                                model.selectedWiFiID = network.id; model.wifiPassword = ""
                                if !network.secure || network.known { controls.connect(to: network) }
                            } label: {
                                HStack {
                                    Image(systemName: network.signal > -55 ? "wifi" : network.signal > -72 ? "wifi" : "wifi.exclamationmark")
                                    Text(network.ssid).lineLimit(1)
                                    Spacer()
                                    if network.ssid == controls.connectedSSID { Image(systemName: "checkmark").foregroundStyle(Color(hex: palette.success)) }
                                    else if network.known { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Color(hex: palette.success)) }
                                    else if network.secure { Image(systemName: "lock.fill").font(.caption) }
                                }
                                    .padding(.horizontal, 10).frame(height: 34).background(Color(hex: palette.surface)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }.buttonStyle(SourcePressButtonStyle())
                            if model.selectedWiFiID == network.id && network.secure && !network.known {
                                HStack { SecureField("Password", text: $model.wifiPassword).textFieldStyle(.plain).onSubmit { controls.connect(to: network, password: model.wifiPassword) }; Button("Connect") { controls.connect(to: network, password: model.wifiPassword) }.buttonStyle(QuickPopoverButtonStyle(palette: palette)) }
                                    .padding(9).background(Color(hex: palette.surface)).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            }.frame(maxHeight: 245)
        }
    }
    private var soundContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "speaker.wave.2.fill"); Slider(value: Binding(get: { controls.outputVolume }, set: controls.setOutputVolume), in: 0...100).tint(Color(hex: palette.accent)); Text("\(Int(controls.outputVolume))%").monospacedDigit().frame(width: 38) }
            HStack { Button("Mute") { controls.setMuted(true) }; Button("Unmute") { controls.setMuted(false) }; Spacer() }.buttonStyle(QuickPopoverButtonStyle(palette: palette))
            if !controls.audioDevices.isEmpty {
                VStack(spacing: 5) {
                    ForEach(controls.audioDevices) { device in
                        Button { controls.selectAudioDevice(device.id) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: device.id == controls.defaultAudioDevice ? "checkmark.circle.fill" : "speaker.wave.2")
                                    .foregroundStyle(device.id == controls.defaultAudioDevice ? Color(hex: palette.accent) : Color(hex: palette.muted))
                                Text(device.name).lineLimit(1); Spacer()
                            }.padding(.horizontal, 10).frame(height: 34).background(Color(hex: palette.surface)).clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(SourcePressButtonStyle())
                    }
                }.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    private var batteryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { BatteryGaugeIcon(level: controls.batteryLevel, charging: controls.batteryCharging, color: iconColor, background: Color(hex: palette.background)).scaleEffect(1.35); Text(controls.batteryPercent).font(.title2.weight(.semibold)).monospacedDigit(); Spacer() }
            Toggle("Low Power Mode", isOn: Binding(get: { controls.lowPowerMode }, set: controls.setLowPowerMode)).toggleStyle(.switch).tint(Color(hex: palette.accent))
            if controls.supportsHighPowerMode {
                Toggle("High Power Mode", isOn: Binding(get: { controls.highPowerMode }, set: controls.setHighPowerMode)).toggleStyle(.switch).tint(Color(hex: palette.accent))
            }
            Text("Power changes never open System Settings or request a password.").font(.caption2).foregroundStyle(Color(hex: palette.muted))
        }
    }
}

private struct QuickPopoverButtonStyle: ButtonStyle {
    let palette: ThemePalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color(hex: configuration.isPressed ? palette.accent : palette.surface))
            .foregroundStyle(Color(hex: configuration.isPressed ? palette.background : palette.foreground))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct TrueBlackView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = CGColor(gray: 0, alpha: 1); view.layer?.isOpaque = true
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { view.layer?.backgroundColor = CGColor(gray: 0, alpha: 1); view.layer?.isOpaque = true }
}

struct SourcePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: reducedMotion ? 0 : 0.12), value: configuration.isPressed)
    }
}

private struct WidgetChrome: ViewModifier {
    let widget: WidgetConfiguration
    let palette: ThemePalette
    func body(content: Content) -> some View {
        content
            .font(.system(size: widget.fontSize, weight: .medium, design: .rounded))
            .padding(.horizontal, widget.style == .plain ? min(3, widget.horizontalPadding) : widget.horizontalPadding)
            .frame(height: 34)
            .background(widget.style == .pill ? Color(hex: widget.background ?? palette.surface) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: widget.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: widget.cornerRadius, style: .continuous).stroke(Color(hex: widget.foreground ?? palette.muted).opacity(0.45), lineWidth: widget.style == .outlined ? 1 : 0))
            .foregroundStyle(Color(hex: widget.foreground ?? palette.foreground))
    }
}

private struct ScriptWidgetLabel: View {
    let widget: WidgetConfiguration
    let palette: ThemePalette
    @ObservedObject private var runner: ScriptWidgetRunner
    init(widget: WidgetConfiguration, palette: ThemePalette) {
        self.widget = widget; self.palette = palette
        self.runner = ScriptWidgetRunner(command: widget.script, interval: widget.refreshInterval)
    }
    var body: some View {
        HStack(spacing: 6) {
            if widget.showIcon { WidgetIcon(value: widget.icon) }
            if widget.showLabel { Text(runner.output).lineLimit(1) }
        }
    }
}

struct WidgetIcon: View {
    let value: String
    var body: some View {
        if value.hasPrefix("text:") {
            Text(String(value.dropFirst(5))).lineLimit(1)
        } else if value.hasPrefix("bundle:"), let url = Bundle.module.url(forResource: String(value.dropFirst(7)), withExtension: nil), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 19.5, height: 19.5)
        } else if value.hasPrefix("/"), let image = NSImage(contentsOfFile: value) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
        } else {
            Image(systemName: value)
        }
    }
}

struct EditableBarCanvas: View {
    @ObservedObject var model: AppModel
    @Binding var selectedWidgetID: UUID?
    @Environment(\.displayScale) private var displayScale
    private var bar: BarConfiguration { model.configuration.bar }
    private var shelfHeight: CGFloat { DisplayLayoutMetrics.previewShelfHeight(bar) }
    private var thickness: CGFloat { DisplayLayoutMetrics.barThickness(bar, shelf: shelfHeight, scale: displayScale) }
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: model.configuration.bar.palette.muted).opacity(0.28), Color(hex: model.configuration.bar.palette.background).opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                BarView(model: model, notchWidth: (bar.reserveNotchSpace || bar.splitAroundNotch) && !bar.notchMaskEnabled ? min(180, proxy.size.width * 0.18) : 0, topReservedHeight: shelfHeight, editing: true) { selectedWidgetID = $0 }
                    .frame(width: bar.position.isVertical ? thickness : proxy.size.width, height: bar.position.isVertical ? nil : thickness)
                    .frame(maxWidth: .infinity, alignment: model.configuration.bar.position == .right ? .trailing : .leading)
                Text("Drag widgets directly on the bar. The center spacing previews notch avoidance without drawing the notch.")
                    .font(.caption).foregroundStyle(.white.opacity(0.82)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.5)).clipShape(Capsule()).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8)
            }
        }
        .frame(height: 122)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
    }
}

struct BarPreview: View {
    @ObservedObject var model: AppModel
    @Environment(\.displayScale) private var displayScale
    private var bar: BarConfiguration { model.configuration.bar }
    private var shelfHeight: CGFloat { DisplayLayoutMetrics.previewShelfHeight(bar) }
    private var thickness: CGFloat { DisplayLayoutMetrics.barThickness(bar, shelf: shelfHeight, scale: displayScale) }
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: model.configuration.bar.palette.muted).opacity(0.34), Color(hex: model.configuration.bar.palette.background).opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
                BarView(model: model, notchWidth: (bar.reserveNotchSpace || bar.splitAroundNotch) && !bar.notchMaskEnabled ? min(180, proxy.size.width * 0.18) : 0, topReservedHeight: shelfHeight)
                    .frame(width: bar.position.isVertical ? thickness : proxy.size.width, height: bar.position.isVertical ? nil : thickness)
                    .frame(maxWidth: .infinity, alignment: model.configuration.bar.position == .right ? .trailing : .leading)
            }
        }
        .frame(height: bar.position.isVertical ? 260 : max(86, thickness + 28))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
    }
}
