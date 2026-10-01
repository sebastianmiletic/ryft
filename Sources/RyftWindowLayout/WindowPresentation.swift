import Foundation
import CoreGraphics

/// Native zoom is a finite transition, not a size heuristic. A full-sized tile
/// can never accidentally disable tiling. No scheduled closure outlives a Space
/// change, a removed window, a quick restore, or disabling the engine.
public struct WindowPresentation {
    public enum Decision: Equatable { case tile, waitForNative, maximize, restoreTile, nativeFullscreen }
    private enum Phase {
        case tiled
        case opening(baseline: CGRect, until: TimeInterval)
        case maximized
        case restoring(until: TimeInterval)
    }
    private var phase: Phase = .tiled
    public var isNormal: Bool { if case .tiled = phase { return true }; return false }
    public init() {}

    public mutating func titleBarDoubleClick(frame: CGRect, now: TimeInterval) {
        switch phase {
        case .tiled: phase = .opening(baseline: frame, until: now + 0.35)
        case .opening, .maximized: phase = .restoring(until: now + 0.35)
        case .restoring: break
        }
    }
    public mutating func restore(now: TimeInterval) { phase = .restoring(until: now) }
    public mutating func observe(frame: CGRect, nativeFullscreen: Bool, now: TimeInterval, pointerDown: Bool) -> Decision {
        if nativeFullscreen { return .nativeFullscreen }
        switch phase {
        case .tiled: return .tile
        case .opening(let baseline, let until):
            if pointerDown || now < until { return .waitForNative }
            // Respect macOS's "Do nothing"/minimize preference and ignore a
            // double-click on tabs or content that did not actually zoom.
            let resized = max(abs(frame.width - baseline.width), abs(frame.height - baseline.height)) > 8
            phase = resized ? .maximized : .tiled
            return resized ? .maximize : .tile
        case .maximized: return .maximize
        case .restoring(let until):
            if pointerDown || now < until { return .waitForNative }
            phase = .tiled
            return .restoreTile
        }
    }
}
