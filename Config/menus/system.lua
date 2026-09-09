-- The session: lock, sleep, and the three ways out.
local item, group = require("item").item, require("item").group

return {
  items = {
    item("system", "System", { symbol = "power", title = "Session", aliases = { "power", "power-menu" } }),
    item("system.screensaver", "Screensaver", { shell = "open -a ScreenSaverEngine" }),
    item("system.lock", "Lock", { shell = "/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend || pmset displaysleepnow" }),
    item("system.sleep", "Sleep", { shell = "pmset sleepnow" }),
    item("system.logout", "Log Out", { applescript = 'tell application "System Events" to log out' }),
    item("system.restart", "Restart", { applescript = 'tell application "System Events" to restart' }),
    item("system.shutdown", "Shut Down", { applescript = 'tell application "System Events" to shut down' }),
  },
}
