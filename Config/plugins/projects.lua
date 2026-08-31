-- Four lines of data become a submenu with five actions each. This is the pattern the
-- menu is built for: describe the data, generate the tree.

local projects = {
  { id = "launcher", label = "App Launcher", path = "~/personal/app_launcher" },
  { id = "settheme", label = "Set Theme",    path = "~/set-theme" },
  { id = "omarchy",  label = "Omarchy",      path = "~/omarchy", icon = "~/omarchy/icon.png" },
  { id = "aether",   label = "Aether",       path = "~/aether" },
}

local actions = {
  { id = "edit",   label = "Edit",           symbol = "chevron.left.forwardslash.chevron.right",
    command = "cd %s && ${EDITOR:-nvim} ." },
  { id = "shell",  label = "Terminal Here",  symbol = "terminal",  command = "cd %s && exec ${SHELL:-/bin/zsh}" },
  { id = "status", label = "Git Status",     symbol = "arrow.triangle.branch",
    command = "cd %s && git status && git log --oneline -12 && exec ${SHELL:-/bin/zsh}" },
  { id = "pull",   label = "Git Pull",       symbol = "arrow.down.circle", command = "cd %s && git pull" },
}

local items = {
  { id = "project", label = "Projects", symbol = "folder", aliases = { "proj", "repo" } },
}

for _, project in ipairs(projects) do
  items[#items + 1] = {
    id = "project." .. project.id,
    label = project.label,
    title = project.label,
    symbol = "folder.fill",
    icon = project.icon,
    detail = project.path,
    -- Typing inside a project greps it; see grepProvider below.
    provider = "grep_" .. project.id,
  }
  for _, action in ipairs(actions) do
    items[#items + 1] = {
      id = "project." .. project.id .. "." .. action.id,
      label = action.label,
      symbol = action.symbol,
      detail = project.path,
      shell = string.format(action.command, project.path),
    }
  end
  items[#items + 1] = {
    id = "project." .. project.id .. ".reveal",
    label = "Reveal in Finder",
    symbol = "macwindow",
    applescript = string.format('tell application "Finder" to open POSIX file "%s"',
      project.path:gsub("^~", os.getenv("HOME") or "~")),
  }
end

-- A provider is dumped to bytecode and reloaded without its upvalues, so a closure
-- over `path` would arrive nil. Compiling the path in as a literal avoids that.
local function grepProvider(path)
  return load(string.format([==[
    return function(query)
      if query == "" then return {} end
      local path = %q
      return {
        { label = "Search for " .. query, detail = path .. "  ·  grep -rn",
          symbol = "text.magnifyingglass", value = "grep",
          shell = "cd " .. path .. " && grep -rn --color=always {query} . | less -R" },
        { label = "Find files named " .. query, detail = path .. "  ·  find -iname",
          symbol = "doc.text.magnifyingglass", value = "find",
          shell = "cd " .. path .. " && find . -iname '*'{query}'*' -not -path './.git/*' | less" },
      }
    end
  ]==], path))()
end

local providers = {}
for _, project in ipairs(projects) do
  providers["grep_" .. project.id] = grepProvider(project.path)
end

return { items = items, providers = providers }
