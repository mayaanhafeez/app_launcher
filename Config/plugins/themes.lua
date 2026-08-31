-- Every theme `set-theme` knows about, as one generated submenu. Picking one writes
-- ~/.config/theme, which the launcher watches: with `palette = "auto"` in theme.lua it
-- retints itself along with the rest of the system.

local themes = {
  "andromeda", "archriot", "blueridge-dark", "catppuccin-mocha", "dark-xp", "drive",
  "hinterlands", "kanagawa", "matte-black", "nord", "osaka-jade", "retro-82",
  "ristretto", "rose-pine", "rose-pine-moon", "tokyo-night", "tokyo-night-storm",
  "tomorrow-night-burns", "vanta-black",
}

local function pretty(name)
  return (name:gsub("%-", " "):gsub("(%a)([%w']*)", function(head, tail)
    return head:upper() .. tail
  end))
end

local items = {
  { id = "style.scheme", label = "Colour Scheme", title = "Set Theme", symbol = "swatchpalette",
    aliases = { "theme", "themes", "colours", "colors" }, detail = "Applies system-wide" },
}

for index, name in ipairs(themes) do
  items[#items + 1] = {
    id = "style.scheme." .. name,
    label = pretty(name),
    symbol = "circle.fill",
    detail = name,
    -- The shell here is not interactive, so ~/.zshrc never runs: use the real path.
    shell = "$HOME/.local/bin/set-theme " .. name,
  }
end

return { items = items }
