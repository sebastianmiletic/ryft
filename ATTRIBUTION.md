# Attribution and source mapping

The built-in **Classic · Exact** preset uses measured geometry, spacing, rounding, module ordering, and a complete Material palette from the project’s reference Quickshell setup.

Ryft maps the reference bar's left tools trigger, active window, resources, workspaces, clock, network, volume, battery, right control-center trigger, sidebars, wallpaper carousel, favorites, and adaptive wallpaper colors to native SwiftUI modules.

Reference snapshots used for the port are included under `Sources/Ryft/Resources/Upstream/Classic`. Ryft does not execute Linux QML or shell scripts on macOS.

The optional downloadable wallpaper collection comes from [ItsTerm1n4l/Wallpapers-old-archive](https://github.com/ItsTerm1n4l/Wallpapers-old-archive). Ryft downloads the archive only after the user chooses **Install GitHub wallpaper collection**, preserving its Abstract, Fantasy, Favorites, Nord, Space, Winter, and other source folders. The archive states that images originate from multiple creators; image rights remain with their respective creators.

The optional Hyprland cursor uses the **Bibata Modern Classic** pointer from [ful1e5/Bibata_Cursor](https://github.com/ful1e5/Bibata_Cursor). The pointer source and GPL-3.0 license are bundled under `Sources/Ryft/Resources/ThirdParty/Bibata`; Ryft recolors the upstream SVG template to the Modern Classic white and dark palette and generates the bundled PNG from that source.

Ryft’s automatic tiler is an independent native Swift implementation of the Dwindle binary-tree model documented by [Hyprland](https://wiki.hypr.land/configuring/layouts/dwindle-layout/). The official documentation and BSD-3-Clause-licensed upstream algorithm were consulted; no Hyprland C++ source or binaries are bundled. [The specification](docs/TILING.md) pins the reviewed upstream commits and distinguishes supported rules from native macOS adaptations. Ryft does not include or execute OmniWM, yabai, or a separate tiling helper.
