-- "Act on what I typed" has to be a provider, not a static item.
--
-- A static row with {query} in it is filtered by the very text you want to pass it:
-- type "ripgrep" inside Install and the row scores no fuzzy match and disappears.
-- Provider rows are appended after filtering, so they always survive.

return {
  providers = {
    brew = function(query)
      if query == "" then return {} end
      -- Only offer this for something that could plausibly be a package name.
      if not query:match("^[%w@%+%-%._/]+$") then return {} end
      return {
        { label = "brew install " .. query, detail = "Homebrew formula",
          symbol = "shippingbox", value = "formula", shell = "brew install {query}" },
        { label = "brew install --cask " .. query, detail = "Homebrew app",
          symbol = "macwindow.badge.plus", value = "cask", shell = "brew install --cask {query}" },
        { label = "brew info " .. query, detail = "Look before you leap",
          symbol = "info.circle", value = "info", shell = "brew info {query} | less" },
      }
    end,
  },
}
