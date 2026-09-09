-- How the Mac looks. `plugins/settings.lua` addresses the same panes as part of the
-- full System Settings tree; these are the handful worth a top-level row.
local item, group = require("item").item, require("item").group

return {
  items = {
    group("style", "Style", "paintpalette"),
    -- No URL reaches the Wallpaper pane's search field, so this types into it.
    item("style.wallpaper", "Wallpaper", { applescript = 'tell application "System Settings" to activate\ntell application "System Events" to tell process "System Settings" to keystroke "wallpaper"' }),
    item("style.appearance", "Appearance", { url = "x-apple.systempreferences:com.apple.Appearance-Settings.extension" }),
    item("style.fonts", "Fonts", { open = "/System/Applications/Font Book.app" }),
    item("style.desktop", "Desktop & Dock", { url = "x-apple.systempreferences:com.apple.Desktop-Settings.extension" }),
    item("style.displays", "Displays", { url = "x-apple.systempreferences:com.apple.Displays-Settings.extension" }),
  },
}
