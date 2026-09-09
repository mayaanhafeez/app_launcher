-- Turns the `menus` and `plugins` lists in config.lua into the flat `items` and
-- `providers` tables the host expects.
--
-- Both lists load through one function and one contract -- a module returning
-- `{ items = ..., providers = ... }` -- because they are the same thing to Kitsune.
-- The split is by origin, not by mechanism: `menus/` is this config's own content,
-- `plugins/` is what could be handed to someone else or deleted whole.
--
-- **Order is meaning.** LuaRuntime decodes each node with `order: index`, so a row's
-- position in the merged list is its sort key within its menu. The order of the lists
-- in config.lua is therefore the order of the top-level rows, and the order inside a
-- file is the order of that menu's rows. Moving a name up the list moves a row up the
-- panel; there is no other sort key to reach for.
--
-- **The pcall is load-bearing.** `reportingRequire` records a failed require in the
-- state's own registry and re-raises it, so a broken file is still reported three ways:
-- a red menu bar icon, Show Last Error, and the panel's banner. Catching it *here* is
-- what stops one bad file taking the whole menu down with it -- every other file still
-- loads, and the launcher still opens.

return function(config)
  local items = {}
  local providers = config.providers or {}

  local function merge(prefix, names)
    for _, name in ipairs(names or {}) do
      local ok, module = pcall(require, prefix .. name)
      if ok and type(module) == "table" then
        for _, entry in ipairs(module.items or {}) do items[#items + 1] = entry end
        for key, fn in pairs(module.providers or {}) do providers[key] = fn end
      end
    end
  end

  merge("menus.", config.menus)
  merge("plugins.", config.plugins)

  -- `menus` and `plugins` are this loader's vocabulary, not Kitsune's. Clearing them
  -- keeps the returned table to exactly the keys the host reads.
  config.menus, config.plugins = nil, nil
  config.items, config.providers = items, providers
  return config
end
