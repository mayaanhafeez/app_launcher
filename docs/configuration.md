# Configuration reference

This is the complete reference for what `~/.config/orbit/config.lua` and
`~/.config/orbit/theme.lua` can express. For install/build instructions and the
`orbitctl` command list, see the [README](../README.md).

Both files reload automatically on save. `config.lua` runs with full execution
privileges and rebuilds the entire menu tree; `theme.lua` runs in a separate,
more restricted Lua state and can only change how the panel looks — it can never
add, remove, or otherwise touch menu items.

- [File locations and `package.path`](#file-locations-and-packagepath)
- [Menu items](#menu-items)
- [Actions and `{query}`](#actions-and-query)
- [Providers](#providers)
- [Settings](#settings)
- [Theme](#theme)
- [Worked example: a plugin from scratch](#worked-example-a-plugin-from-scratch)

## File locations and `package.path`

| File | Purpose |
|---|---|
| `~/.config/orbit/config.lua` | Menu tree, actions, providers, settings |
| `~/.config/orbit/theme.lua` | Colors, spacing, typography |
| `~/.config/orbit/plugins/*.lua` | Anything you `require "plugins.<name>"` |
| `~/.config/orbit/lua/*.lua` | Anything you `require "<name>"` |
| `~/.config/orbit/themes/*.{toml,yaml,yml,conf,theme}` | Local colour scheme files for `palette = "<name>"` |

`config.lua`'s Lua state points `package.path` at:

```
~/.config/orbit/?.lua
~/.config/orbit/?/init.lua
~/.config/orbit/plugins/?.lua
~/.config/orbit/plugins/?/init.lua
~/.config/orbit/lua/?.lua
~/.config/orbit/lua/?/init.lua
```

so a config splits up exactly the way a Neovim config does — `require
"plugins.git"` resolves `~/.config/orbit/plugins/git.lua`, `require "foo"` resolves
`~/.config/orbit/lua/foo.lua` or `~/.config/orbit/foo.lua`. `package.cpath` is
emptied in every state: no C extension modules, ever — a launcher config has no
business `dlopen`-ing.

A global `orbit` table is available everywhere:

| Field | Value |
|---|---|
| `orbit.config_dir` | `~/.config/orbit` |
| `orbit.plugin_dir` | `~/.config/orbit/plugins` |
| `orbit.home` | The user's home directory |
| `orbit.can_execute` | `true` in the config state, `false` inside a provider call |

If `~/.config/orbit/config.lua` doesn't exist, Orbit falls back to a small
built-in menu (Apps / System / Tools) rather than failing to launch.

## Menu items

`config.lua` returns a table with an `items` array. Each item is a table:

```lua
return {
  items = {
    { id = "dev", label = "Development", symbol = "hammer", aliases = { "code" } },
    {
      id = "dev.server",
      label = "Run local server",
      detail = "Opens in Terminal",
      shell = "cd ~/code/my-app && npm run dev",
    },
  },
}
```

| Field | Meaning |
|---|---|
| `id` | Unique row id. **Dotted ids infer their parent**: `dev.server` implicitly parents under `dev`, `dev.servers.web` under `dev.servers`. The one item with `id = "root"` is always the top level regardless of what `parent` says. |
| `parent` | Overrides the inferred parent. Ids without a dot default to `root` unless this is set. |
| `label` | Row text. |
| `title` | Header text shown while this item's submenu is open. Defaults to `label`. |
| `detail` | Subtitle. Visibility is controlled by `theme.lua`'s `detail_mode`. While the user is searching, an item found via drilldown has its `detail` replaced by a breadcrumb (e.g. `Development > Servers`) instead. |
| `symbol` | An SF Symbol name. |
| `icon` | Path to an image file (`~` allowed). **Wins over `symbol`** when both are set — the symbol glyph is simply not drawn. |
| `aliases` | Extra route strings for `orbitctl show <alias>` / `orbitctl invoke <alias>`. Also folded into fuzzy search alongside the label, detail, and the id's last dotted segment (`install.editor.zed` is found by typing `zed`). |
| `provider` | Name of a function in the top-level `providers` table that supplies this item's *children* at query time. See [Providers](#providers). |
| `shell` / `applescript` / `open` / `url` | What the row does. See below. |
| `action` | A Lua function `function(query) ... end`, run in the full config state (with `terminal`/`run`/`osascript` available). See below. |

An item with **no** action field and no `provider` is a category (a submenu with
static children only). An item with any of `shell`, `applescript`, `open`, `url`,
or `action` becomes an actionable row.

If more than one action field is set on the same item, only one runs, in this
priority order: `action` (the Lua function) first, then `shell`, then
`applescript`, then `open`, then `url`.

If no item in `items` has `id = "root"`, Orbit inserts a default one for you so
there's always a top level to open.

## Actions and `{query}`

- **`shell = "..."`** — opens Terminal and runs the command there. The command is
  Base64-transported into an `eval "$(printf %s ... | base64 -D)"` inside an
  AppleScript `do script`, which is what keeps quotes, newlines, pipes and
  redirects intact, and what lets an interactive `read -r '?Prompt: ' var` work
  (the decoded script lands on the Terminal window's own tty-backed shell, not on
  a pipe).
- **`applescript = "..."`** — run through `/usr/bin/osascript`.
- **`open = "..."`** — a bundle path launched through `NSWorkspace`. `~` is
  expanded.
- **`url = "..."`** — opened through the system's default handler for that
  scheme.
- **`action = function(query) ... end`** — called directly with the query the
  user typed. It has the same globals as the rest of `config.lua`, including
  `terminal(command)` (alias `run(command)`) and `osascript(source)`:

  ```lua
  {
    id = "dev.notify",
    label = "Notify",
    action = function(query)
      osascript('display notification "' .. (query ~= "" and query or "hi") .. '" with title "Orbit"')
    end,
  }
  ```

  Lua has no `io`, and `os.execute` is removed in every Lua state Orbit creates —
  `terminal`, `run` and `osascript` are the only way to run something external,
  and each call is logged by the host.

Any of `shell`, `applescript`, `open` or `url` may contain the literal token
`{query}`, which is substituted with what the user typed, **escaped for its
destination**:

| Destination | Escaping |
|---|---|
| `shell` | Single-quoted, with embedded `'` escaped as `'\''` |
| `applescript` | Backslashes and `"` are backslash-escaped |
| `url` | Percent-encoded (alphanumerics left bare) |
| `open` | Substituted verbatim, unescaped — `open` targets a file path, not something `{query}` is meant to build |

```lua
{ id = "install.query", label = "Install What I Typed", shell = "brew install {query}" }
```

### `{query}` only works reliably on provider rows

**A static item with `{query}` in it is filtered by the exact text meant to fill
`{query}`.** Rows go through the fuzzy matcher against their label/detail/id
before `{query}` is ever substituted, so typing `ripgrep` into "Install What I
Typed" scores no match against that label and the row disappears from the list
before it can be activated.

Use a [provider](#providers) for anything that should act on what the user
typed — provider rows are appended to the list *after* the static rows are
filtered, so they always survive. `{query}` inside a *provider* row's
`shell`/`applescript`/`open`/`url` is substituted exactly as described above.
`Config/plugins/brew.lua` is the shipped example of this pattern.

## Providers

A `provider = "name"` on a menu item makes that item's children dynamic: the
named function in the top-level `providers` table is called with the current
query every time that submenu is the open one, and its return value supplies
the rows.

```lua
providers = {
  websearch = function(query)
    if query == "" then return {} end
    return {
      { label = "Google " .. query, symbol = "globe", value = "google",
        url = "https://www.google.com/search?q={query}" },
    }
  end,
}
```

A provider **is not called with any execution helpers**. It runs in a throwaway,
short-lived Lua state that has no `io`, no `os.execute`, and none of `terminal`,
`run`, or `osascript` — those globals only exist in the main config state. A
provider must *describe* what a row should do (via `shell`/`applescript`/`open`/
`url` fields on the rows it returns) and let the host run it once the user picks
one; it cannot execute anything itself.

Two more constraints follow directly from how a provider actually runs:

- **Providers are serialized and reloaded on every call.** Orbit `lua_dump`s the
  provider function out of the config state and reloads that bytecode into a
  fresh sandboxed state per query. That means **a provider function must be
  self-contained — no upvalues beyond `_ENV`.** A `local` declared outside the
  provider function and referenced inside it will come back `nil` when the
  function runs standalone. If you need a helper function, define it *inside*
  the provider closure (see `Config/plugins/smart.lua`'s `asquote`/`copyRow`, or
  `Config/plugins/projects.lua`'s trick of compiling a per-project path in as a
  string literal via `load(string.format(...))` rather than closing over a
  local).
- **Each call has a 0.15 second budget** (plus a shared 1,000,000 Lua
  instruction ceiling that applies to every script Orbit runs). A provider has
  to be fast and pure — no network calls, no sleeping, no expensive scans.

### Provider row fields

A row returned by a provider is a plain table, not a `MenuNode` — it has no
backing item, so its shape is narrower than a static item's:

| Field | Meaning |
|---|---|
| `label` | Required. A row without a non-empty `label` is skipped. |
| `detail` | Subtitle. |
| `symbol` | SF Symbol name. |
| `icon` | Path to an image file, wins over `symbol`. |
| `value` | Used to build the row's id (`<menu-id>.<slugified value>`); defaults to a slug of `label` if omitted. |
| `shell` / `applescript` / `open` / `url` | Same as static items, evaluated in that priority order if more than one is present. `{query}` substitution and per-destination escaping both apply. |

A provider row has **no `action` function field** — providers describe actions
as data, they don't hand back closures. A row with none of `shell`,
`applescript`, `open`, or `url` set is purely informational (not activatable).

## Settings

These are top-level keys in the table `config.lua` returns (except `palette`,
which lives in `theme.lua` — see [Theme](#theme)).

### `hotkey`

```lua
hotkey = { key = "space", mods = { "option" } },
```

The global hotkey that opens the panel. Defaults to Option-Space. `key` accepts
a single letter or digit, or one of: `space`, `return`/`enter`, `tab`,
`escape`/`esc`, `delete`/`backspace`, `left`, `right`, `up`, `down`, `home`,
`end`, `pageup`, `pagedown`, `grave`/`backtick`, `period`, `comma`, `slash`,
`semicolon`, `f1`–`f12`. `mods` accepts any of `option`/`opt`/`alt`,
`command`/`cmd`/`super`, `control`/`ctrl`, `shift`. An unrecognized `key` name
is rejected and the previous binding is kept, so a typo can't leave the
launcher with no way to open.

### `vim`

```lua
vim = false,   -- default
```

Off by default. `vim = true` makes the panel modal, opening in NORMAL mode:

| Key | NORMAL | INSERT |
|---|---|---|
| `j` / `k` | move down / up | types |
| `/` | clear the query, switch to INSERT | types |
| `i` | switch to INSERT, keep the query | types |
| `a` | switch to INSERT at the end of the query | types |
| `s` | clear the query, switch to INSERT | types |
| `Escape` | clear query → back → hide, in that order | switch to NORMAL |
| `Enter` | activate | activate |

Unmapped letters are swallowed in NORMAL rather than typed into the field.
Anything held with Command or Control passes through untouched.

### `back`

```lua
back = { enabled = true, label = "Back", symbol = "chevron.left", detail = "", position = "top" },
-- or: back = false
```

Configures the synthetic row that leaves a submenu. `back = false` removes it
entirely. `position` is `"top"` or `"bottom"`; anything else is treated as
`"top"`. The back row never appears at the root menu, and it's skipped when
Orbit picks which row starts selected on a fresh submenu (so pressing Return
immediately after opening a submenu never walks straight back out).

### `shortcuts`

```lua
shortcuts = {
  enabled = true,
  hints = true,                                          -- draw the chord on the right of each row
  mods = { "command" },
  keys = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
},
-- or: shortcuts = false
```

Positional shortcuts: the *n*th key in `keys` activates the *n*th row currently
on screen (the back row is excluded from the count, so `⌘1` always lands on the
first real item). `mods` takes the same modifier vocabulary as `hotkey.mods`.
`shortcuts = false` disables the feature; `hints = false` keeps the shortcuts
working but stops drawing them.

### `apps`

```lua
apps = {
  paths = {},   -- extra roots to scan, e.g. { "~/dev", "~/Downloads" }
  depth = 3,    -- path components below a root to walk
},
```

`/Applications`, `/System/Applications` and `~/Applications` are always
scanned; `paths` adds more roots on top of them. `depth` bounds how far below
each root the scan descends — keep it small, since a root like `~/dev` can be
enormous. A `.app` bundle is never descended into, so an app's bundled helper
apps never show up as separate entries. Changing either field triggers a
re-scan, and a scan **replaces** the index rather than merging into it, so
removing a path (or deleting an app) removes it from the list on the next
reload.

### `login_item`

```lua
login_item = false,   -- default
```

Registers Orbit to launch at login via `SMAppService`. Off by default —
registering something with launchd isn't something to opt a user into silently.
Only takes effect when applied *value changes*, so toggling it from the menu
bar survives an unrelated `config.lua` save; editing this key back is still
what wins. Only works from the built `.app` bundle (`scripts/build-app.sh`) — a
bare `swift build` binary has no `Info.plist` for launchd to register against.

### `palette`

Set in **`theme.lua`**, not `config.lua` — see [Theme](#theme) below.

## Theme

`theme.lua` returns a table of styling tokens. Layout itself is entirely
native (AppKit), so this token set really is the whole appearance surface —
there is no other place in Orbit a color, spacing value, or font size can come
from.

### Colour

```lua
palette = "auto",   -- "auto" | a scheme name | "~/path/to/scheme.yaml"

-- bg = "17191f"
-- surface = "22252d"
-- fg = "d8dee9"
-- fg_muted = "7f8490"
-- accent = "7aa2f7"
-- border = "3b3f4a"
-- selection_bg = "d8dee9"   -- defaults to fg
-- selection_fg = "7aa2f7"   -- defaults to accent
```

`palette` imports an external colour scheme and seeds `bg`, `surface`, `fg`,
`fg_muted`, `accent`, `border` and `selection_bg`. Any of those keys set
explicitly below it in the same file still wins — `theme.lua` applies the
palette first, then your explicit overrides on top, which is why the shipped
`Config/theme.lua` keeps its overrides commented out (uncommenting all of them
would make `palette` inert).

- `palette = "auto"` follows `~/.config/theme` (the same pointer file tools
  like `set-theme` write), so switching the system theme retints Orbit too.
  Orbit watches that file and reloads automatically when it changes.
- `palette = "kanagawa"` — a bare name, searched in this order:
  ```
  ~/.config/orbit/themes/<name>.{toml,yaml,yml,conf,theme}
  ~/omarchy/themes/<name>/colors.toml
  ~/.config/kitty/themes/<name>.conf
  ~/.config/ghostty/themes/<name>
  ~/.config/btop/themes/<name>.theme
  ```
- `palette = "~/schemes/dracula.yaml"` — an explicit path.

Supported formats — all flat `key → hex`, read by one tokenizer:

| Format | Looks like | Keys used |
|---|---|---|
| Base16 / Base24 YAML | `base00: "1e1e2e"` | `base00`–`base0F` |
| Omarchy `colors.toml` | `accent = "#89b4fa"` | `background`, `foreground`, `accent`, `selection`, `muted`, … |
| kitty `.conf` | `background  #1e1e2e` | `background`, `foreground`, `selection_background`, `color0`–`color15` |
| ghostty | `palette = 4=#7aa2f7` | same as kitty, plus indexed `palette` entries |
| btop `.theme` | `theme[main_bg]="#1e1e2e"` | `main_bg`, `main_fg`, `hi_fg`, `selected_bg`, `inactive_fg` |

Hex is read the same way everywhere — in palette scheme files and in the
explicit `theme.lua` overrides alike: `#rrggbb`, `rrggbb`, `#rgb`, or
`0xaarrggbb` (the alpha byte is dropped, since the theme composes its own).
A value you copy out of a palette file therefore means the same thing when you
paste it into `theme.lua`. A colour that can't be parsed leaves the
palette-seeded value in place rather than overriding it.

### Full token reference

| Key | Default | Notes |
|---|---|---|
| `bg` | `17191f` | Panel background |
| `surface` | `22252d` | |
| `fg` | `d8dee9` | Primary text |
| `fg_muted` | `7f8490` | |
| `accent` | `7aa2f7` | |
| `border` | `3b3f4a` | |
| `selection_bg` | (= `fg`) | |
| `selection_fg` | (= `accent`) | |
| `bg_alpha` | `0.82` | 0–1 |
| `border_alpha` | `1.0` | 0–1 |
| `selection_alpha` | `0.10` | 0–1; the selected row is a soft wash, not a solid slab |
| `detail_alpha` | `0.55` | 0–1 |
| `chevron_alpha` | `0.36` | 0–1 |
| `divider_alpha` | `0.20` | 0–1 |
| `blur` | `0.82` | 0–1; `>0.66` uses `.hudWindow` material, `>0.33` `.menu`, else opaque |
| `radius` | `12` | Panel corner radius |
| `row_radius` | `8` | |
| `width` | `380` | Minimum `220` |
| `max_height` | `0.6` | Fraction (0–1) of the screen height the panel may grow to before scrolling |
| `border_width` | `1` | |
| `offset_y` | `28` | Offset above screen centre |
| `spacing_scale` | `1.0` | Multiplies every spacing token below |
| `panel_padding` | `12` | Inset on every edge, unless overridden per-edge |
| `padding_top` | (= `panel_padding`) | |
| `padding_bottom` | (= `panel_padding`) | |
| `padding_sides` | (= `panel_padding`) | |
| `row_gap` | `2` | |
| `row_padding_x` | `10` | |
| `icon_slot` | `34` | |
| `icon_gap` | `8` | |
| `label_gap` | `1` | |
| `row_height` | `44` | Minimum `20` |
| `row_height_detail` | `56` | Minimum `20`; used when a row's detail line is visible |
| `divider_height` | `15` | Height of the drilldown-marker divider strip |
| `header_gap` | `8` | |
| `selection_inset` | `0` | |
| `selection_bar` | `0` | Width of a left accent bar on the selected row |
| `font` | `""` (system font) | A named font family |
| `font_size` | `13` | Minimum `6` — drives the whole type scale, see below |
| `label_weight` | `"medium"` | |
| `detail_weight` | `"regular"` | |
| `detail_mode` | `"search"` | `"search"` \| `"always"` \| `"never"` — when the detail line renders |

Weight names accepted by `label_weight`/`detail_weight`: `ultralight`, `thin`,
`light`, `regular`/`normal`, `medium`, `semibold`, `bold`, `heavy`, `black`.

### Rescaling the panel

`font_size` drives a proportional type scale rather than being one of many
independent sizes — every other text size is `font_size` times a fixed
multiplier: caption `×0.833`, small `×0.917`, body `×1.0`, title `×1.167`,
heading `×1.333`, icon `×1.5`. Raising `font_size` alone rescales all of that
coherently.

`spacing_scale` does the same job for layout: every spacing token above (gaps,
padding, row height, icon slot, …) is multiplied by it. Setting `spacing_scale
= 1.25` with the defaults otherwise untouched makes for a proportionally
roomier panel without hand-tuning each token.

The panel itself is content-sized — it shrinks to fit its rows and only
scrolls once it would exceed `max_height` of the screen.

## Worked example: a plugin from scratch

This walks through adding a small plugin end to end: a `Tools > Generate UUID`
item whose provider drops a fresh UUID on the clipboard.

**1. Create the file.**

```sh
mkdir -p ~/.config/orbit/plugins
touch ~/.config/orbit/plugins/uuid.lua
```

**2. Write the plugin.** It returns a table with `items` and `providers`, the
same shape every plugin returns:

```lua
-- ~/.config/orbit/plugins/uuid.lua

return {
  items = {
    { id = "tools", label = "Tools", symbol = "hammer" },
    {
      id = "tools.uuid",
      label = "Generate UUID",
      symbol = "number",
      provider = "uuid_gen",
      detail = "Press Enter to copy a new one",
    },
  },
  providers = {
    -- Everything the provider needs lives inside the function body: a provider
    -- is dumped to bytecode and reloaded with none of its upvalues, so a
    -- `local function uuidv4` declared outside this closure would come back
    -- nil when the provider actually runs.
    uuid_gen = function(query)
      local function uuidv4()
        local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
        return (template:gsub("[xy]", function(c)
          local value = (c == "x") and math.random(0, 15) or math.random(8, 11)
          return string.format("%x", value)
        end))
      end
      local id = uuidv4()
      return {
        {
          label = id,
          detail = "Copied to clipboard",
          symbol = "doc.on.clipboard",
          value = "uuid",
          applescript = 'set the clipboard to "' .. id .. '"',
        },
      }
    end,
  },
}
```

The provider ignores `query` entirely — a UUID doesn't need input — but the
signature has to accept it regardless, since Orbit always calls a provider
with the current query as its first argument.

**3. Load the plugin from `config.lua`.** Plugins aren't auto-discovered; the
shipped `config.lua` loads a fixed list by name:

```lua
for _, name in ipairs({ "example", "smart", "text", "projects", "themes", "brew" }) do
  local ok, plugin = pcall(require, "plugins." .. name)
  if ok and type(plugin) == "table" then
    for _, entry in ipairs(plugin.items or {}) do items[#items + 1] = entry end
    for key, fn in pairs(plugin.providers or {}) do providers[key] = fn end
  end
end
```

Add `"uuid"` to that list (or write your own loop — `require "plugins.uuid"`
resolves via the `package.path` entries described above regardless of how you
call it).

**4. Save.** Orbit's file watcher picks up the change within about 80ms and
reloads `config.lua` automatically — no restart needed. Open the panel, type
into Tools, select "Generate UUID," and press Return: the row's `applescript`
action runs and the UUID lands on the clipboard.

From here, the same shape — a category item plus a `provider` function that
returns `{ label, detail, symbol, value, shell|applescript|open|url }` rows —
is how every dynamic list in Orbit is built, from `plugins/brew.lua`'s
"install what I typed" to `plugins/projects.lua`'s per-project grep.
