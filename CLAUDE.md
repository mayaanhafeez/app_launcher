# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
swift build                              # debug build of both executables
scripts/build-app.sh                     # release build + assemble/codesign .build/OrbitLauncher.app
open .build/OrbitLauncher.app            # run the resident app (no Dock/menu-bar item; LSUIElement)
swift test                               # swift-testing suite
swift test --filter fuzzyMatching        # single test (filter matches the @Test function name)
swift run orbitctl toggle                # drive a running instance over IPC
```

`scripts/build-app.sh` is the only supported way to run the GUI: the bare `swift build` binary has no bundle, so
`Resources/Info.plist` (bundle id `com.orbit.launcher`, `LSUIElement`) never applies and the accessory-app behavior and
container-relative socket path break. Ad-hoc codesigning is part of the script because the global hotkey and AppleScript
automation need a stable signature for TCC grants — resigning invalidates them, so expect fresh Accessibility/Automation
prompts after a rebuild.

There is no linter or formatter configured.

## Architecture

Two executables from one SwiftPM package (`Package.swift`), plus a vendored Lua 5.4.8 C target:

- **`OrbitLauncher`** — the resident AppKit app. Owns everything native: panel rendering, app index, fuzzy matching,
  navigation state, the global hotkey, and the IPC server.
- **`orbitctl`** (`Sources/OrbitCLI/main.swift`) — a ~30-line raw-`Darwin` Unix-socket client. Encodes a
  `{command, argument}` JSON request, reads one JSON response, exits `0`/`1`. It holds no app logic.
- **`Palette`** (`Palette.swift`) — imports external colour schemes. Base16 YAML, Omarchy
  `colors.toml`, kitty `.conf`, ghostty and btop `.theme` are all flat `key → hex` files
  differing only in separator and key vocabulary, so one tokenizer reads every dialect and
  `role` accessors resolve semantic roles against a priority list of key names. Adding a
  format means adding key names to those lists, not a parser.
- **`CLua`** — `Vendor/lua-5.4.8/src` compiled in-tree. `Vendor/lua-5.4.8/src/include/CLua.h` is a hand-written shim
  exposing what Swift can't import from Lua's headers (`LUA_REGISTRYINDEX` is a macro; `lua_error` is variadic-adjacent).
  Add to that shim rather than reaching into the Lua sources. Treat everything else under `Vendor/` as upstream — do not
  edit it.

### The native/Lua boundary

This split is the core design constraint: **AppKit owns all layout and interaction; Lua only supplies data.** Lua returns
a flat `{ items = ..., providers = ... }` table; it never describes layout. New visual behavior belongs in a native row
type in `Panel.swift`, not in a Lua-driven layout escape hatch.

### Data flow

`AppDelegate` (`Sources/OrbitLauncher/main.swift`) wires four objects with closures — there is no framework binding, no
observation, and the pieces don't know each other's types:

```
GlobalHotKey / IPCServer ─▶ AppDelegate ─▶ MenuController ──onRows──▶ PanelController
ConfigWatcher ──▶ LuaRuntime.load ──onReload──▶ MenuController      ◀──onQuery/onActivate/onBack──
AppIndex ──onChange──▶ MenuController
```

`MenuController` is the only place that knows about navigation, so it is where the interesting behavior lives:

- A **flat `[MenuNode]` array is the whole menu tree.** Hierarchy is only the `parent` string; `decodeNode` infers it
  from a dotted `id` (`dev.servers.web` → parent `dev.servers`) unless `parent` is set. A node with no action of any kind
  is a category (`kind == .menu`).
- **Empty query shows direct children; a non-empty query searches all descendants** (`isDescendant`, depth-capped at 32).
  Descendant hits are sorted after direct children, their `detail` is replaced by the breadcrumb `path(for:)`, and the
  first one is marked `section == "drilldown-start"` purely so `RowView` can draw a divider there.
- Apps are merged into results only at `apps` (all of them) and at `root` with a non-empty query (top 40).
- **A `provider` belongs to the submenu that declares it and fires while that submenu is
  open** — entering `search` runs `search`'s provider. It is deliberately not driven off the
  visible children: providers used to be collected from `candidates` (the active menu's
  *children*), so a provider on the open menu itself never ran.
- **`{query}` only works on provider rows, not static items.** Static rows go through the
  fuzzy filter, so typing the argument removes the row meant to consume it. Anything
  "act on what I typed" has to come from a provider, whose rows are appended post-filter.
- Provider rows carry their `ScriptAction` inline on `DisplayRow.action` because they have no
  backing `MenuNode` to look up. `activate` checks that before the node lookup.
- `back()` pops an explicit `navigation` stack rather than walking `parent`, so Escape retraces how the user arrived.
  It returns `false` at root, which is `PanelController`'s cue to hide the panel instead.

### LuaRuntime

All Lua work is serialized on a private `orbit.lua` queue and results are hopped back to `@MainActor`; `LuaRuntime` is
`@unchecked Sendable` on that basis. Every `lua_pcall` runs inside `withBudget`, which installs a count hook (1M
instruction ceiling, optional wall-clock deadline) keyed by state pointer in a global map.

Sandboxing is deliberate and layered — preserve it when touching `makeState`:

- `io` is nil'd out and `os.execute` removed in **every** state. External execution exists only as the host-provided
  `terminal` / `run` / `osascript` globals, which log before spawning.
- **Provider functions get none of those globals.** A provider is `lua_dump`ed from the config state and re-loaded into a
  throwaway `makeState(allowActions: false)` state per query, with a 0.15s deadline. That's why providers must be
  serializable (no upvalues beyond `_ENV`).
- `ThemeRuntime` is a separate short-lived state with `io`/`os`/`package`/`debug` removed. It returns a value-typed
  `Theme` and can only restyle the panel — a theme reload cannot touch the menu.

`shell` commands are Base64-encoded into `printf … | base64 -D | /bin/zsh` inside a `do script` AppleScript. That
encoding is what keeps quotes, newlines, pipes and redirects intact; don't "simplify" it into string interpolation.

`{query}` substitution lives on `ScriptAction.resolved(query:)` and escapes per destination —
single-quoted for shell, percent-encoded for URLs, backslash-escaped for AppleScript. Lua
`action` handlers get the query as their first argument. A blank target is a no-op: handing an
empty path to `NSWorkspace` raises a system "file can't be found" dialog.

`package.path` is pointed at the config directory (and `plugins/`, `lua/`) so a config splits up
the way a Neovim one does; `package.cpath` is emptied because a launcher config has no business
dlopen-ing.

Config lives at `~/.config/orbit/{config.lua,theme.lua}` (`Config/` holds the templates users copy). A missing config
falls back to `LuaRuntime.defaultNodes`; a config without a `root` item gets one injected.

`ConfigWatcher` watches **both the directory and each file**, with an 80ms debounce. A directory
vnode event only fires when an entry is added, removed or renamed — rewriting a file in place
(`cat > config.lua`, or an editor that saves without a temp-file swap) never touches the
directory, so a directory-only watch silently misses those saves. File watches are re-armed after
every event because an editor that saves via rename leaves the old descriptor on a dead inode.
A second watcher covers `~/.config/theme` so `palette = "auto"` retints when `set-theme` switches.

### Theme

`Theme` (`Models.swift`) is the entire appearance surface, by design: layout is native, so a value
hardcoded in `Panel.swift` is one the user can never reach. It carries colour, alpha, geometry,
spacing and typography. One `fontSize` drives a proportional scale and `spacingScale` multiplies
every spacing token, so either alone rescales the panel coherently. Selection follows Omarchy — a
low-alpha wash plus accent-tinted text, not an inverted accent slab.

`ThemeRuntime` seeds palette-derived roles *first*, then applies explicit `theme.lua` keys, so
explicit keys always win. The shipped `Config/theme.lua` therefore keeps its colour overrides
commented out; uncommenting them all makes `palette` inert.

### Panel

`PanelController` drives a borderless `.nonactivatingPanel` at `.popUpMenu` level — it takes key focus without
activating the app, which is why the app stays an accessory and the previously focused app keeps its state. Keys arrive
by two paths that must stay in sync: `control(_:textView:doCommandBy:)` for standard editing selectors and
`LauncherField.performKeyEquivalent` → `routeKey` for raw key codes (53/125/126/36/76/123). Left-arrow and Escape only
navigate back when the query is empty.

The card is content-sized: `resizeToContent` sums the row heights and caps at `max_height` of the
screen. It runs *before* `reloadData` in `update(title:rows:)`, because selection repainting walks
realized rows and the table has none until laid out at its final height.

`NSTableView` uses `selectionHighlightStyle = .none`; selection is painted manually by
`RowView.setSelected`, so `repaintSelection` must tell every realized row (`makeIfNecessary: false`)
— scanning `visibleRect` instead misses everything before first layout. Row height is computed in
the delegate from `showsDetail` plus a divider strip for the drilldown marker, so any change to
detail visibility needs a matching `noteHeightOfRows` call. `RowView` centres its label column on
`selectionBackground` rather than pinning to the top, which is what keeps single-line rows aligned
with their icon.

### Vim mode

Off unless `vim = true`; every code path is gated on `PanelController.vimEnabled`, so the
default build behaves exactly as it did before.

The key map is `VimKeys.normalModeAction` in `Models.swift` — deliberately pure and free of
AppKit state so it is testable without a window. `PanelController` maps the resulting
`VimAction` onto behaviour.

**Interception has to happen in a local key-down monitor.** `performKeyEquivalent` is *not*
sent for unmodified character keys — that is why the existing arrow/return/escape handling
lives in `control(_:textView:doCommandBy:)`, and why `routeKey` only ever sees special keys.
An earlier attempt to route `j`/`k` through `routeKey` silently typed them into the field
instead. `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` runs before the field editor
and returning nil swallows the event, which is the only hook that works here. The monitor is
inert unless vim mode is on and the panel is the key window.

Escape is the one key whose meaning is modal: insert → normal in the monitor, and in normal
mode it is passed through to the existing `cancelOperation:` path so clear/back/hide is
unchanged. `controlTextDidChange` flips to insert as a safety net, because a dead key or IME
commit can reach the field without passing the monitor and the indicator must never claim
NORMAL while the field is editing.

### IPC

`IPCServer` binds a `0600` Unix socket at
`~/Library/Containers/com.orbit.launcher/Data/tmp/orbit.sock`. One request, one response, connection closed. The handler
runs on `@MainActor`. Commands: `ping`, `toggle [route]`, `show [route]`, `hide`, `reload`, `invoke <node-id>`. Adding a
command means editing the switch in `AppDelegate.handle(_:)` — `orbitctl` forwards whatever verb it's given and needs no
change. `theme` reports the resolved palette name, which is the quickest way to check what a config
actually loaded.

Routes resolve through `MenuController.node(matching:)`: an exact id wins over any alias, and
underscores normalise to dashes. Unknown routes silently resolve to `root`; `invoke` on a category
or unknown id returns `ok: false`.

The global hotkey is re-registered from `config.lua` on every reload. `GlobalHotKey.register`
returns `false` for an unknown key name and keeps the previous binding rather than leaving the
launcher with no way to open.
