-- Search the web for whatever is typed.
--
-- This has to be a provider, not static rows: a static row goes through the fuzzy
-- filter, so typing the search term would remove the very row meant to consume it.
-- Provider rows are appended *after* the filter, which is what makes {query} work.
--
-- A provider is re-loaded into an isolated state per keystroke -- no io, no terminal,
-- no osascript, on a 0.15s budget -- so it must be a pure function of the query. It
-- *describes* an action and the host runs it.
local item = require("item").item

return {
  items = {
    item("search", "Search", { symbol = "magnifyingglass", provider = "websearch",
                               detail = "Type, then pick a destination" }),
  },
  providers = {
    websearch = function(query)
      if query == "" then return {} end
      return {
        { label = "Google " .. query, symbol = "globe", value = "google",
          url = "https://www.google.com/search?q={query}" },
        { label = "GitHub " .. query, symbol = "chevron.left.forwardslash.chevron.right", value = "github",
          url = "https://github.com/search?q={query}" },
        { label = "Man page for " .. query, symbol = "doc.text", value = "man",
          shell = "man {query}" },
      }
    end,
  },
}
