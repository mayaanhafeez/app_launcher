-- A few macOS panes, and Kitsune's own files.
--
-- `settings` is not an alias here: `plugins/settings.lua` claims that id, and an exact
-- id beats an alias, so an alias by that name could never resolve.
local item, group = require("item").item, require("item").group

return {
  items = {
    group("setup", "Setup", "gearshape", { "config" }),
    item("setup.system", "System Settings", { open = "/System/Applications/System Settings.app" }),
    item("setup.network", "Network", { url = "x-apple.systempreferences:com.apple.Network-Settings.extension" }),
    item("setup.bluetooth", "Bluetooth", { url = "x-apple.systempreferences:com.apple.BluetoothSettings" }),
    item("setup.keyboard", "Keyboard", { url = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension" }),
    item("setup.trackpad", "Trackpad", { url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension" }),
    item("setup.security", "Privacy & Security", { url = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension" }),
    item("setup.config", "Kitsune Config", { shell = "${EDITOR:-nano} ~/.config/kitsune/config.lua" }),
    item("setup.theme", "Kitsune Theme", { shell = "${EDITOR:-nano} ~/.config/kitsune/theme.lua" }),
  },
}
