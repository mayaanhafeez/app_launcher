-- Example plugin. Copy the plugins/ directory to ~/.config/kitsune/ and add its name
-- to the plugin list in config.lua. A plugin returns items and/or providers; ids are
-- dotted the same way, so it can hang rows off any existing submenu.

local function item(id, label, fields)
  fields = fields or {}
  fields.id = id
  fields.label = label
  return fields
end

return {
  items = {
    item("dev", "Development", { symbol = "hammer", aliases = { "code" } }),
    item("dev.here", "Terminal Here", { shell = "cd ~ && $SHELL" }),
    item("dev.grep", "Grep Home For What I Typed", {
      symbol = "text.magnifyingglass",
      shell = "grep -rn {query} ~ | less",
    }),
    -- A `command` fills a submenu from a subprocess while it is open. The output is
    -- text -- tab-separated `label`<TAB>`detail`, or JSON for the full set of fields --
    -- and `on_select` is what a row *does*, with `{value}` standing in for the row's
    -- own value (its label, unless the JSON form gave it one). The output never names
    -- a command of its own: `{value}` is quoted on the way in, so a filename with a
    -- space or a semicolon in it stays a filename.
    item("dev.branches", "Git Branches", {
      symbol = "arrow.triangle.branch",
      command = 'cd ~ && git branch --format "%(refname:short)\t%(subject)" 2>/dev/null',
      on_select = { shell = "cd ~ && git switch {value}" },
    }),
    item("dev.notify", "Say Hello", {
      symbol = "bell",
      action = function(query)
        osascript(string.format('display notification %q with title "Kitsune"',
          query ~= "" and query or "hello"))
      end,
    }),
  },
  providers = {},
}
