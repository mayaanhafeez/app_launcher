-- Text conversions. Also self-contained, for the reason in smart.lua.
return {
  items = {
    { id = "text", label = "Text", title = "Convert Text", symbol = "textformat",
      aliases = { "case", "convert" }, provider = "text",
      detail = "Type, then pick a conversion" },
  },
  providers = {
    text = function(query)
      if query == "" then return {} end
      local function asquote(text)
        return (text:gsub("\\", "\\\\"):gsub('"', '\\"'))
      end
      local function title(text)
        return (text:gsub("(%a)([%w']*)", function(head, tail) return head:upper() .. tail:lower() end))
      end
      local words = {}
      for word in query:gmatch("[%w]+") do words[#words + 1] = word:lower() end

      local conversions = {
        { "UPPERCASE",  query:upper(),                    "arrow.up" },
        { "lowercase",  query:lower(),                    "arrow.down" },
        { "Title Case", title(query),                     "textformat.size" },
        { "snake_case", table.concat(words, "_"),         "minus" },
        { "kebab-case", table.concat(words, "-"),         "minus" },
        { "Reversed",   query:reverse(),                  "arrow.left.arrow.right" },
      }

      local rows = {}
      for _, item in ipairs(conversions) do
        local label, text, symbol = item[1], item[2], item[3]
        if text ~= "" then
          rows[#rows + 1] = {
            label = text, detail = label, symbol = symbol, value = label,
            applescript = 'set the clipboard to "' .. asquote(text) .. '"\n'
              .. 'display notification "Copied" with title "Kitsune"',
          }
        end
      end
      return rows
    end,
  },
}
