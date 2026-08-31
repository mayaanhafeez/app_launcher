-- A provider attached to `root`, so it runs on every keystroke at the top level and
-- adds rows next to the app results — a calculator and web fallbacks.
--
-- A provider is dumped to bytecode and reloaded into a fresh sandbox on each call, so
-- upvalues from this file would arrive nil. Everything it needs lives inside it.

return {
  providers = {
    smart = function(query)
      if query == "" then return {} end
      local rows = {}

      local function asquote(text)
        return (text:gsub("\\", "\\\\"):gsub('"', '\\"'))
      end
      local function copyRow(label, detail, symbol, value, text)
        return {
          label = label, detail = detail, symbol = symbol, value = value,
          applescript = 'set the clipboard to "' .. asquote(text) .. '"\n'
            .. 'display notification "Copied ' .. asquote(text) .. '" with title "Orbit"',
        }
      end

      -- Calculator: only when the query is nothing but arithmetic.
      -- Needs a digit and an operator, so a bare number is left to the converter below.
      local expression = query:match("^[%d%s%+%-%*/%%%^%(%)%.]+$")
      if expression and expression:match("%d") and expression:match("[%+%-%*/%%%^]") then
        local chunk = load("return " .. expression)
        if chunk then
          local ok, value = pcall(chunk)
          if ok and type(value) == "number" and value == value
             and value ~= math.huge and value ~= -math.huge then
            local text = (value == math.floor(value) and math.abs(value) < 1e15)
              and string.format("%d", value)
              or string.format("%.10g", value)
            rows[#rows + 1] = copyRow("= " .. text, "Copy the result", "equal.square", "calc", text)
          end
        end
      end

      -- Hex / decimal, either direction.
      local hex = query:match("^0[xX](%x+)$")
      if hex then
        rows[#rows + 1] = copyRow("= " .. tostring(tonumber(hex, 16)), "Hex to decimal",
                                  "number", "hex2dec", tostring(tonumber(hex, 16)))
      elseif query:match("^%d+$") and #query < 15 then
        local value = string.format("0x%X", tonumber(query))
        rows[#rows + 1] = copyRow("= " .. value, "Decimal to hex", "number", "dec2hex", value)
      end

      if #query >= 2 then
        rows[#rows + 1] = { label = "Search Google", detail = query, symbol = "magnifyingglass",
                            value = "google", url = "https://www.google.com/search?q={query}" }
        rows[#rows + 1] = { label = "Search GitHub", detail = query, symbol = "curlybraces",
                            value = "github", url = "https://github.com/search?q={query}&type=repositories" }
      end
      return rows
    end,
  },
}
