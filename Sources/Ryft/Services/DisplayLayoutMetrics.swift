import AppKit
import RyftWindowLayout

/// The bar, wallpaper covers and tiler share these pixel-aligned boundaries.
/// Native menu-bar measurements are cached before Ryft hides Apple's bar.
enum DisplayLayoutMetrics {
    private static var menuBarHeights: [CGDirectDisplayID: CGFloat] = [:]

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        let id = displayID(for: screen)
        let observed = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        if observed >= 1 {
            let value = min(observed, 64)
            menuBarHeights[id] = value
            return value
        }
        return menuBarHeights[id] ?? min(64, max(NSStatusBar.system.thickness, screen.safeAreaInsets.top))
    }
    static func notchShelfHeight(for screen: NSScreen, bar: BarConfiguration) -> CGFloat {
        guard bar.position == .top, bar.notchMaskEnabled else { return 0 }
        let height = bar.notchMaskHeight > 0 ? bar.notchMaskHeight : ((screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil) ? max(screen.safeAreaInsets.top, 32) : 0)
        return PixelGrid.ceil(height, scale: screen.backingScaleFactor)
    }
    static func topExtent(for screen: NSScreen, bar: BarConfiguration) -> TopBarExtent {
        TopBarExtent(height: bar.height, outerInset: bar.presentation == .top ? 0 : bar.outerInset, shelf: notchShelfHeight(for: screen, bar: bar), menuBarHeight: menuBarHeight(for: screen), scale: screen.backingScaleFactor)
    }
    static func barThickness(_ bar: BarConfiguration, shelf: CGFloat = 0, scale: CGFloat) -> CGFloat {
        if bar.position == .top {
            return TopBarExtent(height: bar.height, outerInset: bar.presentation == .top ? 0 : bar.outerInset, shelf: shelf, menuBarHeight: 0, scale: scale).thickness
        }
        return PixelGrid.ceil(bar.height + (bar.presentation == .top ? 0 : bar.outerInset * 2), scale: scale)
    }
    static func previewShelfHeight(_ bar: BarConfiguration) -> CGFloat {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return 0 }
        return notchShelfHeight(for: screen, bar: bar)
    }
    static func barFrame(for screen: NSScreen, bar: BarConfiguration) -> CGRect {
        let scale = screen.backingScaleFactor
        let thickness = barThickness(bar, shelf: notchShelfHeight(for: screen, bar: bar), scale: scale)
        let frame: CGRect
        switch bar.position {
        case .top: frame = CGRect(x: screen.frame.minX, y: screen.frame.maxY - thickness, width: screen.frame.width, height: thickness)
        case .bottom: frame = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: thickness)
        case .left: frame = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: thickness, height: screen.frame.height)
        case .right: frame = CGRect(x: screen.frame.maxX - thickness, y: screen.frame.minY, width: thickness, height: screen.frame.height)
        }
        return PixelGrid.rect(frame, scale: scale)
    }
    static func menuBarCoverFrame(for screen: NSScreen, bar: BarConfiguration) -> CGRect {
        let height = bar.position == .top ? topExtent(for: screen, bar: bar).coverHeight : PixelGrid.ceil(menuBarHeight(for: screen), scale: screen.backingScaleFactor)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }
    static func quartzFrame(_ frame: CGRect) -> CGRect {
        // NSScreen's primary display is first. NSScreen.main follows keyboard
        // focus and is not a safe coordinate origin on multiple displays.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }
    static func workArea(for screen: NSScreen, bar: BarConfiguration, outerGap: CGFloat) -> CGRect {
        let display = quartzFrame(screen.frame)
        let dockHidden = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        var work = dockHidden ? display : quartzFrame(screen.visibleFrame).intersection(display)
        guard !work.isNull else { return display }
        if bar.enabled && (bar.showOnAllDisplays || screen == NSScreen.screens.first) {
            let cover = quartzFrame(menuBarCoverFrame(for: screen, bar: bar))
            let top = max(work.minY, cover.maxY)
            work = CGRect(x: work.minX, y: top, width: work.width, height: max(1, work.maxY - top))
            let barRect = quartzFrame(barFrame(for: screen, bar: bar))
            switch bar.position {
            case .top: break // cover and bar have exactly the same lower edge
            case .bottom: work.size.height = max(1, min(work.maxY, barRect.minY) - work.minY)
            case .left:
                let left = max(work.minX, barRect.maxX)
                work = CGRect(x: left, y: work.minY, width: max(1, work.maxX - left), height: work.height)
            case .right: work.size.width = max(1, min(work.maxX, barRect.minX) - work.minX)
            }
        }
        let gap = min(40, max(0, outerGap))
        return PixelGrid.rect(work.insetBy(dx: min(gap, work.width / 4), dy: min(gap, work.height / 4)), scale: screen.backingScaleFactor)
    }
}
