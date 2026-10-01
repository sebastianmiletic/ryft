// CommandLineTools-only XCTest-compatible runner. The same test cases run
// through XCTest with `swift test` on machines with a complete Xcode install.
import Foundation
import CoreGraphics

class XCTestCase {}
private var failures = 0
private func failure(_ message: String, file: StaticString, line: UInt) {
    failures += 1; print("FAIL \(file):\(line): \(message)")
}
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { failure("Expected true", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a != b { failure("\(a) != \(b)", file: file, line: line) }
}
func XCTAssertEqual(_ a: CGFloat, _ b: CGFloat, accuracy: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    if abs(a - b) > accuracy { failure("\(a) != \(b) ± \(accuracy)", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a == b { failure("Expected different values", file: file, line: line) }
}
func XCTAssertGreaterThan(_ a: CGFloat, _ b: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    if a <= b { failure("\(a) <= \(b)", file: file, line: line) }
}
func XCTAssertGreaterThanOrEqual(_ a: CGFloat, _ b: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    if a < b { failure("\(a) < \(b)", file: file, line: line) }
}

@main struct LayoutTestRunner {
    static func main() {
        let l = LayoutTests(), p = PresentationTests(), b = BarExtentTests(), n = NativeTileTests()
        let tests: [(String, () -> Void)] = [
            ("single window", l.testSingleWindowFillsWorkArea),
            ("landscape halves", l.testTwoWindowsAreLeftAndRightOnLandscapeDisplay),
            ("focused leaf insertion", l.testThirdWindowSplitsFocusedLeafNotAlwaysRemainder),
            ("sibling promotion", l.testRemovalPromotesSiblingWithoutRebuildingTree),
            ("minimize/restore slot", l.testMinimizeProjectionRestoresExactSlot),
            ("swap identity", l.testSwapPreservesGeometryAndBranchRatios),
            ("persistent resize and gap", l.testResizeUpdatesPersistentBranchAndKeepsGap),
            ("Space value isolation", l.testTreesAreValueIsolatedAcrossSpaces),
            ("split orientation", l.testHyprlandAutomaticAndPreservedSplitDirections),
            ("Hyprland ratios", l.testHyprlandRatioConventionAndBounds),
            ("cursor ordering", l.testCursorChoosesChildOrder),
            ("minimum sizes", l.testMinimumSizeConstrainsDivider),
            ("insertion/removal and pixel invariants", l.testManyInsertionRemovalCyclesNeverOverlapOrDuplicateIDs),
            ("fractional work-area edges", l.testFractionalWorkAreaHasNoAccidentalOuterPadding),
            ("nested minimum-size margins", l.testNestedMinimumSizesIncludeBothInteriorMargins),
            ("balanced mode gaps", l.testBalancedAlternativeStillHasExactGaps),
            ("zoom/restore no rebound", p.testNativeZoomThenRestoreDoesNotResuspend),
            ("no size-based false zoom", p.testLargeNormalWindowCannotBeMisclassifiedAsZoomed),
            ("respect native do-nothing", p.testNoNativeZoomMeansNoHijackedDoubleClick),
            ("rapid double-click cycle", p.testRapidDoubleClickCycleReturnsToTile),
            ("native fullscreen", p.testFullscreenNeverReturnsAFrameWriteDecision),
            ("200 zoom/restore cycles", p.testRepeatedNativeZoomCyclesNeverLeaveStaleSuspension),
            ("pointer hold", p.testPointerHoldCannotRaceNativeResize),
            ("exact native rounded-slot restoration", n.testZoomRestoresActualAssignedFrameNotAnotherRounding),
            ("native slot invalidation", n.testGeometryChangeInvalidatesOldNativeSlot),
            ("native slot rejection and cleanup", n.testRejectedSizeAndClosedWindowCannotReuseStaleSlot),
            ("cover flush edge", b.testFloatingCoverEndsAtWaybarBottomWithoutTrailingPadding),
            ("Retina cover alignment", b.testFractionalSettingsAlignToPhysicalPixels),
            ("thin cover safety", b.testFlushAndUnusuallyThinBarsStillHideNativeMenuBar)
        ]
        for (name, test) in tests {
            let before = failures; test(); if failures == before { print("PASS \(name)") }
        }
        print("\(tests.count) tests, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
