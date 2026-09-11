# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
swift build                              # debug build of both executables
scripts/build-app.sh                     # release build + assemble/codesign .build/KitsuneLauncher.app
open .build/KitsuneLauncher.app            # run the resident app (no Dock/menu-bar item; LSUIElement)
swift test                               # swift-testing suite
swift test --filter fuzzyMatching        # single test (filter matches the @Test function name)
swift run kitsunectl toggle                # drive a running instance over IPC
```

`scripts/build-app.sh` is the only supported way to run the GUI: the bare `swift build` binary has no bundle, so
`Resources/Info.plist` (bundle id `com.kitsune.launcher`, `LSUIElement`) never applies and the accessory-app behavior and
container-relative socket path break. Ad-hoc codesigning is part of the script because the global hotkey and AppleScript
automation need a stable signature for TCC grants — resigning invalidates them, so expect fresh Accessibility/Automation
prompts after a rebuild.

There is no linter or formatter configured.

## Git workflow

- Create every feature or bug-fix branch from `main`.
- Merge the branch into `dev` for testing.
- After testing is approved, merge the same branch into `main`.
- Delete the feature or bug-fix branch after it is merged into `main`.
- Do not make feature or bug-fix commits directly on `dev` or `main`.

## Architecture

Two executables from one SwiftPM package (`Package.swift`), plus a vendored Lua 5.4.8 C target:

- **`KitsuneLauncher`** — the resident AppKit app. Owns everything native: panel rendering, app index, fuzzy matching,
  navigation state, the global hotkey, and the IPC server.
- **`kitsunectl`** (`Sources/KitsuneCLI/main.swift`) — a ~30-line raw-`Darwin` Unix-socket client. Encodes a
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

`AppDelegate` (`Sources/KitsuneLauncher/main.swift`) wires four objects with closures — there is no framework binding, no
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
- **The back row is synthetic.** `decorated(_:)` adds it at every emission point rather than merging it into
  `candidates`: a static row would go through the fuzzy filter and vanish on the first keystroke, and adding it late is
  also what keeps `position = "bottom"` below the provider rows, which arrive after the base list. It is never shown at
  `root`, and `PanelController.update` skips `kind == .back` when picking the initial selection so Return on a fresh
  submenu never walks straight back out. Configured by `back = { enabled, label, symbol, detail, position }` (or
  `back = false`) in `config.lua`, carried on `Settings`.
- `back()` pops an explicit `navigation` stack rather than walking `parent`, so Escape retraces how the user arrived.
  It returns `false` at root, which is `PanelController`'s cue to hide the panel instead.

### LuaRuntime

All Lua work is serialized on a private `kitsune.lua` queue and results are hopped back to `@MainActor`; `LuaRuntime` is
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

`shell` commands are Base64-encoded into `eval "$(printf … | base64 -D)"` inside a `do script` AppleScript. The
encoding is what keeps quotes, newlines, pipes and redirects intact; don't "simplify" it into string interpolation.
The `eval` matters just as much: piping the decoded script into a shell puts it on **stdin**, which is exactly where
`read` reads from, so `read -r '?Formula: ' name; … && brew install $name` saw EOF and installed nothing (and a
multi-line script had `read` swallow its own next line). `eval` runs it in the Terminal window's own shell, which
leaves stdin on the tty — and because that shell is interactive, it is also what makes zsh print `read`'s `?prompt`.

`terminalLaunch(_:spec:)` decides *where* that script goes, and the two families it returns are not variants of one
command line. Terminal and iTerm are **scripted** — `do script` / `write text` puts the command into a window already
running an interactive shell, which is the whole reason the encoding above exists. Every other terminal is **spawned**
through `open -na <app> --args`, where argv is exact and the command needs no encoding at all; the `-i` in the default
`-e {shell} -ic {command}` is what keeps prompts printing there. Adding a terminal means adding a line to
`TerminalSpec.knownArguments`, not a code path, and `args` in the config is the escape hatch for one that isn't listed.
The spec is held in a process-wide `activeTerminal()` rather than on `LuaRuntime` because `terminalRun` is a bare C
function pointer with nowhere to hang a reference — `publishSettings` replaces it on every reload, including the
`Settings()` a missing config publishes, which is what puts Terminal.app back.

`{query}` substitution lives on `ScriptAction.resolved(query:)` and escapes per destination —
single-quoted for shell, percent-encoded for URLs, backslash-escaped for AppleScript. Lua
`action` handlers get the query as their first argument. A blank target is a no-op: handing an
empty path to `NSWorkspace` raises a system "file can't be found" dialog.

`package.path` is pointed at the config directory (and `plugins/`, `lua/`) so a config splits up
the way a Neovim one does; `package.cpath` is emptied because a launcher config has no business
dlopen-ing.

Config lives at `~/.config/kitsune/{config.lua,theme.lua}` (`Config/` holds the templates users copy). A missing config
falls back to `LuaRuntime.defaultNodes`; a config without a `root` item gets one injected.

`ConfigWatcher` watches **both the directory and each file**, with an 80ms debounce. A directory
vnode event only fires when an entry is added, removed or renamed — rewriting a file in place
(`cat > config.lua`, or an editor that saves without a temp-file swap) never touches the
directory, so a directory-only watch silently misses those saves. File watches are re-armed after
every event because an editor that saves via rename leaves the old descriptor on a dead inode.
A second watcher covers `~/.config/theme` so `palette = "auto"` retints when `set-theme` switches.

The watch is **recursive**, because `package.path` makes a config a tree rather than two files: every `.lua` file below
`~/.config/kitsune` is watched, and so is every directory holding one — an editor saving `plugins/git.lua` by rename
touches `plugins/`, never the config root, so the root's own watch never sees it. Non-`.lua` files are skipped, hidden
entries (a version-controlled config's `.git`) are not walked, and the walk is bounded by `maxDepth`/`maxWatches` so a
repository dropped under the config directory costs a fixed number of descriptors. The tree is re-walked on every event
rather than enumerated once at `start()`, which is what picks up a `plugins/` directory created after launch.
Recursion is tied to `watchesDirectory`: the `~/.config/theme` pointer watcher is aimed at the whole of `~/.config`,
and walking that would watch every dotfile directory the user owns.

### App index

`AppIndex` scans `/Applications`, `/System/Applications` and `~/Applications`, plus whatever `apps.paths` adds, and a
scan **replaces** the index rather than merging into it — dropping a path from the config, or deleting an app, has to
remove those rows on the next reload. `apps.depth` (3 by default) caps how far below a root the walk goes, because a
user root like `~/dev` can be enormous; 3 covers every built-in root, down to `~/Applications/CrossOver/Steam/Steam.app`.
Packages are returned but never descended into, so an app's bundled helper apps stay out of the list.

Icons are the index's entire memory cost — `NSWorkspace.icon(forFile:)` returns a multi-representation image sized for
the Finder and the index holds one per app for the process lifetime. `thumbnail(for:)` flattens each to a single 2x
bitmap at `thumbnailSize` (36pt, covering `Theme.iconSlot`), so an icon costs a fixed ~21KB
(72x72 RGBA) instead of a Finder-sized image with every representation it ships. A 129-app index sits at ~82MB resident
at rest; opening the full apps list still adds ~30MB of AppKit row and layer memory, which this does not address.

An `NSMetadataQuery` for app bundles used to live here and was removed: nothing observed
`NSMetadataQueryDidFinishGathering`, and `NSMetadataQueryDelegate` has no such callback (only the two `replacement…`
methods), so its results were never consumed. Wiring Spotlight back up means adding those notification observers — and
keeping the directory scan regardless, since Spotlight indexes nothing under `/System`.

### Command rows

`CommandRunner` (`CommandRunner.swift`) is the second async row source: a node's `command` is spawned while its submenu
is open and its stdout becomes rows. It exists because a provider cannot look at the machine — a provider is re-loaded
into a sandboxed state per keystroke — so `brew search`, `mdfind` and `aerospace list-windows` have to be spawned by the
host, debounced, deadlined and byte-capped.

**Output is data, never behaviour.** A row supplies `label`, `detail`, `symbol`, `value` and `notice`, and what
activating it does comes from `on_select` on the node that declared the command. The rows used to be able to name their
own `shell`/`applescript` — and a row is frequently a line the user did not write. A browser tab title is set by
whatever page is open, `aerospace`'s `--format` output is tab-separated and its window list is positional, so a title
carrying a newline and tabs split into a whole second record whose first field became the command. That is the one path
in the app where data an attacker can influence became something that runs; everything else needs code execution as the
user first.

`on_select` is resolved per row in `parse`, and the resolved `ScriptAction` is carried on `DisplayRow.action` exactly as
a provider row's is — so activation and the actions menu (`RowActions.entries` reads `row.action`) both keep working
with no second dispatch path. `{value}` is substituted by `ScriptAction.resolved(query:value:)`, escaped per
destination like `{query}` and in the **same pass**, so a value containing the literal text `{query}` is not given a
second reading. `value` defaults to the label, which is what keeps the tab-separated form a one-liner; `notice = true`
opts a row out, since an "on_select" that applies to every row would otherwise make "No rates for EUR" activatable.

The escaping only covers the layer the host can see. An `applescript` that itself runs `do shell script` is a shell
string inside an AppleScript string, and the plugin owns the inner layer — `Config/plugins/aerospace.lua` splices
`{value}` in with AppleScript's own `quoted form of` for exactly that reason. Its four menus also re-resolve `$wm`
inside the template, since the rows no longer carry which of aerospace/hyprspace answered.

The cache is keyed by the resolved script, plus the query when — and only when — the `on_select` is what reads
`{query}`: a static command whose action is query-dependent would otherwise be served rows carrying the query that
first built them.

### Trust boundaries

`~/.config/kitsune` and the IPC socket are **full trust by design**. A config is Lua the user wrote, it can already
`shell` anything, and the socket is `0600` in a container-relative directory — anyone who can write to either already
has code execution as the user. The sandboxing around providers and themes is about containing *the config's own
mistakes*, not about defending against a hostile config.

What is **not** trusted is anything the app reads at runtime: command output, window titles, file names, clipboard
contents, app metadata. Those are values, and the rule is that they stay values — a new feature that lets one of them
name a command, a path to open, or a URL to visit is re-opening the hole `on_select` closed.

### Filesystem path mode

`FileBrowser` (`FileBrowser.swift`) is the third async row source, beside providers and commands. A query starting `/`
or `~` **at `root`** stops being a menu search and becomes a directory listing — `build` returns an empty base list plus
the directory as the title, and the rows arrive from a background queue under the same `providerGeneration` guard, so a
slow directory cannot block a keystroke and a listing the user has typed past is dropped rather than drawn. Only `root`
does this: inside a submenu a leading slash is text to match, and has to stay that way.

`PathQuery` splits the query at its **last separator** — that is the whole trick, since it makes every keystroke after
the separator a filter of one already-known directory rather than another walk of the disk. It keeps the typed `prefix`
alongside the expanded `directory` because browsing *extends what was typed*: a `~/`-rooted query has to stay
`~/`-rooted rather than turning into `/Users/…` under the user mid-type.

Every row carries `.open(path)` — **directories too** — which is what gives the actions menu Reveal in Finder, Copy Path
and Open With here with no new `RowAction` case. `activate` therefore checks the directory case *before* the `action`
dispatch, or Return on a folder would open it in the Finder instead of browsing into it. A package is not browsable
(`isFilePackage`), on the same argument that stops `AppIndex` descending into a bundle.

Rows are absent from `kitsunectl list` for the same reason provider rows are: that is a synchronous snapshot.

### Clipboard history

`ClipboardHistory` (`ClipboardHistory.swift`) is a native row source with memory, for the two reasons `UsageStore`
gives: `NSPasteboard` has no change notification, so `changeCount` must be polled on a timer, and a Lua provider runs
only while its menu is open and is re-loaded into a throwaway state per keystroke. Neither watching nor remembering is
expressible there.

**Off by default, and inert while off** — `apply(_:)` stops the timer, drops the ring *and* deletes the file, because
"nothing is recorded while it is off" is a stronger claim than "the timer stopped". Re-enabling reseeds `lastChangeCount`
first, so whatever was already on the pasteboard — copied before the user asked for any of this — is not swept up.
Copies marked `org.nspasteboard.{Concealed,Transient,AutoGenerated}Type` are skipped, but their `changeCount` is still
recorded, or a skipped entry is re-examined on every tick. `persist` is opt-in separately from `enabled` and revoking it
deletes the file.

The pasteboard read is an injected closure (`Reading`) rather than a direct `NSPasteboard.general` call, which is what
lets the whole state machine be tested without touching the developer's clipboard — the same argument as `UsageStore`'s
`url: nil`.

The route is a real `MenuNode` injected the way `LuaRuntime` injects a missing `root`, so listing, search, aliases and
`kitsunectl show clipboard` all come for free; only `build` knows where the rows come from, beside the existing `apps`
case. It is re-injected after every reload because a reload replaces `nodes` wholesale. Rows carry
`rowAction = .copyText`, so Return goes through the row-action path and there is no second dispatch route to keep in
step — and `perform` calls `noteOwnWrite()` after writing, so re-copying an entry is not read back in as a fresh copy.

### Theme

`Theme` (`Models.swift`) is the entire appearance surface, by design: layout is native, so a value
hardcoded in `Panel.swift` is one the user can never reach. It carries colour, alpha, geometry,
spacing and typography. One `fontSize` drives a proportional scale and `spacingScale` multiplies
every spacing token, so either alone rescales the panel coherently. `panelPadding` is the
uniform inset; `paddingTop`/`paddingBottom`/`paddingSides` are optional per-edge overrides
that fall back to it when nil. Layout and `resizeToContent` both read the resolved
`topPadding`/`bottomPadding`/`sidePadding` accessors rather than `panelPadding` directly —
sizing the card from one value while laying it out from another is how the content and the
frame drift apart. Selection follows Omarchy — a
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

The window's content view is a plain container holding **two siblings**: the `NSVisualEffectView` and, drawn over it,
the card. The effect view used to be the card's superview, which made `blur = 0` (implemented as `alphaValue = 0`) hide
the rows and the input along with the material. `blur = 0` now hides the effect view alone — the card paints
`cardBackground` over a clear window either way, so the material is the only thing that switch is allowed to reach.

The card is content-sized: `resizeToContent` sums the row heights and caps at `max_height` of the
screen. It runs *before* `reloadData` in `update(title:rows:)`, because selection repainting walks
realized rows and the table has none until laid out at its final height.

It **anchors once per showing and hangs from that top edge** afterwards (`anchoredTop`,
`PanelPlacement.hanging`). `PanelPlacement.frame` places the card from scratch, so under the default
`center` a height change of N moves the top edge by N/2 — and `MenuController.refresh` emits twice,
so the provider, `command` and file rows land tens to hundreds of ms after the panel is already
drawn. Re-anchoring there reads as a jump rather than a resize. `captureAnchors` clears it, so a new
showing still re-anchors, and so does a theme reload, whose geometry may have moved the panel.
`update` also returns early when neither the title nor the rows changed — the app scan finishing
re-emits an identical root list — which is why `DisplayRow` is `Equatable`.

**Where** it lands is `PanelPlacement` (`Models.swift`) — pure, like `VimKeys` and `RowActions`: the visible frame,
the pointer and the focused window's frame all arrive as values, so every anchor and every clamp is testable without
a screen. `theme.position` picks the anchor and `theme.screen` the display; `offset_x`/`offset_y` are applied to the
anchor and then clamped with it, which is what makes it impossible for a config to place the card off-screen.
`active-window` and `screen = "active"` resolve through `FocusedWindow.frame()` (`SystemServices.swift`), an
Accessibility lookup that returns nil rather than guessing and drops those choices back to the pointer.

Both the pointer and that lookup are captured in `captureAnchors()` **once per showing**, not per resize:
`resizeToContent` runs on every keystroke, an Accessibility call is cross-process, and re-reading the pointer would let
the panel crawl after the mouse — or hop displays — while the user types into it.

The panel is ordered in with `animationBehavior = .none`. Left at `.default`, AppKit picks a fade for
a panel, and ramping the alpha of a rounded, shadowed card over ~6 frames makes its outline look like
it settles by a pixel or two on every open — measurable as the card's edges growing 3-5px across the
frames after it appears, with the window frame provably unchanged.

`NSTableView` uses `selectionHighlightStyle = .none`; selection is painted manually by
`RowView.setSelected`, so `repaintSelection` must tell every realized row (`makeIfNecessary: false`)
— scanning `visibleRect` instead misses everything before first layout. Row height is computed in
the delegate from `showsDetail` plus a divider strip for the drilldown marker, so any change to
detail visibility needs a matching `noteHeightOfRows` call. `RowView` centres its label column on
`selectionBackground` rather than pinning to the top, which is what keeps single-line rows aligned
with their icon.

### Row actions

Tab (or ⌘↩) on the selected row pushes its actions — Reveal in Finder, Copy Path, Open With…, Copy as Shell Command,
Copy Label — as **a menu like any other**, not a modal surface: same list, same fuzzy filter, same back row, same vim
keys. `RowActions.entries(for:query:)` (`RowActions.swift`) is the whole table and is pure, like `VimKeys` and
`EditingKeys`, so it is testable without a window. It takes the query because `ScriptAction.resolved(query:)` is what
makes "Copy as Shell Command" copy the command that would actually run rather than a template with a `{query}` hole.

`RowAction` is a value, not a closure, for the same reason `ScriptAction` is: the row *describes* what to do and
`MenuController.perform` does it. It is carried on `DisplayRow.rowAction` and checked in `activate` **before** the node
lookup, exactly as `action` is — an actions row backs no `MenuNode`. Every case dismisses except `openWithPicker`, which
navigates.

Navigation had to generalise for this. `activeMenu`/`navigation: [String]` became `location: MenuLocation` and a stack
of `Frame`s, because an actions menu is built from a `DisplayRow` and cannot be named by an id. `activeMenu` survives as
a computed property returning the node id or the sentinel `kitsune.actions`, and that sentinel is what keeps the blast
radius small: it matches no node, so `decorated` still adds the back row (it only withholds one at `root`) and neither
the provider nor the command lookup finds anything to run.

A `Frame` carries an optional `restoreQuery`. **Only actions frames set it** — an actions menu is a detour from a search,
so the search must survive it, whereas leaving an ordinary submenu is a fresh start and still clears the query. `back()`
*refreshes* with the restored query rather than only re-emitting it, because `PanelController.setQuery` deliberately
does not fire `onQuery` back.

Key routing splits the two chords across the two paths it has to: ⌘↩ is modified so it reaches `routeKey`, where it is
claimed before the bare Return cases; Tab is unmodified, so `performKeyEquivalent` is never sent for it and it can only
be caught as `insertTab:` in `control(_:textView:doCommandBy:)`. Tab also had to be added to the pass-through list in
`consumesInNormalMode`, or vim's normal mode swallows it as an unmapped key.

### List shortcuts

`ShortcutSpec` (`Models.swift`) is positional, not per-item: the nth key activates the nth row of whatever the list is
currently showing, so it needs no ids and keeps working over search results and provider rows. Like `VimKeys` it is a
pure function of characters plus modifiers, so it is testable without a window. `PanelController.activate(position:)`
filters out `kind == .back` before indexing, which is what keeps ⌘1 on the first real item with the back row at either
end, and it swallows a key past the end of the list rather than letting it reach the field. Dispatch is
`performKeyEquivalent` → `routeKey`, which works here precisely because these are modified keys — the reason plain keys
need the vim-mode event monitor instead. Configured by `shortcuts = { enabled, hints, mods, keys }` (or `shortcuts = false`).

`hints` draws each row's chord on its right. `PanelController` precomputes one hint per row in `rebuildHints` rather
than deriving it in `viewFor`, which would re-count the rows above every row it builds. The label hangs off
`chevron.leadingAnchor`, not the row edge, so a hint sits the same distance from the edge whether or not its row draws a
chevron — a hidden chevron keeps its width — and an empty hint measures zero wide, which leaves the label column's
trailing limit exactly where the chevron alone used to put it.

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

### Menu bar

`MenuBarItem` (`SystemServices.swift`) is the only persistent UI outside the panel: an `NSStatusItem` with Open Config
Folder / Reload Config / Show Last Error / Open at Login / Quit. The app is `LSUIElement`, so without it the only ways to reload or quit are `kitsunectl`
and `kill`. "Open Config Folder" creates `~/.config/kitsune` first — opening a path that doesn't exist does nothing at
all.

It is configured by `menu_bar = { enabled, symbol, title }` (or `menu_bar = false`), carried on `Settings`. The
`NSStatusItem` is therefore created on demand in `apply(_:)` rather than held in a stored property — a stored one exists
from the moment the object does, which is exactly what `enabled = false` has to be able to prevent. The `NSMenu` *is*
built once in `init` and reattached, so re-enabling doesn't rebuild the entries or lose their targets. An unknown
`symbol` leaves the button's image alone, on the same argument as `GlobalHotKey.register`. `AppDelegate.startMenuBar()`
runs **before** `reloadAll()` for this reason: the spec arrives with the first settings publish and needs something to
apply to.

Switching it off is a one-way door for discoverability, so the first time it happens `AppDelegate` raises a modal
`NSAlert` naming `kitsunectl` and `kill` as what's left, gated on a `UserDefaults` flag so it never fires twice. The
panel's own `showNotice` is no use here — it auto-hides after five seconds and the panel is shut when a config save
lands.

**Config errors live here, not in a toast.** `LuaRuntime.onLoadOutcome` fires from `publish` — the single point every
exit from `reload` passes through — so a load's problems are reported exactly once. `AppDelegate` holds them until a
load succeeds, and surfaces them three ways: the status button goes red, **Show Last Error** opens the full text, and
`PanelController.persistentNotice` keeps the summary on the panel's banner. All three are needed. The banner alone
auto-hid after five seconds and the panel is shut when a save lands; the menu bar alone means the only report is behind
a menu nobody has a reason to open. `MenuBarItem` re-applies the state after building a status item, or switching the
item off and on again would clear an error that is still outstanding.

The red is painted into a **copy** of the glyph (`MenuBarItem.tinted`), not applied with `contentTintColor`. A status
item draws a template image as a mask in the menu bar's own text colour and ignores the tint, so the "red" icon was
black — which is the same thing as no indicator at all. A painted copy must also drop `isTemplate`, or the mask wins
again.

`ConfigErrorFormatter` is what the user actually reads. Lua's message names the token where the *parser* stopped, which
for a missing comma is below the line to fix, and repeats an absolute path identical in every error that user will ever
see. The formatter strips the `Config:` prefix the alert title already says, rewrites paths relative to the config
directory (`plugins/themes.lua`, not `themes.lua` — that is what the config called it), quotes every line the message
named straight from the file, and adds the parse-error hint. It takes its file reader as a closure, so the whole thing
is testable without a disk, on the same argument as `ClipboardHistory.Reading`.

**A plugin the config caught is still reported.** The shipped template loads plugins with `pcall(require, ...)` so one
broken plugin does not take the menu down — which also swallowed the error whole: the load "succeeded", nothing was
shown, and the rows just never appeared. `reportingRequire` stands in for `require` in the config state, records the
failure in the state's own registry (`kitsune.warnings`) and **re-raises it**, so a config that catches it behaves
exactly as before and one that does not still fails outright. `publish` drops a warning the failure message already
contains, or an uncaught `require` error would be reported twice. The list lives in the registry rather than a Swift
global because a state is built per load: one load cannot carry its problems into the next.

`LoginItem` wraps `SMAppService.mainApp` — no helper target, no legacy `SMLoginItemSetEnabled`. It only works from a
real bundle (the bare `swift build` binary has no Info.plist for launchd), and registration is tied to the bundle's
signature and location, so re-signing or moving the app can orphan it. `register()` can also succeed while leaving the
item in `.requiresApproval`, which looks like a silent failure unless the notice says so.

`login_item` in `config.lua` is applied **only when the value changes** (`AppDelegate.appliedLoginItem`), so a toggle
made from the menu bar survives every unrelated config save; an actual edit to the key still wins. The menu's checkmark
is resolved in `menuNeedsUpdate` rather than cached, because System Settings can switch the item off without telling
the app.

### IPC

`reload` is the one **asynchronous** verb: a config load runs on the Lua queue, so answering `ok` before it had been
parsed made `kitsunectl reload` useless in a script. `IPCCommands.handle` therefore takes a completion, the socket stays
open until it fires, and `AppDelegate` parks the reply in `pendingReloads` until `LuaRuntime.onLoadOutcome` reports how
the load went. Every other verb still answers inline through the pure `response(for:)` switch.

`IPCServer` binds a `0600` Unix socket at
`~/Library/Containers/com.kitsune.launcher/Data/tmp/kitsune.sock`. One request, one response, connection closed. The handler
runs on `@MainActor`. Commands: `ping`, `toggle [route]`, `show [route]`, `hide`, `reload`, `theme`, `version`,
`invoke <node-id>`. The verb switch lives in `IPCCommands` (`SystemServices.swift`), which holds no AppKit state —
`AppDelegate.handle(_:)` only binds each effect to the delegate's objects, so the command surface is testable without an
`NSApplication`. Adding a command means editing that switch and adding a closure; `kitsunectl` forwards whatever verb it's
given and needs no change. `theme` reports the resolved palette name, which is the quickest way to check what a config
actually loaded; `version` reads the bundle's stamped plist rather than a compiled-in constant, so it cannot drift from
the tag `scripts/build-app.sh` built from.

Routes resolve through `MenuController.node(matching:)`: an exact id wins over any alias, and
underscores normalise to dashes. Unknown routes silently resolve to `root`; `invoke` on a category
or unknown id returns `ok: false`.

### Global hotkeys

`GlobalHotKey` is a **registry**, not a binding: `bindings` is keyed by slot — a chord's index in `config.lua` — and
`register(_:)` takes the whole set, adding, replacing and dropping per slot on each reload. One binding never had to ask
which chord fired; several do, so the Carbon callback now pulls the `EventHotKeyID` off the event with
`GetEventParameter` and dispatches on its `id`.

A rejected chord costs **only its own slot**, which is the point of the registry: all-or-nothing was tolerable when
there was one binding and is not once there are several. An unknown key name is caught by `keyCode(for:)` *before*
anything is unregistered, so a typo cannot cost a working binding; a chord that is valid but already held system-wide
fails at `RegisterEventHotKey`, and the slot's previous spec is re-claimed. `register` returns the specs it could not
bind so `AppDelegate` names those and only those. An unchanged spec keeps the registration it already holds, so an
unrelated config save doesn't churn the set.

`HotKeySpec.target` is a `HotKeyTarget`: `.toggle(route)` opens the panel (`"root"` being the historical behaviour), and
`.invoke(id)` fires a node through `MenuController.invoke(id:)` — the same entry point `kitsunectl invoke` uses — with no
panel at all. Because an `invoke` chord shows nothing, a failure is `NSLog`ed as well as noticed, or it is silent.

`hotkeys = { ... }` is the list; `hotkey = { ... }` stays a single-entry alias decoded by the same `decodeHotKey`, and
`hotkeys` wins when both are present. An empty list leaves the default binding rather than leaving the launcher with no
way to open.
