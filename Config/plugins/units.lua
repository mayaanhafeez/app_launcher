-- Unit conversion: `10 km to mi`, `72f`, `500 mb in gib`, `2 cups to ml`.
--
-- This is a **provider**, where `plugins/currency.lua` had to be a `command`, and the
-- difference is the whole reason they are separate files. A provider is dumped to
-- bytecode and re-loaded into a fresh sandbox on every keystroke -- no `io`, no
-- execution globals, a 0.15s budget -- so it can only compute from the query. Currency
-- needs a rate off the network and cannot live there. A unit conversion is a
-- multiplication, so it can, and it costs no process at all while you type.
--
-- That sandbox is also why everything below lives *inside* the function: a provider is
-- serialized with no upvalues beyond `_ENV`, so a table hoisted to the file scope would
-- arrive nil.
--
-- Both units are required, except for temperature, where a single one (`72f`) shows the
-- other two -- that is the one case where the query is unambiguous on its own.

return {
  items = {
    { id = "convert", label = "Convert", symbol = "arrow.left.arrow.right",
      title = "Convert  ·  e.g. 10 km to mi",
      detail = "Length, mass, volume, data, time, speed, temperature",
      aliases = { "units", "unit", "uc" }, provider = "units" },
  },
  providers = {
    units = function(query)
      if query == "" then return {} end

      -- unit -> { dimension, factor to the dimension's base unit }.
      local U = {
        -- length, base metre
        mm = { "length", 0.001 }, cm = { "length", 0.01 }, m = { "length", 1 },
        km = { "length", 1000 },
        ["in"] = { "length", 0.0254 }, inch = { "length", 0.0254 }, inches = { "length", 0.0254 },
        ft = { "length", 0.3048 }, foot = { "length", 0.3048 }, feet = { "length", 0.3048 },
        yd = { "length", 0.9144 }, yard = { "length", 0.9144 }, yards = { "length", 0.9144 },
        mi = { "length", 1609.344 }, mile = { "length", 1609.344 }, miles = { "length", 1609.344 },
        nmi = { "length", 1852 },
        -- mass, base kilogram
        mg = { "mass", 1e-6 }, g = { "mass", 0.001 }, kg = { "mass", 1 },
        t = { "mass", 1000 }, tonne = { "mass", 1000 }, tonnes = { "mass", 1000 },
        oz = { "mass", 0.028349523125 }, lb = { "mass", 0.45359237 }, lbs = { "mass", 0.45359237 },
        pound = { "mass", 0.45359237 }, pounds = { "mass", 0.45359237 }, st = { "mass", 6.35029318 },
        -- volume, base litre
        ml = { "volume", 0.001 }, l = { "volume", 1 }, litre = { "volume", 1 }, liter = { "volume", 1 },
        litres = { "volume", 1 }, liters = { "volume", 1 },
        tsp = { "volume", 0.00492892159375 }, tbsp = { "volume", 0.01478676478125 },
        floz = { "volume", 0.0295735295625 }, cup = { "volume", 0.2365882365 },
        cups = { "volume", 0.2365882365 }, pt = { "volume", 0.473176473 },
        qt = { "volume", 0.946352946 }, gal = { "volume", 3.785411784 },
        -- data, base byte. The decimal and binary prefixes are both here on purpose:
        -- `500 mb in gib` is exactly the question this is for.
        b = { "data", 1 }, kb = { "data", 1e3 }, mb = { "data", 1e6 }, gb = { "data", 1e9 },
        tb = { "data", 1e12 }, kib = { "data", 1024 }, mib = { "data", 1048576 },
        gib = { "data", 1073741824 }, tib = { "data", 1099511627776 },
        -- time, base second
        ms = { "time", 0.001 }, s = { "time", 1 }, sec = { "time", 1 }, secs = { "time", 1 },
        min = { "time", 60 }, mins = { "time", 60 }, h = { "time", 3600 }, hr = { "time", 3600 },
        hour = { "time", 3600 }, hours = { "time", 3600 }, d = { "time", 86400 },
        day = { "time", 86400 }, days = { "time", 86400 }, wk = { "time", 604800 },
        week = { "time", 604800 }, weeks = { "time", 604800 },
        -- speed, base metre/second
        mps = { "speed", 1 }, kmh = { "speed", 1 / 3.6 }, kph = { "speed", 1 / 3.6 },
        mph = { "speed", 0.44704 }, kn = { "speed", 1852 / 3600 }, knot = { "speed", 1852 / 3600 },
        knots = { "speed", 1852 / 3600 },
        -- temperature is affine, not linear, so it carries no factor and is converted
        -- through celsius by the two helpers below.
        c = { "temp" }, celsius = { "temp" }, f = { "temp" }, fahrenheit = { "temp" },
        k = { "temp" }, kelvin = { "temp" },
      }
      local canonical = {
        celsius = "c", fahrenheit = "f", kelvin = "k",
        inch = "in", inches = "in", foot = "ft", feet = "ft", yard = "yd", yards = "yd",
        mile = "mi", miles = "mi", pound = "lb", pounds = "lb", lbs = "lb",
        litre = "l", liter = "l", litres = "l", liters = "l", cups = "cup",
        sec = "s", secs = "s", mins = "min", hr = "h", hour = "h", hours = "h",
        day = "d", days = "d", week = "wk", weeks = "wk", knot = "kn", knots = "kn",
        kph = "kmh", tonne = "t", tonnes = "t",
      }

      local text = query:lower():gsub(",", "")
      local amount, rest = text:match("^%s*(%-?%d+%.?%d*)%s*(.*)$")
      if not amount then return {} end
      amount = tonumber(amount)
      if not amount then return {} end

      local tokens = {}
      for word in rest:gmatch("%a+") do tokens[#tokens + 1] = word end
      local from = tokens[1]
      if not from or not U[from] then return {} end

      -- `in` is both a connector and inches, so it only counts as a connector when a
      -- real unit follows it: `10 cm in inches` versus `10 cm to in`.
      local to
      for index = 2, #tokens do
        local token = tokens[index]
        local connector = token == "to" or token == "as" or token == "into"
          or (token == "in" and tokens[index + 1] ~= nil)
        if not connector then to = token; break end
      end
      if to and not U[to] then return {} end

      local dimension = U[from][1]
      if to and U[to][1] ~= dimension then return {} end

      local function toCelsius(unit, value)
        if unit == "f" or unit == "fahrenheit" then return (value - 32) * 5 / 9 end
        if unit == "k" or unit == "kelvin" then return value - 273.15 end
        return value
      end
      local function fromCelsius(unit, value)
        if unit == "f" then return value * 9 / 5 + 32 end
        if unit == "k" then return value + 273.15 end
        return value
      end
      local function pretty(value)
        if value ~= value or value == math.huge or value == -math.huge then return nil end
        local absolute = math.abs(value)
        local text = (absolute ~= 0 and (absolute < 0.001 or absolute >= 1e12))
          and string.format("%.6g", value)
          or string.format("%.6f", value)
        if text:find("%.") then text = text:gsub("0+$", ""):gsub("%.$", "") end
        return text
      end

      -- Return copies the number alone: the row already says what the unit is, and a
      -- pasted "12.7 cm" is rarely what was wanted.
      local function row(value, unit)
        local text = pretty(value)
        if not text then return nil end
        local escaped = text:gsub("\\", "\\\\"):gsub('"', '\\"')
        return {
          label = text .. " " .. unit,
          detail = query .. "  ·  copy " .. text,
          symbol = "arrow.left.arrow.right",
          value = "unit-" .. unit,
          applescript = 'set the clipboard to "' .. escaped .. '"\n'
            .. 'display notification "Copied ' .. escaped .. '" with title "Kitsune"',
        }
      end

      local targets = {}
      if to then
        targets[1] = canonical[to] or to
      elseif dimension == "temp" then
        -- A lone temperature is unambiguous, so answer with the other two scales.
        local unit = canonical[from] or from
        for _, candidate in ipairs({ "c", "f", "k" }) do
          if candidate ~= unit then targets[#targets + 1] = candidate end
        end
      else
        return {}
      end

      local rows = {}
      for _, target in ipairs(targets) do
        local converted
        if dimension == "temp" then
          converted = fromCelsius(target, toCelsius(from, amount))
        else
          converted = amount * U[from][2] / U[target][2]
        end
        local built = row(converted, target)
        if built then rows[#rows + 1] = built end
      end
      return rows
    end,
  },
}
