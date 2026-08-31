return {
  items = {
    { id = "root", label = "Go" },
    { id = "apps", parent = "root", label = "Applications", detail = "Installed applications", symbol = "square.grid.2x2" },
    { id = "system", parent = "root", label = "System", detail = "macOS controls", symbol = "gearshape" },
    { id = "system.settings", parent = "system", label = "System Settings", shell = "open -a 'System Settings'" },
    { id = "system.lock", parent = "system", label = "Lock Screen", shell = "/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend" },
    { id = "system.sleep", parent = "system", label = "Sleep", shell = "pmset sleepnow" },
    { id = "tools", parent = "root", label = "Tools", detail = "Everyday utilities", symbol = "hammer" },
    { id = "tools.activity", parent = "tools", label = "Activity Monitor", shell = "open -a 'Activity Monitor'" },
    { id = "tools.screenshot", parent = "tools", label = "Screenshot", shell = "open -a Screenshot" },
    { id = "tools.color", parent = "tools", label = "Digital Color Meter", shell = "open -a 'Digital Color Meter'" },
    { id = "tools.finder", parent = "tools", label = "Show Desktop in Finder", applescript = 'tell application "Finder" to open desktop' },
  },
  providers = {
    example = function(query)
      return { { label = "Query", detail = query, symbol = "magnifyingglass" } }
    end,
  },
}
