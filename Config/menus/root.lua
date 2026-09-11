-- The top of the menu, and the app list.
--
-- `root` is the one node that must exist -- LuaRuntime injects a bare one when a config
-- has none -- and it is the only place a provider runs on every keystroke at the top
-- level, which is what puts a calculator and a base conversion next to the app results.
local item = require("item").item

return {
  items = {
    item("root", "Go", { provider = "smart" }),
    item("apps", "Apps", { detail = "Installed applications", symbol = "square.grid.2x2",
                           aliases = { "app", "applications" } }),
  },
}
