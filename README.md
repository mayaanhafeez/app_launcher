# OrbitLauncher

A resident native macOS launcher and nested command menu, in the shape of the Omarchy
menu. AppKit owns the warm non-activating panel, rendering, app index, fuzzy matching,
state, hotkey and IPC. Lua 5.4 owns the menu tree, actions, providers, plugins and the
theme.

The split is deliberate: **layout is native, everything else is yours.** New visual
behaviour becomes a native row type plus a theme token — never Lua-driven layout.

## Build and run

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
open .build/OrbitLauncher.app
swift run orbitctl toggle
```

The default hotkey is `Option-Space` and is configurable. The app has no Dock or
menu-bar item.

```sh
mkdir -p ~/.config/orbit
cp Config/config.lua Config/theme.lua ~/.config/orbit/
cp -r Config/plugins ~/.config/orbit/
```

Both files reload on save. `config.lua` rebuilds the whole menu state; `theme.lua` uses
a separate restricted state and can only restyle the panel.

## IPC

```sh
orbitctl toggle [route]
orbitctl show [route]
orbitctl hide
orbitctl invoke <node-id>
orbitctl reload
orbitctl theme          # report the colour scheme currently in effect
orbitctl ping
```

A route is an item id or one of its `aliases`, case-insensitive, with underscores
normalised to dashes. An exact id beats any alias; an unknown route opens the root.
The Unix socket is `~/Library/Containers/com.orbit.launcher/Data/tmp/orbit.sock`, mode
`0600`.

## The menu

Lua defines an arbitrary menu tree. An item with no action is a submenu. Dotted ids
infer their parent, or set `parent` explicitly:

```lua
return {
  hotkey = { key = "space", mods = { "option" } },
  items = {
    { id = "root", label = "Go" },
    { id = "dev", label = "Development", symbol = "hammer", aliases = { "code" } },
    {
      id = "dev.server",
      label = "Run local server",
      detail = "Opens in Terminal",
      shell = "cd ~/code/my-app && npm run dev",
    },
    { id = "dev.docs", label = "Docs", url = "https://developer.apple.com/documentation/" },
    { id = "dev.xcode", label = "Xcode", open = "/Applications/Xcode.app" },
    { id = "dev.finder", label = "Reveal", applescript = 'tell application "Finder" to open home' },
  },
}
```

| Field | Meaning |
|---|---|
| `id` / `parent` | Dotted ids define the tree; `parent` overrides |
| `label` | Row text |
| `title` | Header text while the submenu is open; defaults to `label` |
| `detail` | Subtitle (see `detail_mode`); replaced by a breadcrumb while searching |
| `symbol` | SF Symbol name |
| `icon` | Path to an image file, `~` allowed; wins over `symbol` |
| `aliases` | Extra routes for `orbitctl`, also searchable |
| `provider` | Name of a function in `providers` that fills this submenu at runtime |
| `shell` / `applescript` / `open` / `url` / `action` | What the row does |

Rows are searchable by label, detail, leaf id and aliases, so `install.editor.zed` is
found by typing `zed`.

### Actions and the query

`shell` always opens in Terminal and is the default action type. The command is
Base64-transported into the terminal session, so quotes, newlines, pipes and redirects
survive intact. `applescript` goes to `/usr/bin/osascript`, `open` launches a bundle
through `NSWorkspace`, and `url` opens through the default handler.

Any of them may contain `{query}`, replaced by what the user typed and escaped for its
destination — shell-quoted, percent-encoded, or AppleScript-escaped:

```lua
{ id = "install.query", label = "Install What I Typed", shell = "brew install {query}" }
```

**A static item cannot usefully carry `{query}`.** Rows are filtered by fuzzy match, so
typing the argument filters away the row meant to receive it: `ripgrep` inside Install
scores no match against "Install What I Typed" and the list comes back empty. Use a
provider for anything that acts on what you typed — provider rows are appended after
filtering, so they always survive. `{query}` on a *provider* row works exactly as
described above, and the shipped `plugins/brew.lua` is the pattern to copy.

`action` handlers receive the query as their argument and may use the host helpers:

```lua
{
  id = "dev.notify",
  label = "Notify",
  action = function(query)
    terminal("printf '%s\\n' " .. string.format("%q", query))
    osascript('display notification "Started" with title "Orbit"')
  end,
}
```

`run(command)` is an alias of `terminal(command)`. Lua has no `io`, and `os.execute` is
removed: all external execution goes through `terminal`, `run` or `osascript` and is
logged by the host.

### Providers

A submenu with `provider = "name"` gets its rows at runtime, and the provider runs
while that submenu is open — entering it is what fills it.

A provider is called with the current query in an isolated state with **no** execution
helpers and a 0.15s budget, so it must be a pure function of the query. It *describes*
an action and the host runs it:

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

Provider rows accept `label`, `detail`, `symbol`, `icon`, `value` (used for the row id)
and the same four action fields. A row with no action is informational. Because
providers are dumped and reloaded into a fresh state, they must be serialisable — no
upvalues beyond `_ENV`.

### Plugins

`~/.config/orbit` is on `package.path`, so a config splits up like a Neovim one.
`require "plugins.git"` resolves `~/.config/orbit/plugins/git.lua`; `~/.config/orbit/lua/`
works too. C modules are disabled. A plugin returns `items` and/or `providers`, and its
dotted ids can hang rows off any existing submenu:

```lua
for _, name in ipairs({ "git", "docker" }) do
  local ok, plugin = pcall(require, "plugins." .. name)
  if ok and type(plugin) == "table" then
    for _, entry in ipairs(plugin.items or {}) do items[#items + 1] = entry end
    for key, fn in pairs(plugin.providers or {}) do providers[key] = fn end
  end
end
```

A global `orbit` table exposes `config_dir`, `plugin_dir`, `home` and `can_execute`.

## Vim mode

Off by default. `vim = true` in `config.lua` turns the panel modal; it opens in NORMAL.

| Key | NORMAL | INSERT |
|---|---|---|
| `j` / `k` | move down / up | types |
| `/` | clear the query and start typing | types |
| `i` | resume typing where the cursor was | types |
| `a` | append at the end of the query | types |
| `s` | replace the query and start typing | types |
| `Escape` | clear the query, then go back, then hide | return to NORMAL |
| `Enter` | activate | activate |

Escape is the only key whose meaning differs by mode, which is what makes the useful
loop work: `/foo`, `Escape`, then `j`/`k` through the filtered results. In NORMAL it
keeps the behaviour it has without vim mode.

Unmapped keys are swallowed in NORMAL, so letters never leak into the field. Anything
with Command or Control passes through, so system shortcuts still work. Arrow keys and
Enter behave the same in both modes. The current mode is shown at the right of the
header, muted in NORMAL and accent-coloured in INSERT.

## Theming

`theme.lua` is the entire appearance surface — spacing, sizing and typography included,
because nothing else is reachable from Lua. See `Config/theme.lua` for the full token
list with defaults.

One base `font_size` drives a proportional type scale (caption .83, small .92, body 1.0,
title 1.17, heading 1.33, icon 1.5), and `spacing_scale` multiplies every spacing token,
so either one alone rescales the panel coherently. The panel is content-sized: it shrinks
to its rows and scrolls only past `max_height`.

### Colour schemes

`palette` imports an external scheme and seeds `bg`, `surface`, `fg`, `fg_muted`,
`accent`, `border` and `selection_bg`. Any token you set explicitly still wins.

```lua
palette = "auto",         -- follow ~/.config/theme, so `set-theme` retints this too
palette = "kanagawa",     -- a name
palette = "~/schemes/dracula.yaml",
```

A bare name is searched in order:

```
~/.config/orbit/themes/<name>.{toml,yaml,yml,conf,theme}
~/omarchy/themes/<name>/colors.toml
~/.config/{kitty,ghostty,btop}/themes/<name>
```

Supported formats — all flat `key → hex`, read by one parser:

| Format | Looks like | Keys used |
|---|---|---|
| Base16 / Base24 YAML | `base00: "1e1e2e"` | `base00`–`base0F`, flat or under `palette:` |
| Omarchy `colors.toml` | `accent = "#89b4fa"` | `background`, `foreground`, `accent`, `selection`, `muted`, … |
| kitty `.conf` | `background  #1e1e2e` | `background`, `foreground`, `selection_background`, `color0`–`color15` |
| ghostty | `palette = 4=#7aa2f7` | same, plus indexed `palette` entries |
| btop `.theme` | `theme[main_bg]="#1e1e2e"` | `main_bg`, `main_fg`, `hi_fg`, `selected_bg`, `inactive_fg` |

Hex may be `#rrggbb`, `rrggbb`, `#rgb` or `0xaarrggbb`.
