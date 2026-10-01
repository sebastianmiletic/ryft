import Foundation
import CoreGraphics

public enum PixelGrid {
    public static func round(_ value: CGFloat, scale: CGFloat) -> CGFloat { (value * max(1, scale)).rounded() / max(1, scale) }
    public static func ceil(_ value: CGFloat, scale: CGFloat) -> CGFloat { Foundation.ceil(value * max(1, scale)) / max(1, scale) }
    /// Round edges independently. CGRect.integral expands both edges and can
    /// introduce overlaps and one-point seams on a Retina display.
    public static func rect(_ value: CGRect, scale: CGFloat) -> CGRect {
        let x = round(value.minX, scale: scale), y = round(value.minY, scale: scale)
        return CGRect(x: x, y: y, width: max(0, round(value.maxX, scale: scale) - x), height: max(0, round(value.maxY, scale: scale) - y))
    }
}

public struct TopBarExtent {
    public let inset: CGFloat
    public let shelf: CGFloat
    public let height: CGFloat
    public let thickness: CGFloat
    public let coverHeight: CGFloat
    public init(height: CGFloat, outerInset: CGFloat, shelf: CGFloat, menuBarHeight: CGFloat, scale: CGFloat) {
        self.inset = PixelGrid.ceil(max(0, outerInset), scale: scale)
        self.shelf = PixelGrid.ceil(max(0, shelf), scale: scale)
        self.height = PixelGrid.ceil(max(1, height), scale: scale)
        // There is no trailing inset underneath the visual bottom of Waybar.
        thickness = self.shelf + self.inset + self.height
        // Very thin user-created bars still need to cover Apple's taller bar.
        coverHeight = max(thickness, PixelGrid.ceil(menuBarHeight, scale: scale))
    }
}
