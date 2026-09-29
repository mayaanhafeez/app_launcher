---
name: kitsune-plugin
description: Write a Kitsune launcher plugin in ~/.config/kitsune/plugins — a menu whose rows come from Lua (a provider), from a shell command's output (a command menu), or from a Lua action — then register and test it. Use when the user wants Kitsune to search, list or act on something new (a CLI tool, an API, files, windows), or to fix or extend an existing plugin. For plain config edits, use kitsune-config.
---

# Writing a Kitsune plugin

A plugin is one Lua file, `~/.config/kitsune/plugins/<name>.lua`, returning
`{ items = { ... }, providers = { ... } }` — the same contract as a `menus/` file.
Plugins are not auto-discovered: **add `"<name>"` to `plugins` in `config.lua`** or
it never loads. Read one of the shipped plugins next to it before writing:
`brew.lua` (provider acting on typed text), `smart.lua` (provider with helpers),
`find.lua` and `currency.lua` (command menus), `projects.lua` (generated tree).

## Pick the row source

| The rows need to… | Use | Where it runs |
|---|---|---|
| be fixed | static `items` | — |
| be computed from what the user types | `provider` | sandboxed Lua, per keystroke |
| come from looking at the machine (a CLI, files, windows, the network) | `command` + `on_select` | a real process, debounced |
| do something only Lua can decide at activation | `action = function(query)` | the full config state |

## Static items and ids

```lua
local item, group = require("item").item, require("item").group

return {
  items = {
    group("notes", "Notes", "note.text", { "note" }),
    item("notes.new", "New Note", { shell = "${EDITOR:-nano} ~/notes/$(date +%F).md" }),
  },
}
```

Dotted ids infer the parent (`notes.new` → `notes`), so a plugin can hang rows under
any existing menu. Ids must be unique across the whole config.

## Providers

```lua
return {
  items = {
    { id = "hex", label = "Hex", symbol = "number", provider = "hex" },
  },
  providers = {
    hex = function(query)
      if query == "" then return {} end
      local n = tonumber(query)
      if not n then return {} end
      local text = string.format("0x%X", n)
      return {
        { label = text, detail = "Copy", symbol = "doc.on.clipboard", value = "hex",
          applescript = 'set the clipboard to "' .. text .. '"' },
      }
    end,
  },
}
```

A provider runs while **the item that declares it** is open (`provider = "hex"` on
`hex`), or on every top-level keystroke if declared on `root`. Its rows are added
*after* the fuzzy filter, which is why "act on what I typed" must be a provider.

Hard constraints — each one breaks a plugin silently if ignored:

- **No upvalues.** The function is `lua_dump`ed and reloaded into a fresh state per
  call, so any `local` from outside the function arrives `nil`. Define helpers
  *inside* it. To bake per-instance data in, compile it as a literal:
  `load(string.format("return function(query) local path = %q ... end", path))()`
  — see `projects.lua`.
- **No execution and no I/O.** There is no `io`, no `os.execute`, no `terminal` /
  `run` / `osascript` in a provider. It *describes* actions on the rows it returns
  and the host runs them when one is picked.
- **0.15 s budget** per call and a 1M-instruction ceiling. No loops over large data,
  no waiting.
- Row fields: `label` (required), `detail`, `symbol`, `icon`, `value` (names the
  row; defaults to the label), and one of `shell` / `applescript` / `open` / `url`.
  `{query}` in those is substituted and escaped. A row with no action is
  informational. There is no `action` function on a provider row.
- Building `applescript` from text: escape `\` and `"` yourself (see `asquote` in
  `smart.lua`); only `{query}` is escaped for you.

## Command menus

```lua
return {
  items = {
    { id = "procs", label = "Kill Process", symbol = "xmark.octagon",
      -- JSON rather than label<TAB>detail, so the row can show a name but carry a pid.
      command = [[q={query}; ps -axco pid=,comm= | awk -v q="$q" 'index(tolower($0), tolower(q)) {
        pid = $1; $1 = ""; sub(/^ +/, ""); gsub(/\\/, "\\\\"); gsub(/"/, "\\\"")
        printf "{\"label\":\"%s\",\"detail\":\"pid %s\",\"value\":\"%s\"}\n", $0, pid, pid
      }' | head -50]],
      on_select = { shell = "kill {value}" } },
  },
}
```

- stdout becomes rows while the menu is open: `label<TAB>detail` per line, or one
  JSON object per line with `label`, `detail`, `symbol`, `value`, `notice`.
- `{query}` in `command` arrives single-quoted, so assign it to a variable first
  (`q={query};`). The rows are **not** fuzzy-filtered for you, so the command must
  filter on the query itself — with `index()` or `grep -F`, not a regex built from
  what was typed.
- **Output is data, never behaviour.** What a row does comes only from the item's
  `on_select` (`shell` / `applescript` / `open` / `url`), with `{value}` filled in
  and escaped — `value` if the JSON gave one, otherwise the label. Never build a
  command out of output text: a window title or file name is attacker-writable.
- `applescript = 'do shell script "..."'` is a shell string inside an AppleScript
  string and Kitsune only escapes the outer layer: splice `{value}` with
  `quoted form of "{value}"`.
- It runs under `/bin/sh` with a GUI app's minimal PATH (Homebrew's bin dirs are
  added). A tool installed elsewhere needs its full path, or `commands.login = true`.
- **Degrade when the tool is missing** instead of printing nothing:
  `command -v jq >/dev/null || { echo '{"label":"jq is not installed","notice":true}'; exit 0; }`.
  Emit `notice` rows for "nothing found" and errors too.
- Keep it read-only and fast: it re-runs as the user types (debounced, killed after
  `commands.timeout`, output capped).

## Actions

`action = function(query) ... end` on an item runs in the config state, with
`terminal(cmd)` (alias `run`) and `osascript(source)` — the only ways to execute
anything; there is no `io` or `os.execute`. Prefer a declarative `shell`/`url`/…
when one will do: those also get the Copy as Shell Command/Copy URL row actions.

## Register, reload, test

1. Save `plugins/<name>.lua`, add `"<name>"` to `plugins` in `config.lua`.
2. `kitsunectl reload` — prints `ok`, or exits 1 with the error. A plugin that fails
   to load is reported (red menu bar icon, Show Last Error) while the rest of the
   menu keeps working, so a missing menu means: check the error first.
3. `kitsunectl list <item-id>` shows static rows; `kitsunectl show <item-id>` opens
   the panel there so the user can type and see provider or command rows, which
   `list` does not include. `kitsunectl invoke <id>` runs an item's action.
4. For a command menu, run the command yourself in `sh` with a sample query first —
   it is the fastest way to get the output format right.

Full reference: https://github.com/mayaanhafeez/app_launcher/blob/main/docs/configuration.md
