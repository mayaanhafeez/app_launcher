return {
  items = {
    { id = "root", label = "Go" },
    { id = "apps", parent = "root", label = "Applications", detail = "Installed applications", symbol = "square.grid.2x2" },
    { id = "system", parent = "root", label = "System", detail = "macOS controls", symbol = "gearshape" },
    { id = "system.settings", parent = "system", label = "System Settings", action = function() run("open -a 'System Settings'") end },
    { id = "system.lock", parent = "system", label = "Lock Screen", action = function() run("/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend") end },
    { id = "system.sleep", parent = "system", label = "Sleep", action = function() run("pmset sleepnow") end },
    { id = "tools", parent = "root", label = "Tools", detail = "Everyday utilities", symbol = "hammer" },
    { id = "tools.activity", parent = "tools", label = "Activity Monitor", action = function() run("open -a 'Activity Monitor'") end },
    { id = "tools.screenshot", parent = "tools", label = "Screenshot", action = function() run("open -a Screenshot") end },
    { id = "tools.color", parent = "tools", label = "Digital Color Meter", action = function() run("open -a 'Digital Color Meter'") end },
  },
  providers = {
    example = function(query)
      return { { label = "Query", detail = query, symbol = "magnifyingglass" } }
    end,
  },
}
