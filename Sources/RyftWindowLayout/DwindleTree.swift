import Foundation
import CoreGraphics

/// Persistent BSP tree, using Hyprland's ratio convention: 1 = 50/50,
/// 0.1...1.9 = 5...95%. Coordinates are logical points, top-left origin.
public struct DwindleTree {
    public typealias WindowID = UInt32
    public enum Axis: Equatable { case leftRight, topBottom }
    public enum Placement { case cursor, before, after }
    public struct Options {
        public var preserveSplit = false
        public var widthMultiplier: CGFloat = 1
        public var defaultRatio: CGFloat = 1
        public var placement: Placement = .cursor
        public init() {}
    }
    public struct Split {
        public let id: UUID
        public let axis: Axis
        public let bounds: CGRect
        public let boundary: CGFloat
        public let first: Set<WindowID>
        public let second: Set<WindowID>
    }
    public struct Layout {
        public var frames: [WindowID: CGRect] = [:]
        public var cells: [WindowID: CGRect] = [:]
        public var splits: [Split] = []
        public init() {}
    }
    private indirect enum Node {
        case leaf(WindowID)
        case split(UUID, Axis, CGFloat, Node, Node)
        var windows: [WindowID] {
            switch self {
            case .leaf(let id): return [id]
            case .split(_, _, _, let first, let second): return first.windows + second.windows
            }
        }
    }
    private var root: Node?
    public var windows: [WindowID] { root?.windows ?? [] }
    public init() {}

    public mutating func insert(_ id: WindowID, nextTo preferred: WindowID?, in area: CGRect, cursor: CGPoint?, options: Options) {
        guard !windows.contains(id) else { return }
        guard let root else { self.root = .leaf(id); return }
        let current = layout(in: area, options: options)
        let target = preferred.flatMap { current.cells[$0] != nil ? $0 : nil }
            ?? closest(to: cursor ?? CGPoint(x: area.midX, y: area.midY), frames: current.cells)
            ?? windows.last!
        let bounds = current.cells[target] ?? area
        let axis: Axis = bounds.width > bounds.height * options.widthMultiplier ? .leftRight : .topBottom
        let newFirst: Bool
        switch options.placement {
        case .before: newFirst = true
        case .after: newFirst = false
        case .cursor:
            let point = cursor ?? CGPoint(x: bounds.maxX, y: bounds.maxY)
            newFirst = axis == .leftRight ? point.x < bounds.midX : point.y < bounds.midY
        }
        let ratio = min(1.9, max(0.1, options.defaultRatio))
        let replacement = Node.split(UUID(), axis, ratio, .leaf(newFirst ? id : target), .leaf(newFirst ? target : id))
        self.root = replaceLeaf(root, id: target, with: replacement)
    }

    public mutating func remove(_ id: WindowID) { root = removing(id, from: root) }

    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard a != b, windows.contains(a), windows.contains(b), let root else { return }
        self.root = mapLeaves(root) { $0 == a ? b : $0 == b ? a : $0 }
    }

    /// Missing/minimized leaves are projected out for layout, not deleted.
    /// Restoring them therefore restores their tree slot and split ratios.
    public func layout(in area: CGRect, active: Set<WindowID>? = nil, gap: CGFloat = 0, scale: CGFloat = 1, options: Options = Options(), minimums: [WindowID: CGSize] = [:]) -> Layout {
        var result = Layout()
        guard area.width > 0, area.height > 0, let root = projected(root, active: active) else { return result }
        let alignedArea = PixelGrid.rect(area, scale: scale)
        calculate(root, bounds: alignedArea, area: alignedArea, gap: max(0, gap), scale: scale, options: options, minimums: minimums, result: &result)
        return result
    }

    /// Adjust the actual ancestor separators touched by a native edge drag.
    /// Ratios belong to persistent branches, never count-based array indices.
    public mutating func resize(_ id: WindowID, from expected: CGRect, to actual: CGRect, layout: Layout) {
        guard let root else { return }
        let deltas: [(Axis, Bool, CGFloat)] = [
            (.leftRight, false, actual.minX - expected.minX), (.leftRight, true, actual.maxX - expected.maxX),
            (.topBottom, false, actual.minY - expected.minY), (.topBottom, true, actual.maxY - expected.maxY)
        ]
        var updates: [UUID: CGFloat] = [:]
        for (axis, trailing, delta) in deltas where abs(delta) > 3 {
            // Splits are in parent-before-child order. The deepest separator
            // bordering this edge is the one the user is actually resizing.
            guard let split = layout.splits.reversed().first(where: { split in
                guard split.axis == axis else { return false }
                let member = trailing ? split.first.contains(id) : split.second.contains(id)
                let edge = axis == .leftRight ? (trailing ? expected.maxX : expected.minX) : (trailing ? expected.maxY : expected.minY)
                return member && abs(edge - split.boundary) <= 24
            }) else { continue }
            let origin = axis == .leftRight ? split.bounds.minX : split.bounds.minY
            let length = axis == .leftRight ? split.bounds.width : split.bounds.height
            guard length > 1 else { continue }
            updates[split.id] = min(1.9, max(0.1, (split.boundary + delta - origin) * 2 / length))
        }
        self.root = updatingRatios(root, values: updates)
    }

    public static func balanced(ids: [WindowID], in area: CGRect, gap: CGFloat, scale: CGFloat) -> Layout {
        var result = Layout()
        guard !ids.isEmpty, area.width > 0, area.height > 0 else { return result }
        let area = PixelGrid.rect(area, scale: scale)
        let columns = max(1, Int(ceil(sqrt(Double(ids.count)))))
        let rows = (ids.count + columns - 1) / columns
        let rowHeight = area.height / CGFloat(rows)
        var index = 0
        for row in 0..<rows {
            let count = min(columns, ids.count - index)
            let width = area.width / CGFloat(count)
            for column in 0..<count {
                let cell = CGRect(x: area.minX + CGFloat(column) * width, y: area.minY + CGFloat(row) * rowHeight, width: width, height: rowHeight)
                let id = ids[index]; index += 1
                result.cells[id] = PixelGrid.rect(cell, scale: scale)
                result.frames[id] = gapped(cell, area: area, gap: gap, scale: scale)
            }
        }
        return result
    }

    private func calculate(_ node: Node, bounds: CGRect, area: CGRect, gap: CGFloat, scale: CGFloat, options: Options, minimums: [WindowID: CGSize], result: inout Layout) {
        switch node {
        case .leaf(let id):
            result.cells[id] = bounds
            result.frames[id] = Self.gapped(bounds, area: area, gap: gap, scale: scale)
        case .split(let id, let savedAxis, let ratio, let first, let second):
            let axis = options.preserveSplit ? savedAxis : (bounds.width > bounds.height * options.widthMultiplier ? .leftRight : .topBottom)
            let length = axis == .leftRight ? bounds.width : bounds.height
            var provisionalA = bounds, provisionalB = bounds
            if axis == .leftRight {
                provisionalA.size.width *= ratio / 2
                provisionalB.origin.x += provisionalA.width; provisionalB.size.width -= provisionalA.width
            } else {
                provisionalA.size.height *= ratio / 2
                provisionalB.origin.y += provisionalA.height; provisionalB.size.height -= provisionalA.height
            }
            let firstMin = minimumSize(first, options: options, bounds: provisionalA, area: area, gap: gap, minimums: minimums)
            let secondMin = minimumSize(second, options: options, bounds: provisionalB, area: area, gap: gap, minimums: minimums)
            let minimumFirst = axis == .leftRight ? firstMin.width : firstMin.height
            let minimumSecond = axis == .leftRight ? secondMin.width : secondMin.height
            var firstLength = length * min(1.9, max(0.1, ratio)) / 2
            if minimumFirst + minimumSecond <= length {
                firstLength = max(minimumFirst, min(length - minimumSecond, firstLength))
            }
            let origin = axis == .leftRight ? bounds.minX : bounds.minY
            let boundary = PixelGrid.round(origin + firstLength, scale: scale)
            let a: CGRect, b: CGRect
            if axis == .leftRight {
                a = CGRect(x: bounds.minX, y: bounds.minY, width: boundary - bounds.minX, height: bounds.height)
                b = CGRect(x: boundary, y: bounds.minY, width: bounds.maxX - boundary, height: bounds.height)
            } else {
                a = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: boundary - bounds.minY)
                b = CGRect(x: bounds.minX, y: boundary, width: bounds.width, height: bounds.maxY - boundary)
            }
            result.splits.append(Split(id: id, axis: axis, bounds: bounds, boundary: boundary, first: Set(first.windows), second: Set(second.windows)))
            calculate(first, bounds: a, area: area, gap: gap, scale: scale, options: options, minimums: minimums, result: &result)
            calculate(second, bounds: b, area: area, gap: gap, scale: scale, options: options, minimums: minimums, result: &result)
        }
    }

    private func minimumSize(_ node: Node, options: Options, bounds: CGRect, area: CGRect, gap: CGFloat, minimums: [WindowID: CGSize]) -> CGSize {
        switch node {
        case .leaf(let id):
            let size = minimums[id] ?? CGSize(width: 1, height: 1)
            let horizontal = (abs(bounds.minX - area.minX) < 0.01 ? 0 : gap / 2) + (abs(bounds.maxX - area.maxX) < 0.01 ? 0 : gap / 2)
            let vertical = (abs(bounds.minY - area.minY) < 0.01 ? 0 : gap / 2) + (abs(bounds.maxY - area.maxY) < 0.01 ? 0 : gap / 2)
            return CGSize(width: size.width + horizontal, height: size.height + vertical)
        case .split(_, let savedAxis, let ratio, let first, let second):
            let axis = options.preserveSplit ? savedAxis : (bounds.width > bounds.height * options.widthMultiplier ? .leftRight : .topBottom)
            var a = bounds, b = bounds
            if axis == .leftRight { a.size.width *= ratio / 2; b.origin.x += a.width; b.size.width -= a.width }
            else { a.size.height *= ratio / 2; b.origin.y += a.height; b.size.height -= a.height }
            let m = minimumSize(first, options: options, bounds: a, area: area, gap: gap, minimums: minimums)
            let n = minimumSize(second, options: options, bounds: b, area: area, gap: gap, minimums: minimums)
            return axis == .leftRight ? CGSize(width: m.width + n.width, height: max(m.height, n.height)) : CGSize(width: max(m.width, n.width), height: m.height + n.height)
        }
    }

    private static func gapped(_ bounds: CGRect, area: CGRect, gap: CGFloat, scale: CGFloat) -> CGRect {
        let left = abs(bounds.minX - area.minX) < 0.01 ? 0 : gap / 2
        let top = abs(bounds.minY - area.minY) < 0.01 ? 0 : gap / 2
        let right = abs(bounds.maxX - area.maxX) < 0.01 ? 0 : gap / 2
        let bottom = abs(bounds.maxY - area.maxY) < 0.01 ? 0 : gap / 2
        return PixelGrid.rect(CGRect(x: bounds.minX + left, y: bounds.minY + top, width: max(1, bounds.width - left - right), height: max(1, bounds.height - top - bottom)), scale: scale)
    }
    private func closest(to point: CGPoint, frames: [WindowID: CGRect]) -> WindowID? {
        frames.keys.sorted().min { a, b in
            func distance(_ r: CGRect) -> CGFloat {
                let dx = max(r.minX - point.x, 0, point.x - r.maxX)
                let dy = max(r.minY - point.y, 0, point.y - r.maxY)
                return dx * dx + dy * dy
            }
            return distance(frames[a]!) < distance(frames[b]!)
        }
    }
    private func replaceLeaf(_ node: Node, id: WindowID, with replacement: Node) -> Node {
        switch node {
        case .leaf(let value): return value == id ? replacement : node
        case .split(let key, let axis, let ratio, let a, let b): return .split(key, axis, ratio, replaceLeaf(a, id: id, with: replacement), replaceLeaf(b, id: id, with: replacement))
        }
    }
    private func removing(_ id: WindowID, from node: Node?) -> Node? {
        guard let node else { return nil }
        switch node {
        case .leaf(let value): return value == id ? nil : node
        case .split(let key, let axis, let ratio, let a, let b):
            let first = removing(id, from: a), second = removing(id, from: b)
            if let first, let second { return .split(key, axis, ratio, first, second) }
            return first ?? second
        }
    }
    private func projected(_ node: Node?, active: Set<WindowID>?) -> Node? {
        guard let node else { return nil }
        guard let active else { return node }
        switch node {
        case .leaf(let id): return active.contains(id) ? node : nil
        case .split(let key, let axis, let ratio, let a, let b):
            let first = projected(a, active: active), second = projected(b, active: active)
            if let first, let second { return .split(key, axis, ratio, first, second) }
            return first ?? second
        }
    }
    private func mapLeaves(_ node: Node, transform: (WindowID) -> WindowID) -> Node {
        switch node {
        case .leaf(let id): return .leaf(transform(id))
        case .split(let key, let axis, let ratio, let a, let b): return .split(key, axis, ratio, mapLeaves(a, transform: transform), mapLeaves(b, transform: transform))
        }
    }
    private func updatingRatios(_ node: Node, values: [UUID: CGFloat]) -> Node {
        switch node {
        case .leaf: return node
        case .split(let key, let axis, let ratio, let a, let b): return .split(key, axis, values[key] ?? ratio, updatingRatios(a, values: values), updatingRatios(b, values: values))
        }
    }
}
