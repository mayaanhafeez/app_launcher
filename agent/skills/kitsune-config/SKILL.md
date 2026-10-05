---
name: kitsune-config
description: Edit a Kitsune launcher config in ~/.config/kitsune — add or reorder menu items, change hotkeys and settings, pick a colour scheme or restyle the panel in theme.lua, and check the result with kitsunectl. Use whenever the user wants to change what Kitsune shows, how it looks, or how it is opened. For writing a new plugin (a provider, a command-backed menu), use kitsune-plugin instead.
---

# Editing a Kitsune config

Kitsune is a macOS keyboard launcher. AppKit owns every pixel of layout; Lua only
supplies **data** — a flat list of items, plus settings. Everything lives in
`~/.config/kitsune` and reloads on save, so there is no restart step.

## Before you edit

1. Read `~/.config/kitsune/config.lua` first. Every setting Kitsune reads is listed
   there **at its default, with a comment explaining it** — it is the settings
   reference. Change a value in place; do not guess a key that is not in the file.
2. If `~/.config/kitsune` is missing or has no `config.lua`, launch the app once (or
   use its menu bar item → Open Config Folder): Kitsune copies its shipped templates
   in on first launch. Never write into the `.app` bundle.
3. Assume the files are the user's own. Keep their comments, ordering and style.

## Layout

```
config.lua     settings only, plus the `menus` and `plugins` lists
theme.lua      appearance only: colours, geometry, spacing, type, placement
menus/*.lua    this config's own rows, one file per top-level menu
plugins/*.lua  self-contained pieces, each loaded only if named in `plugins`
lua/item.lua   the item() / group() row constructors — the field reference
lua/loader.lua merges the two lists; each file returns { items = ..., providers = ... }
colour_schemes/  shipped palettes          themes/  the user's overrides (searched first)
```

**Order is the sort key.** The order of `menus` and `plugins` in `config.lua` is the
order of the top-level rows, and the order inside a file is the order of that menu.
To move a row, move its line.

## Menu items

```lua
local item, group = require("item").item, require("item").group

return {
  items = {
    group("dev", "Development", "hammer", { "code" }),       -- id, label, SF Symbol, aliases
    item("dev.server", "Run Server", { detail = "npm run dev", shell = "cd ~/code/app && npm run dev" }),
    item("dev.docs", "Docs", { url = "https://example.com/docs" }),
  },
}
```

- **Dotted ids infer the parent**: `dev.server` sits under `dev`. `parent = "..."`
  overrides it. The item with `id = "root"` is the top level.
- An item with **no action** is a submenu. Actions, highest priority first:
  `action = function(query) ... end` (Lua, with `terminal`/`run`/`osascript`),
  `shell` (runs in the user's terminal), `applescript`, `open` (a path), `url`.
- Other fields: `label`, `title` (header while open), `detail`, `symbol` (SF Symbol
  name), `icon` (image path, wins over `symbol`), `aliases` (searchable, and
  routable by `kitsunectl show`), `keep = true` (never filtered out by typing),
  `hidden = true` (not listed, but found by search and `invoke`).
- `{query}` in `shell`/`applescript`/`url` is replaced by what the user typed,
  escaped for that destination. **On a static row it only works with `keep = true`**:
  otherwise the text meant to fill `{query}` is fuzzy-matched against the label
  first and the row vanishes. Anything that acts on typed text is better as a
  provider (see kitsune-plugin).
- A `shell` row opens a terminal window. Prompts work: `read -r '?Name: ' name`.
  Something that should run silently belongs in `applescript` with `do shell script`.

To add a whole new top-level menu, create `menus/<name>.lua` returning
`{ items = { ... } }` and add `"<name>"` to `menus` in `config.lua` where it should
appear. To switch a plugin on or off, add or remove its name in `plugins`.

## Settings

All top-level keys of the table `config.lua` returns, each documented in place:
`hotkeys`, `back`, `shortcuts`, `menu_bar`, `apps`, `files`, `ranking`, `search`,
`provider_limits`, `commands`, `watch`, `terminal`, `clipboard`,
`show_search_only`, `vim`, `login_item`. A disabled block is spelled `false`
(`clipboard = false`), not deleted.

Hotkeys: `{ key = "space", mods = { "option" } }` toggles the panel;
add `route = "<id>"` to open a submenu, or `invoke = "<id>"` to run an item without
showing the panel. A chord macOS will not grant fails alone; the rest stay bound.

## Theme

`theme.lua` can only restyle — it cannot touch the menu. `palette = "<name>"` seeds
the colour roles from a scheme file, looked up in `themes/`, then any
`palette_paths` entries, then the shipped `colour_schemes/`. List `colour_schemes/`
to see the available names. Explicit colour keys (`bg`, `fg`, `accent`, …) override
the palette, so leave them commented out unless the user wants a role pinned.
`font_size` and `spacing_scale` each rescale the whole panel coherently; prefer them
to editing many tokens. `screens = { ... }` overrides values per display.

`tint = { mode, color, alpha, blur, screens, fade }` washes the screen behind the
open panel (off unless set; `tint = false` / `tint = "monochrome"` also work).
`color` is a role name (`bg` by default, so it follows the palette) or a hex value;
`monochrome` is a black dim, not a greyscale filter. A display's `tint` in `screens`
merges onto the global one.

## Check your work

Saving reloads automatically. Then confirm the load, because a broken config keeps
the last good menu and only reports the error:

```sh
kitsunectl reload          # "ok", or exits 1 with the Lua error and line
kitsunectl list <menu-id>  # the static rows of a menu, as JSON (provider rows excluded)
kitsunectl show <menu-id>  # open the panel there, for the user to look at
kitsunectl theme           # the palette name that actually resolved
```

If `kitsunectl` is not on PATH it lives at
`/Applications/KitsuneLauncher.app/Contents/MacOS/kitsunectl`. A load error also turns
the menu bar icon red, and its menu has Show Last Error.

Lua errors name the line where the **parser gave up**, which for a missing comma is
the line *after* the mistake — look one item up.

## Rules

- Keep layout out of Lua. There is no way to describe layout from a config, and no
  escape hatch; a visual change that `theme.lua` cannot express needs a change to the
  app, not the config.
- Do not make runtime data (command output, window titles, file names, clipboard
  text) choose what runs. Output fills `{value}` in a node's `on_select`; it never
  names a command itself.
- Full reference, including every theme token:
  https://github.com/mayaanhafeez/app_launcher/blob/main/docs/configuration.md
