-- AeroSpace / Hyprspace. The launcher's edge over a keybinding is that it can *search*
-- live state, so the four menus that matter are the ones backed by a list the window
-- manager owns: every window, every workspace, and the two ways to move things between
-- them. The rest is a keystroke you already have.
--
-- Three constraints shape every line of this file:
--
-- 1. **This has to be `command`, not `provider`.** A provider is re-loaded into a
--    throwaway state per keystroke with `io` nil'd and no execution globals, so it is a
--    pure function of the query. `aerospace list-windows` looks at the machine, and only
--    the host can spawn that.
--
-- 2. **The command must filter on `{query}` itself.** Command rows are appended *after*
--    the fuzzy filter, exactly like provider rows, so nothing narrows them for you —
--    hence `-v q={query}` and the `index()` test in each awk program.
--
-- 3. **The action is `applescript`, not `shell`.** `shell = ...` opens a terminal
--    window; focusing a window must not. `do shell script` runs it silently, which is
--    what the Automation permission Kitsune already asks for is for.
--
-- The panel itself is invisible to the window manager — a non-activating accessory
-- panel never becomes the frontmost window — so `aerospace list-windows --focused`
-- answers with the user's real window while the launcher is open, and a plain
-- `close` or `layout` acts on that window rather than on Kitsune.

-- Resolved at run time rather than baked in: one plugin serves both binaries, and a GUI
-- app inherits a minimal PATH from launchd, so neither is on it by default.
local RESOLVE = 'PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; '
  .. 'wm=$(command -v hyprspace || command -v aerospace)'

-- `do shell script "..."` takes an AppleScript string literal, so the script has to be
-- escaped for AppleScript rather than for the shell.
local function applescript(script)
  return 'do shell script "' .. script:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- A static row: run one subcommand against whatever the window manager considers
-- focused. `exec` because there is nothing left to do afterwards, and the `&&` guard
-- because a missing binary should be a no-op, not an AppleScript error.
local function item(id, label, fields)
  fields = fields or {}
  fields.id = id
  fields.label = label
  if fields.wm then
    fields.applescript = applescript(RESOLVE .. ' && exec "$wm" ' .. fields.wm)
    fields.wm = nil
  end
  return fields
end

-- Shared by both awk programs. Window titles contain quotes and backslashes often
-- enough to matter ("Copy" in a Finder window, any Windows path in a browser tab), and
-- a broken JSON line is silently dropped by the host — so the escaping is done a
-- character at a time rather than with `gsub`, whose replacement-string backslash rules
-- are the wrong tool for producing backslashes.
local ESCAPE = [[
function esc(s,   out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\"" || c == "\\") out = out "\\" c
    else if (c == "\t") out = out " "
    else out = out c
  }
  return out
}
function row(label, detail, symbol, value, script) {
  printf "{\"label\":\"%s\",\"detail\":\"%s\",\"symbol\":\"%s\",\"value\":\"%s\"," \
         "\"applescript\":\"do shell script \\\"%s\\\"\"}\n",
         esc(label), esc(detail), symbol, esc(value), esc(script)
}
function notice(label, detail) {
  printf "{\"label\":\"%s\",\"detail\":\"%s\",\"symbol\":\"exclamationmark.triangle\"}\n",
         esc(label), esc(detail)
}
]]

-- A row with no action is a notice, which is how "nothing is running" says so instead
-- of drawing an empty menu.
local MISSING = 'printf \'{"label":"No window manager found",'
  .. '"detail":"Install AeroSpace or Hyprspace","symbol":"exclamationmark.triangle"}\\n\''

-- Every window on every workspace, focused by id. The id is what the row acts on, so a
-- window that moved between listing and Return is still the window you picked.
local WINDOWS = RESOLVE .. ' || { ' .. MISSING .. '; exit 0; }\n'
  .. '"$wm" list-windows --all '
  .. '--format \'%{window-id}\t%{workspace}\t%{app-name}\t%{window-title}\' 2>/dev/null'
  .. ' | awk -F\'\t\' -v q={query} -v wm="$wm" \''
  .. ESCAPE .. [[
{
  seen = 1
  if (q != "" && index(tolower($3 " " $4), tolower(q)) == 0) next
  row(($4 == "" ? $3 : $3 "  ·  " $4), "Workspace " $2, "macwindow",
      "win-" $1, wm " focus --window-id " $1)
}
END { if (!seen) notice("No windows", "The window manager is not running") }
]] .. "'"

-- One list, three verbs. `mode` is what the row does with the workspace it names:
-- focus it, send the focused window there, or pull it onto this monitor. The window id
-- is resolved while the rows are built for the same reason the window list bakes one
-- in — by the time Return lands, "focused" may mean something else.
local function workspaces(mode)
  return RESOLVE .. ' || { ' .. MISSING .. '; exit 0; }\n'
    .. '{ "$wm" list-workspaces --focused --format \'F\t%{workspace}\'\n'
    .. '  "$wm" list-windows --focused --format \'T\t%{window-id}\'\n'
    .. '  "$wm" list-windows --all --format \'N\t%{workspace}\'\n'
    .. '  "$wm" list-workspaces --all --format \'W\t%{workspace}\t%{monitor-name}\'\n'
    .. '} 2>/dev/null | awk -F\'\t\' -v q={query} -v wm="$wm" -v mode=' .. mode .. ' \''
    .. ESCAPE .. [[
$1 == "F" { focused = $2; next }
$1 == "T" { window = $2; next }
$1 == "N" { count[$2]++; next }
$1 == "W" {
  seen = 1
  workspace = $2; monitor = $3
  if (q != "" && index(tolower(workspace " " monitor), tolower(q)) == 0) next
  n = count[workspace] + 0
  detail = n " window" (n == 1 ? "" : "s") "  ·  " monitor
  symbol = n ? "square.grid.2x2" : "square.dashed"
  if (workspace == focused) { detail = detail "  ·  focused"; symbol = "square.grid.2x2.fill" }
  if (mode == "move") {
    if (window == "") next
    row("Move window to " workspace, detail, symbol, "ws-" workspace,
        wm " move-node-to-workspace --window-id " window " -- " workspace)
  } else if (mode == "summon") {
    row("Summon workspace " workspace, detail, symbol, "ws-" workspace,
        wm " summon-workspace -- " workspace)
  } else {
    row("Workspace " workspace, detail, symbol, "ws-" workspace,
        wm " workspace -- " workspace)
  }
}
END {
  if (!seen) notice("No workspaces", "The window manager is not running")
  else if (mode == "move" && window == "") notice("No focused window", "Nothing to move")
}
]] .. "'"
end

return {
  items = {
    item("wm", "Window Manager", {
      symbol = "rectangle.3.group",
      title = "Window Manager",
      aliases = { "aerospace", "hyprspace", "tiling", "wm" },
    }),

    -- The four live lists.
    item("wm.switch", "Switch Window", {
      symbol = "macwindow.on.rectangle",
      detail = "Every window, every workspace",
      aliases = { "windows", "alt-tab" },
      command = WINDOWS,
    }),
    item("wm.workspace", "Workspaces", {
      symbol = "square.grid.3x2",
      aliases = { "spaces", "ws" },
      command = workspaces("focus"),
    }),
    item("wm.send", "Move Window To", {
      symbol = "arrow.right.square",
      detail = "Send the focused window to a workspace",
      aliases = { "move" },
      command = workspaces("move"),
    }),
    item("wm.summon", "Summon Workspace", {
      symbol = "arrow.down.left.square",
      detail = "Pull a workspace onto this monitor",
      command = workspaces("summon"),
    }),

    -- Layout, on whatever is focused. `layout` takes a list and toggles between the
    -- entries, which is why Tiles and Accordion each name both axes: pressing them
    -- twice flips the split rather than doing nothing.
    item("wm.layout", "Layout", { symbol = "squareshape.split.2x2" }),
    item("wm.layout.tiles", "Tiles", { symbol = "rectangle.split.2x1", wm = "layout tiles horizontal vertical" }),
    item("wm.layout.accordion", "Accordion", { symbol = "rectangle.stack", wm = "layout accordion horizontal vertical" }),
    item("wm.layout.horizontal", "Horizontal", { symbol = "rectangle.split.3x1", wm = "layout horizontal" }),
    item("wm.layout.vertical", "Vertical", { symbol = "rectangle.split.1x2", wm = "layout vertical" }),
    item("wm.layout.float", "Toggle Floating", { symbol = "macwindow.badge.plus", aliases = { "float" }, wm = "layout floating tiling" }),
    item("wm.layout.fullscreen", "Toggle Fullscreen", { symbol = "arrow.up.left.and.arrow.down.right", wm = "fullscreen" }),
    item("wm.layout.native", "Toggle Native Fullscreen", { symbol = "arrow.up.left.and.arrow.down.right.square", wm = "macos-native-fullscreen" }),
    item("wm.layout.minimize", "Minimize", { symbol = "arrow.down.right.and.arrow.up.left", wm = "macos-native-minimize" }),

    -- The tree operations, which have no obvious keybinding and are the ones people
    -- forget exist.
    item("wm.tree", "Arrange", { symbol = "arrow.triangle.branch" }),
    item("wm.tree.balance", "Balance Sizes", { symbol = "equal.square", detail = "Even out the focused workspace", wm = "balance-sizes" }),
    item("wm.tree.flatten", "Flatten Tree", { symbol = "list.bullet.indent", detail = "Collapse nested containers", wm = "flatten-workspace-tree" }),
    item("wm.tree.close", "Close Window", { symbol = "xmark.square", wm = "close" }),
    item("wm.tree.others", "Close Other Windows", { symbol = "xmark.square.fill", detail = "Everything but the focused window", wm = "close-all-windows-but-current" }),

    item("wm.monitor", "Monitors", { symbol = "display.2" }),
    item("wm.monitor.next", "Focus Next Monitor", { symbol = "arrow.right.circle", wm = "focus-monitor --wrap-around next" }),
    item("wm.monitor.prev", "Focus Previous Monitor", { symbol = "arrow.left.circle", wm = "focus-monitor --wrap-around prev" }),
    item("wm.monitor.send", "Move Window to Next Monitor", { symbol = "arrow.right.square.fill", wm = "move-node-to-monitor --focus-follows-window --wrap-around next" }),

    item("wm.setup", "Window Manager Setup", { symbol = "gearshape.2", title = "Setup" }),
    item("wm.setup.reload", "Reload Config", { symbol = "arrow.clockwise", wm = "reload-config" }),
    item("wm.setup.toggle", "Toggle Tiling", { symbol = "power", detail = "Suspend window management", wm = "enable toggle" }),
    item("wm.setup.service", "Service Mode", { symbol = "wrench.and.screwdriver", wm = "mode service" }),
    -- An editor *does* want a terminal, so this one is a `shell` row like any other.
    -- Whichever config exists is the one that opens.
    item("wm.setup.edit", "Edit Config", {
      symbol = "chevron.left.forwardslash.chevron.right",
      shell = 'for f in ~/.config/hyprspace/config.toml ~/.aerospace.toml ~/.config/aerospace/aerospace.toml; '
        .. 'do [ -f "$f" ] && exec ${EDITOR:-nvim} "$f"; done; echo "no config found"; read -r _',
    }),
  },
}
