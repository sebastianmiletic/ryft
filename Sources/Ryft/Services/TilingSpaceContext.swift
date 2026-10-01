import AppKit
import Darwin

struct TilingLayoutKey: Hashable {
    let display: CGDirectDisplayID
    let space: UInt64
}
struct TilingDisplayContext {
    let key: TilingLayoutKey
    let screen: NSScreen
    let nativeFullscreen: Bool
    let windowIDs: Set<CGWindowID>?
}

/// Uses actual managed Space IDs, not the changing Mission Control desktop
/// number. A Space gesture may briefly report both desktops as on-screen;
/// intersecting with the active Space's window list prevents cross-Space writes.
final class TilingSpaceContext {
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias CopySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias CopyWindows = @convention(c) (UInt32, UInt32, CFArray, UInt32, UnsafePointer<UInt64>?, UnsafePointer<UInt64>?) -> Unmanaged<CFArray>?
    private let library: UnsafeMutableRawPointer?
    private let main: MainConnection?
    private let spaces: CopySpaces?
    private let windows: CopyWindows?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        library = handle
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let value = dlsym(handle, name) else { return nil }
            return unsafeBitCast(value, to: type)
        }
        main = symbol("CGSMainConnectionID", MainConnection.self)
        spaces = symbol("CGSCopyManagedDisplaySpaces", CopySpaces.self)
        windows = symbol("SLSCopyWindowsWithOptionsAndTags", CopyWindows.self)
    }
    deinit { if let library { dlclose(library) } }

    func current(fallbackDesktop: Int) -> [TilingDisplayContext] {
        guard let main, let spaces, let displays = spaces(main())?.takeRetainedValue() as? [[String: Any]] else {
            return NSScreen.screens.map { TilingDisplayContext(key: TilingLayoutKey(display: DisplayLayoutMetrics.displayID(for: $0), space: UInt64(max(1, fallbackDesktop))), screen: $0, nativeFullscreen: false, windowIDs: nil) }
        }
        var result: [TilingDisplayContext] = []
        for screen in NSScreen.screens {
            let id = DisplayLayoutMetrics.displayID(for: screen)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            guard let display = displays.first(where: { ($0["Display Identifier"] as? String) == uuid })
                    ?? displays.first(where: { ($0["Display Identifier"] as? String) == "Main" }),
                  let current = display["Current Space"] as? [String: Any],
                  let space = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
            var setTags: UInt64 = 0, clearTags: UInt64 = 0
            let ids = windows?(main(), 0, [NSNumber(value: space)] as CFArray, 0x2, &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber]
            result.append(TilingDisplayContext(key: TilingLayoutKey(display: id, space: space), screen: screen, nativeFullscreen: ((current["type"] as? NSNumber)?.intValue ?? 0) != 0, windowIDs: ids.map { Set($0.map { CGWindowID($0.uint32Value) }) }))
        }
        return result
    }
}
