-- KitsuneLauncher config. Copy this whole directory to ~/.config/kitsune/.
--
-- This file holds settings and nothing else. Rows live in two places, both using the
-- same contract -- a module returning `{ items = ..., providers = ... }`:
--
--   menus/     this config's own content, one file per top-level menu
--   plugins/   self-contained pieces, to share or delete whole
--   lua/       item.lua (the row constructors, and what fields a row may carry)
--              loader.lua (merges the two lists below)
--
-- Everything reloads on save, anywhere in the tree.
--
-- **Every option Kitsune reads is listed below, at its default**, so this file doubles
-- as the reference. Anything switched off is spelled `false` rather than left out: an
-- absent key and a disabled one look identical from here, and only one of them is a
-- decision someone made.

local load = require("loader")

return load {
  -- Which files supply the rows, and in what order. A node's position in the merged
  -- list is its sort key, so this list *is* the order of the top-level rows.
  menus = {
    "root", "learn", "trigger", "style", "setup", "homebrew", "update", "about",
    "system", "search",
  },
  plugins = {
    "example", "smart", "text", "projects", "themes", "brew", "aerospace", "settings",
    "find", "currency", "units",
  },

  -- Global chords. Each either toggles the panel (optionally at a `route`) or fires a
  -- node outright with `invoke`, never showing the panel. A chord Kitsune cannot bind
  -- costs only its own line: the rest stay bound, and the one that failed keeps
  -- whatever it had. `hotkey = { ... }` is still accepted as a single-entry alias, and
  -- `hotkeys` wins when both are present.
  hotkeys = {
    { key = "space", mods = { "option" } },                       -- toggle the root menu
    -- { key = "t", mods = { "option" }, route = "tools" },        -- open a submenu directly
    -- { key = "l", mods = { "option" }, invoke = "system.lock" }, -- run a node, no panel
  },

  -- The row that leaves a submenu. Never shown at root, skipped when the selection
  -- lands on the first row, and it survives every query. `back = false` removes it;
  -- `position` is "top" or "bottom".
  back = { enabled = true, label = "Back", symbol = "chevron.left", detail = "", position = "top" },

  -- Positional shortcuts for whatever the list is showing: the nth key activates the
  -- nth row, with the back row skipped so the numbering matches the items.
  -- `shortcuts = false` removes them; `mods` takes the same names as `hotkeys`.
  shortcuts = {
    enabled = true,
    hints = true,          -- draw the chord on the right of each row
    mods = { "command" },
    keys = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
  },

  -- The menu bar item. `menu_bar = false` removes it entirely -- but the app has no
  -- Dock icon either, so with it gone the only ways left to reload or quit are
  -- `kitsunectl` and `kill`. Kitsune says so once, the first time you switch it off.
  -- An unknown `symbol` leaves the current icon alone. `title` draws text beside it.
  menu_bar = { enabled = true, symbol = "circle.dashed", title = "" },

  -- Extra roots to scan for .app bundles, on top of /Applications,
  -- /System/Applications and ~/Applications. `depth` is how many components below a
  -- root to walk -- keep it small, a root like ~/dev can be enormous.
  apps = {
    paths = {},          -- e.g. { "~/dev", "~/Downloads" }
    depth = 3,
  },

  -- Path completion. A query starting `/` or `~` at the top level lists that directory
  -- instead of searching the menu: Return on a folder browses into it, Return on a file
  -- opens it, Tab gives Reveal / Copy Path / Open With. Dotfiles need `show_hidden`,
  -- unless the fragment being typed starts with a dot. `files = false` switches it off.
  files = { enabled = true, show_hidden = false, limit = 40 },

  -- Frecency. Rows activated often, and recently, rank higher in *search* results; the
  -- order written in `menus/` is never rearranged. `ranking = false` switches it off.
  -- `half_life` is in seconds, `weight` is the ceiling on the discount in fuzzy-score
  -- units.
  ranking = { enabled = true, half_life = 14 * 24 * 3600, weight = 12 },

  -- Result limits. `app_limit` caps the app rows merged into a search, `row_limit` caps
  -- the whole list (0 = no cap), `depth` is how far a drilldown search walks, and
  -- `match_detail` decides whether the subtitle is searchable too.
  search = { app_limit = 40, row_limit = 0, depth = 32, match_detail = true },

  -- Budget for Lua providers. `debounce` is a quiet period before a keystroke runs the
  -- provider; 0 fires on every keystroke. Named `provider_limits` rather than
  -- `providers`, which already holds the provider functions themselves.
  provider_limits = { timeout = 0.15, instructions = 1000000, debounce = 0 },

  -- Budget for `command = "..."` rows. Stricter than the Lua one, because this spawns a
  -- real process while you type: `debounce` is a quiet period before anything is
  -- spawned, `timeout` kills what overstays, `max_bytes` bounds a command that prints
  -- without stopping. `login = true` runs a login shell so it picks up your own PATH --
  -- slower, but needed if the launcher cannot find your tools (a GUI app inherits a
  -- minimal PATH from launchd; /opt/homebrew/bin and /usr/local/bin are added anyway).
  commands = {
    timeout = 2,
    debounce = 0.15,
    max_rows = 200,
    max_bytes = 1048576,
    cache_size = 32,
    shell = "/bin/sh",
    login = false,
  },

  -- Quiet period after a config-file change before reloading.
  watch = { debounce = 0.08 },

  -- Which terminal a `shell = ...` item opens in. Terminal and iTerm are driven by
  -- AppleScript, which types the command into a window already running your interactive
  -- shell. Everything else is launched with `open -na <app> --args`, and Kitsune knows
  -- the flags for the common ones. For anything else, spell the argv out -- `{shell}`
  -- and `{command}` are substituted, and `{command}` arrives as one argument:
  --   terminal = { app = "Rio", args = { "-e", "{shell}", "-ic", "{command}" } },
  terminal = "Terminal",

  -- Clipboard history: a built-in `clipboard` menu (aliases: clip, history) listing the
  -- last `limit` things you copied, newest first. Return re-copies an entry.
  --
  -- OFF, and nothing at all is recorded while it is off -- a launcher that starts
  -- logging everything you copy unasked is not a good default. Copies marked concealed
  -- or transient (password managers set this) are always skipped. `persist` writes the
  -- history to disk; it is opt-in on its own, and turning it back off deletes the file.
  --   clipboard = { enabled = true, limit = 100, poll_interval = 1, persist = false },
  clipboard = false,

  -- Open as a bare search field, the way Spotlight does: at root with nothing typed
  -- the list is not drawn at all, and the first keystroke expands the card. A submenu
  -- is unaffected -- arriving somewhere deliberately still shows what is in it. Off by
  -- default, because the menu tree is the point of a launcher that has one.
  show_search_only = false,

  -- Modal navigation. When on, the panel opens in NORMAL mode:
  --   j / k      move down / up          / or s   clear the query and start typing
  --   i          resume typing           a        append at the end of the query
  --   Escape     insert -> normal; in normal mode it clears, then goes back, then hides
  --   Enter      activate, in either mode
  -- Arrow keys keep working in both modes.
  vim = false,

  -- Start Kitsune at login. Registering something with launchd is a thing to opt into.
  -- It can also be toggled from the menu bar, and this value wins the next time the
  -- config is saved. Only works from the built .app bundle.
  login_item = false,
}
