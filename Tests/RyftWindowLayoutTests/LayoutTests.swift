import CoreGraphics
#if RYFT_STANDALONE_TESTS
import Foundation
#else
import XCTest
@testable import RyftWindowLayout
#endif

final class LayoutTests: XCTestCase {
    let landscape = CGRect(x: 0, y: 46, width: 1600, height: 900)
    var options: DwindleTree.Options {
        var options = DwindleTree.Options(); options.placement = .after; return options
    }
    func tree(_ ids: [UInt32]) -> DwindleTree {
        var result = DwindleTree()
        for (index, id) in ids.enumerated() { result.insert(id, nextTo: index > 0 ? ids[index - 1] : nil, in: landscape, cursor: nil, options: options) }
        return result
    }
    func testSingleWindowFillsWorkArea() {
        XCTAssertEqual(tree([1]).layout(in: landscape).frames[1], landscape)
    }
    func testTwoWindowsAreLeftAndRightOnLandscapeDisplay() {
        let layout = tree([1, 2]).layout(in: landscape, gap: 10, scale: 2, options: options)
        XCTAssertEqual(layout.frames[1], CGRect(x: 0, y: 46, width: 795, height: 900))
        XCTAssertEqual(layout.frames[2], CGRect(x: 805, y: 46, width: 795, height: 900))
        XCTAssertEqual(layout.splits.first?.axis, .leftRight)
    }
    func testThirdWindowSplitsFocusedLeafNotAlwaysRemainder() {
        var tree = tree([1, 2])
        let before = tree.layout(in: landscape, options: options)
        tree.insert(3, nextTo: 1, in: landscape, cursor: nil, options: options)
        let after = tree.layout(in: landscape, options: options)
        XCTAssertEqual(before.frames[2], after.frames[2])
        XCTAssertEqual(after.frames[1]?.width, 800)
        XCTAssertEqual(after.frames[1]?.height, 450)
        XCTAssertEqual(after.frames[3]?.minY, 496)
    }
    func testRemovalPromotesSiblingWithoutRebuildingTree() {
        var tree = tree([1, 2, 3])
        tree.remove(3)
        let layout = tree.layout(in: landscape, options: options)
        XCTAssertEqual(layout.frames, self.tree([1, 2]).layout(in: landscape, options: options).frames)
        tree.remove(1)
        XCTAssertEqual(tree.layout(in: landscape).frames[2], landscape)
    }
    func testMinimizeProjectionRestoresExactSlot() {
        let tree = tree([1, 2, 3])
        let all = tree.layout(in: landscape, gap: 10, options: options)
        let projected = tree.layout(in: landscape, active: [1, 2], gap: 10, options: options)
        XCTAssertEqual(projected.frames.count, 2)
        XCTAssertEqual(tree.windows.count, 3)
        XCTAssertEqual(all.frames, tree.layout(in: landscape, active: [1, 2, 3], gap: 10, options: options).frames)
    }
    func testSwapPreservesGeometryAndBranchRatios() {
        var tree = tree([1, 2, 3])
        let before = tree.layout(in: landscape, options: options)
        tree.swap(1, 3)
        let after = tree.layout(in: landscape, options: options)
        XCTAssertEqual(after.frames[1], before.frames[3]); XCTAssertEqual(after.frames[3], before.frames[1])
        XCTAssertEqual(after.frames[2], before.frames[2])
        XCTAssertEqual(after.splits.map(\.id), before.splits.map(\.id))
    }
    func testResizeUpdatesPersistentBranchAndKeepsGap() {
        var tree = tree([1, 2])
        let layout = tree.layout(in: landscape, gap: 10, options: options)
        let frame = layout.frames[1]!
        var resized = frame; resized.size.width += 120
        tree.resize(1, from: frame, to: resized, layout: layout)
        let after = tree.layout(in: landscape, gap: 10, options: options)
        XCTAssertEqual(after.frames[1]!.width, frame.width + 120)
        XCTAssertEqual(after.frames[2]!.minX - after.frames[1]!.maxX, 10)
        XCTAssertEqual(after.frames[2]!.maxX, landscape.maxX)
    }
    func testTreesAreValueIsolatedAcrossSpaces() {
        var spaceOne = tree([1, 2]); let spaceTwo = spaceOne
        let before = spaceOne.layout(in: landscape, options: options)
        var resized = before.frames[1]!; resized.size.width += 120
        spaceOne.resize(1, from: before.frames[1]!, to: resized, layout: before)
        XCTAssertEqual(spaceTwo.layout(in: landscape, options: options).frames, before.frames)
        XCTAssertNotEqual(spaceOne.layout(in: landscape, options: options).frames, before.frames)
    }
    func testHyprlandAutomaticAndPreservedSplitDirections() {
        let tree = tree([1, 2])
        let portrait = CGRect(x: 0, y: 0, width: 900, height: 1600)
        XCTAssertEqual(tree.layout(in: portrait, options: options).splits.first?.axis, .topBottom)
        var preserve = options; preserve.preserveSplit = true
        XCTAssertEqual(tree.layout(in: portrait, options: preserve).splits.first?.axis, .leftRight)
    }
    func testHyprlandRatioConventionAndBounds() {
        var options = self.options; options.defaultRatio = 1.2
        var tree = DwindleTree()
        tree.insert(1, nextTo: nil, in: landscape, cursor: nil, options: options)
        tree.insert(2, nextTo: 1, in: landscape, cursor: nil, options: options)
        XCTAssertEqual(tree.layout(in: landscape, options: options).frames[1]?.width, 960)
    }
    func testCursorChoosesChildOrder() {
        var options = self.options; options.placement = .cursor
        var tree = DwindleTree()
        tree.insert(1, nextTo: nil, in: landscape, cursor: nil, options: options)
        tree.insert(2, nextTo: 1, in: landscape, cursor: CGPoint(x: 10, y: 100), options: options)
        XCTAssertEqual(tree.windows, [2, 1])
    }
    func testMinimumSizeConstrainsDivider() {
        var options = self.options; options.defaultRatio = 0.2
        var tree = DwindleTree()
        tree.insert(1, nextTo: nil, in: landscape, cursor: nil, options: options)
        tree.insert(2, nextTo: 1, in: landscape, cursor: nil, options: options)
        let layout = tree.layout(in: landscape, gap: 10, options: options, minimums: [1: CGSize(width: 450, height: 200), 2: CGSize(width: 450, height: 200)])
        XCTAssertGreaterThanOrEqual(layout.frames[1]!.width, 450)
        XCTAssertEqual(layout.frames[2]!.minX - layout.frames[1]!.maxX, 10)
    }
    func testManyInsertionRemovalCyclesNeverOverlapOrDuplicateIDs() {
        for scale: CGFloat in [1, 2] {
            var tree = DwindleTree()
            let area = CGRect(x: -1800.5, y: -960.5, width: 3600.5, height: 2200.5)
            for id: UInt32 in 1...12 {
                let anchor = tree.windows.first
                tree.insert(id, nextTo: anchor, in: area, cursor: nil, options: options)
                check(tree.layout(in: area, gap: 9, scale: scale, options: options), area: area, scale: scale)
            }
            for id: UInt32 in [4, 8, 2, 7, 1, 12, 5, 3, 9, 6, 11, 10] {
                tree.remove(id)
                check(tree.layout(in: area, gap: 9, scale: scale, options: options), area: area, scale: scale)
            }
            XCTAssertTrue(tree.windows.isEmpty)
        }
    }
    func testFractionalWorkAreaHasNoAccidentalOuterPadding() {
        let area = CGRect(x: -1800.5, y: 46.5, width: 1600.5, height: 900.5)
        XCTAssertEqual(tree([1]).layout(in: area, gap: 10, scale: 1).frames[1], PixelGrid.rect(area, scale: 1))
        XCTAssertEqual(DwindleTree.balanced(ids: [1], in: area, gap: 10, scale: 1).frames[1], PixelGrid.rect(area, scale: 1))
    }
    func testNestedMinimumSizesIncludeBothInteriorMargins() {
        var options = self.options; options.defaultRatio = 1.8; options.preserveSplit = true
        var tree = DwindleTree()
        tree.insert(1, nextTo: nil, in: landscape, cursor: nil, options: options)
        tree.insert(2, nextTo: 1, in: landscape, cursor: nil, options: options)
        tree.insert(3, nextTo: 2, in: landscape, cursor: nil, options: options)
        let sizes: [UInt32: CGSize] = [1: CGSize(width: 400, height: 300), 2: CGSize(width: 450, height: 200), 3: CGSize(width: 450, height: 200)]
        let layout = tree.layout(in: landscape, gap: 10, scale: 2, options: options, minimums: sizes)
        for (id, size) in sizes {
            XCTAssertGreaterThanOrEqual(layout.frames[id]!.width, size.width)
            XCTAssertGreaterThanOrEqual(layout.frames[id]!.height, size.height)
        }
    }
    func testBalancedAlternativeStillHasExactGaps() {
        let layout = DwindleTree.balanced(ids: [1, 2, 3], in: landscape, gap: 10, scale: 2)
        XCTAssertEqual(layout.frames[1]!.height, 445)
        XCTAssertEqual(layout.frames[3]!.width, 1600)
        XCTAssertEqual(layout.frames[3]!.minY - layout.frames[1]!.maxY, 10)
    }
    private func check(_ layout: DwindleTree.Layout, area: CGRect, scale: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let frames = Array(layout.frames.values)
        for (index, frame) in frames.enumerated() {
            XCTAssertGreaterThan(frame.width, 0, file: file, line: line); XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
            XCTAssertTrue(PixelGrid.rect(area, scale: scale).contains(frame), file: file, line: line)
            for value in [frame.minX, frame.minY, frame.maxX, frame.maxY] { XCTAssertEqual(value * scale, (value * scale).rounded(), accuracy: 0.001, file: file, line: line) }
            for other in frames.dropFirst(index + 1) { let intersection = frame.intersection(other); XCTAssertTrue(intersection.isNull || intersection.width == 0 || intersection.height == 0, file: file, line: line) }
        }
    }
}

final class PresentationTests: XCTestCase {
    let tile = CGRect(x: 10, y: 50, width: 700, height: 850)
    let full = CGRect(x: 10, y: 50, width: 1410, height: 850)
    func testNativeZoomThenRestoreDoesNotResuspend() {
        var mode = WindowPresentation()
        mode.titleBarDoubleClick(frame: tile, now: 1)
        XCTAssertEqual(mode.observe(frame: tile, nativeFullscreen: false, now: 1.2, pointerDown: false), .waitForNative)
        XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: false, now: 1.5, pointerDown: false), .maximize)
        mode.titleBarDoubleClick(frame: full, now: 2)
        XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: false, now: 2.2, pointerDown: false), .waitForNative)
        XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: false, now: 2.5, pointerDown: false), .restoreTile)
        XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: false, now: 2.6, pointerDown: false), .tile)
        XCTAssertEqual(mode.observe(frame: tile, nativeFullscreen: false, now: 3, pointerDown: false), .tile)
    }
    func testLargeNormalWindowCannotBeMisclassifiedAsZoomed() {
        var mode = WindowPresentation()
        XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: false, now: 5, pointerDown: false), .tile)
    }
    func testNoNativeZoomMeansNoHijackedDoubleClick() {
        var mode = WindowPresentation(); mode.titleBarDoubleClick(frame: tile, now: 1)
        XCTAssertEqual(mode.observe(frame: tile, nativeFullscreen: false, now: 2, pointerDown: false), .tile)
        XCTAssertTrue(mode.isNormal)
    }
    func testRapidDoubleClickCycleReturnsToTile() {
        var mode = WindowPresentation()
        mode.titleBarDoubleClick(frame: tile, now: 1)
        mode.titleBarDoubleClick(frame: full, now: 1.15)
        XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: false, now: 1.6, pointerDown: false), .restoreTile)
    }
    func testFullscreenNeverReturnsAFrameWriteDecision() {
        var mode = WindowPresentation(); mode.titleBarDoubleClick(frame: tile, now: 1)
        XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: true, now: 2, pointerDown: false), .nativeFullscreen)
    }
    func testRepeatedNativeZoomCyclesNeverLeaveStaleSuspension() {
        var mode = WindowPresentation()
        for cycle in 0..<200 {
            let now = Double(cycle) * 2
            mode.titleBarDoubleClick(frame: tile, now: now)
            XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: false, now: now + 0.5, pointerDown: false), .maximize)
            mode.titleBarDoubleClick(frame: full, now: now + 1)
            XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: false, now: now + 1.5, pointerDown: false), .restoreTile)
            XCTAssertTrue(mode.isNormal)
        }
    }
    func testPointerHoldCannotRaceNativeResize() {
        var mode = WindowPresentation(); mode.titleBarDoubleClick(frame: tile, now: 1)
        XCTAssertEqual(mode.observe(frame: full, nativeFullscreen: false, now: 4, pointerDown: true), .waitForNative)
    }
}

final class NativeTileTests: XCTestCase {
    let requested = CGRect(x: 2.5, y: 48.5, width: 727.5, height: 447.5)
    let native = CGRect(x: 2, y: 49, width: 728, height: 447)
    func testZoomRestoresActualAssignedFrameNotAnotherRounding() {
        var memory = NativeTileMemory()
        memory.record(1, requested: requested, actual: native)
        for _ in 0..<200 { XCTAssertEqual(memory.resolve(1, requested: requested), native) }
    }
    func testGeometryChangeInvalidatesOldNativeSlot() {
        var memory = NativeTileMemory()
        memory.record(1, requested: requested, actual: native)
        let changed = requested.offsetBy(dx: 200, dy: 0)
        XCTAssertEqual(memory.resolve(1, requested: changed), changed)
    }
    func testRejectedSizeAndClosedWindowCannotReuseStaleSlot() {
        var memory = NativeTileMemory()
        memory.record(1, requested: requested, actual: native)
        var rejected = requested; rejected.size.width += 300
        memory.record(1, requested: requested, actual: rejected)
        XCTAssertEqual(memory.resolve(1, requested: requested), native)
        memory.retain([])
        XCTAssertEqual(memory.resolve(1, requested: requested), requested)
    }
}

final class BarExtentTests: XCTestCase {
    func testFloatingCoverEndsAtWaybarBottomWithoutTrailingPadding() {
        let extent = TopBarExtent(height: 40, outerInset: 6, shelf: 0, menuBarHeight: 33, scale: 2)
        XCTAssertEqual(extent.thickness, 46); XCTAssertEqual(extent.coverHeight, 46)
        XCTAssertEqual(extent.thickness, extent.inset + extent.height)
    }
    func testFractionalSettingsAlignToPhysicalPixels() {
        let extent = TopBarExtent(height: 39.2, outerInset: 5.1, shelf: 32.1, menuBarHeight: 33, scale: 2)
        XCTAssertEqual(extent.height, 39.5); XCTAssertEqual(extent.inset, 5.5); XCTAssertEqual(extent.shelf, 32.5)
        XCTAssertEqual(extent.coverHeight, extent.thickness)
    }
    func testFlushAndUnusuallyThinBarsStillHideNativeMenuBar() {
        XCTAssertEqual(TopBarExtent(height: 40, outerInset: 0, shelf: 0, menuBarHeight: 33, scale: 1).coverHeight, 40)
        XCTAssertEqual(TopBarExtent(height: 24, outerInset: 0, shelf: 0, menuBarHeight: 33, scale: 2).coverHeight, 33)
    }
}
