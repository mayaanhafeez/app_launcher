# OrbitLauncher

A resident native macOS launcher and nested command menu. AppKit owns the warm non-activating panel, rendering, app index, fuzzy matching, state, hotkey, and IPC. Lua 5.4 owns menu data, actions, providers, and flat theme tokens.

## Build and run

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
open .build/OrbitLauncher.app
swift run orbitctl toggle
```

The global hotkey is `Option-Command-Space`. The app has no Dock or menu-bar item.

Copy `Config/config.lua` and `Config/theme.lua` to `~/.config/orbit/` to start customizing. Config changes rebuild the complete menu Lua state. Theme changes use a separate restricted state and only restyle the warm panel.

## IPC

```sh
orbitctl toggle [route]
orbitctl show [route]
orbitctl hide
orbitctl invoke <node-id>
orbitctl reload
orbitctl ping
```

The Unix socket is `~/Library/Containers/com.orbit.launcher/Data/Library/Application Support/OrbitLauncher/orbit.sock` and is mode `0600`.

Lua menu entries are data-only native row contracts. Supported fields are `id`, `parent`, `label`, `detail`, `symbol`, `provider`, and `action`. UI layout remains entirely native; new visual behavior should be implemented as a native row type rather than Lua layout.
