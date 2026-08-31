return {
  items = {
    { id = "root", label = "Go" },
    { id = "apps", parent = "root", label = "Applications", detail = "Installed applications", symbol = "square.grid.2x2" },
    { id = "system", parent = "root", label = "System", detail = "macOS controls", symbol = "gearshape" },
    { id = "system.settings", parent = "system", label = "System Settings", action = function() run("open -a 'System Settings'") end },
    { id = "system.lock", parent = "system", label = "Lock Screen", action = function() run("/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend") end },
  },
  providers = {
    example = function(query)
      return { { label = "Query", detail = query, symbol = "magnifyingglass" } }
    end,
  },
}
