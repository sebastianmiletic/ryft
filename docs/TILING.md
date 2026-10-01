# Native Dwindle layout

Ryft's layout engine is an independent Swift implementation of Hyprland's documented Dwindle tree model, adapted to macOS Accessibility windows. It does not execute Hyprland, OmniWM, yabai, or a separate helper. **Settings → Tiling** selects **Hyprland Dwindle** or the separate balanced **Sizing & positioning** mode. Enablement and application exceptions are preserved when upgrading.

## Upstream references

Reviewed October 1, 2026. References are pinned so future upstream changes do not silently change this specification:

- [Official Dwindle documentation](https://wiki.hypr.land/configuring/layouts/dwindle-layout/), [wiki source at `7f7e03d`](https://github.com/hyprwm/hyprland-wiki/blob/7f7e03d1932f133f9f9e88e954deff68094bfa1f/content/configuring/layouts/dwindle-layout.md).
- [Official dispatcher documentation](https://github.com/hyprwm/hyprland-wiki/blob/7f7e03d1932f133f9f9e88e954deff68094bfa1f/content/configuring/core/dispatchers.md).
- [Upstream Dwindle algorithm at `e826317`](https://github.com/hyprwm/Hyprland/blob/e82631720b5d585d7ca09f567cb321063b7c7ab2/src/layout/algorithm/tiled/dwindle/DwindleAlgorithm.cpp) and [its header](https://github.com/hyprwm/Hyprland/blob/e82631720b5d585d7ca09f567cb321063b7c7ab2/src/layout/algorithm/tiled/dwindle/DwindleAlgorithm.hpp).

No upstream C++ source is bundled or translated line-for-line.

## Implemented rules

- Each display/managed Space has its own persistent binary tree. Windows are leaves; split branches own their direction and ratio. Window count, application activation and CGWindow Z-order never rebuild existing branches.
- Opening a window splits the focused leaf by default (`use_active_for_splits`). Disable **Split the focused window** to select the leaf beneath/nearest the cursor instead.
- **New window side** implements `force_split`: cursor-directed, new left/top, or new right/bottom. Default is cursor-directed.
- By default the split axis follows each container's aspect ratio: left/right when `width > height × split_width_multiplier`, otherwise top/bottom. **Preserve split directions** implements `preserve_split`; it locks each branch to its creation direction.
- **Default split ratio** uses Hyprland's convention: `1 = 50/50`; `0.1...1.9 = 5...95%` for the first (left/top) child. Existing dividers retain their own ratios.
- Closing a leaf promotes its sibling. Minimizing or hiding projects a leaf out without destroying it, so restoring restores its tree slot. Dragging an internal window edge adjusts the actual ancestor divider; dropping a title bar in another tile swaps leaf IDs, not the tree or ratios.
- Inner gaps, work-area edges and final window rectangles are aligned to physical display pixels. The bar/cover, Dock and outer gap are reserved once using the same geometry.

This is the Dwindle model, not the old "keep the left half and always split the remainder" approximation.

## Native macOS differences

macOS is not a Wayland compositor. Ryft cannot override a window's native minimum size, force fixed-size windows to resize, expose all Hyprland dispatchers, or replace Mission Control animations.

- Only resizable standard AX windows are managed. Window IDs are resolved with `_AXUIElementGetWindow`, then cached one-to-one identity and a tightly bounded geometry fallback. Sheets/dialogs, excluded apps and Ryft's own panels do not consume slots.
- Native fullscreen Spaces and `AXFullScreen` windows are never resized, including checks immediately before every write.
- Title-bar double-click waits for native macOS zoom to actually change the frame. Successful zoom fills the bar-safe area; another double-click explicitly restores the current tile before returning to normal layout. Actual native tile frames are retained because Cocoa/Chromium may round half-point AX coordinates to whole points; restoration reuses that exact assigned frame while the requested slot is unchanged. There is no "large frame means maximized" heuristic. Apple’s “Do nothing”/minimize preference is respected. Buttons, fields and web content are not title bars.
- A maximized window keeps its tree slot, but pauses only its own tile writes. Siblings and newly opened windows continue to be sized even on the same desktop; closing a maximized window cannot leave a global suspension behind. Unlike Hyprland, macOS provides no compositor-level mechanism for Ryft to hide those sibling tiles.
- Native dragging/resizing pauses corrective writes. Applications that reject smaller sizes teach the engine their minimum dimensions. A window that physically cannot fit remains floating, with a **minimum-size exception** status, instead of repeatedly rejecting writes or overlapping its tiled neighbors.
- Space membership comes from the actual active managed Space ID and window list, not a desktop's renumberable index. Animations revalidate that Space before writing. If private SkyLight functions are unavailable, Ryft falls back to visible windows and the current desktop number; that fallback cannot provide equally strong Space isolation.
- Disabling layout/quitting restores pre-managed frames for currently visible normal windows. It does not move hidden desktops, minimized windows, or native-fullscreen/maximized windows.
- Reduce Motion disables layout animation. Optional Hyprland `smart_split`, pseudotiling, special workspaces, preselect/rotation commands and precise drag insertion are not implemented. Ryft exposes only rules it implements.

## Exact wallpaper-cover boundary

For a top bar, `TopBarExtent` is:

```
notch shelf + top inset + bar height
```

There is **no extra bottom inset**. Each component is rounded upward to the display's physical-pixel grid. The all-Spaces Waybar window and the desktop-specific wallpaper cover use the same lower edge; the tiler starts at that edge plus the configured outer gap. With a 40 pt bar, 6 pt inset and no notch shelf, both windows are exactly **46 pt / 92 Retina pixels** tall.

A bar shorter than Apple's native menu bar is the deliberate exception: its cover must extend far enough to conceal Apple’s menu surface. On other bar edges, a separate top cover conceals the native menu bar.

## Regression tests

```sh
./scripts/test-layout.sh
# Or, with a complete Xcode installation providing XCTest:
swift test
```

The portable script runs the same core test cases without requiring XCTest in CommandLineTools. Cases cover persistent insertion/removal, focused/cursor placement, swaps, divider ratios, independent Space values, minimization projection, orientations, nested minimum sizes, inner gaps, negative/fractional coordinates, 1×/2× pixel grids, native fullscreen decisions, ignored native zoom, rapid restore, 200 consecutive zoom/restore state cycles, exact native rounded-slot restoration/invalidation, and the cover's exact lower edge.

These tests prove pure geometry/state behavior, not every third-party application's AX implementation. Live verification still needs repeated browser double-clicks, native fullscreen, native edge drags, Space gestures, multi-display topology changes and application-specific minimum-size behavior.

### Verified on October 1, 2026

On macOS 27 with a 1470 × 956 pt, 2× display: all 29 core tests passed, debug and signed production builds passed, and the installed CG windows showed the Waybar and four independent desktop covers at exactly 46 pt height. Native AX checks exercised three browser windows plus two temporary standard windows while one browser was maximized. All normal windows matched their slots within 0.5 pt (native Cocoa rounding), and the maximized browser matched the safe area. Minimizing/restoring returned both test windows to identical actual frames and requested slots; closing them reduced five managed windows to three without stopping the engine.

Repeated physical title-bar zoom/restore, native fullscreen transitions, pointer divider/swap gestures, slow/rapid Space gestures and multiple-display tests still require completing the live regression matrix. Pure-state 200-cycle tests are not a substitute for those application-specific checks.

For an opt-in geometry-only adapter trace, launch the installed executable with `RYFT_TILING_TRACE=/tmp/ryft-tiling.json`. This overwrites a local JSON snapshot containing window IDs, bundle IDs, frame coordinates, Space IDs and engine status. It never includes window titles, selected text, screenshots or AI credentials; no trace is written unless that variable is explicitly supplied.
