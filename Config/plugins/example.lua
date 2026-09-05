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
