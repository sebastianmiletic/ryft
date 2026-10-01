import CoreGraphics

/// Some Cocoa/Chromium windows round half-point AX coordinates to whole points.
/// Remember the actual assigned tile so native zoom restores that exact frame,
/// not a subtly different rounding of the same mathematical layout rectangle.
public struct NativeTileMemory {
    public struct Slot {
        public let requested: CGRect
        public let actual: CGRect
    }
    private var slots: [UInt32: Slot] = [:]
    public init() {}
    public mutating func record(_ id: UInt32, requested: CGRect, actual: CGRect, tolerance: CGFloat = 0.55) {
        let delta = max(abs(actual.minX - requested.minX), abs(actual.minY - requested.minY), abs(actual.width - requested.width), abs(actual.height - requested.height))
        guard delta <= tolerance else { return }
        slots[id] = Slot(requested: requested, actual: actual)
    }
    public func resolve(_ id: UInt32, requested: CGRect) -> CGRect {
        guard let slot = slots[id], slot.requested == requested else { return requested }
        return slot.actual
    }
    public mutating func retain(_ existing: Set<UInt32>) { slots = slots.filter { existing.contains($0.key) } }
}
