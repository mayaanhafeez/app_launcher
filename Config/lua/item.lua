-- Row constructors, and the reference for what a row may carry.
--
-- Every menu file and every plugin requires this rather than carrying its own copy.
-- There were four separate definitions of `item` before this file existed -- one in
-- config.lua and one in each plugin that built rows -- and nothing kept them in step.
--
-- `lua/` is on package.path, so this is `require "item"` from anywhere in the config.
--
-- Item fields:
--   id / parent   dotted ids infer the parent; an item with no action is a submenu
--   label         row text            title    header text when open (defaults to label)
--   detail        subtitle            symbol   SF Symbol name
--   icon          image file path     aliases  extra route names, also searchable
--   provider      name of a function in `providers` that supplies rows at query time
--   command       shell command whose stdout becomes rows while this menu is open
--   keep          skip the fuzzy filter; the row stays visible whatever is typed
--   hidden        never listed, but still reachable by search, alias and `invoke`
--   shell | applescript | open | url | action(query)
--
-- Any of shell/applescript/open/url may contain {query}, replaced by what is typed and
-- escaped for its destination. `action` handlers receive it as an argument.
--
-- `keep = true` is what makes {query} usable on a static item: an ordinary row goes
-- through the fuzzy filter, so typing the argument would remove the very row meant to
-- consume it. Kept rows sort below the search results.

local M = {}

function M.item(id, label, fields)
  fields = fields or {}
  fields.id = id
  fields.label = label
  return fields
end

-- A submenu. Nothing but the *absence* of an action makes a node a category, so a
-- group is `item` with the action left off -- named, because a bare `item` call with
-- no action reads like something was forgotten.
function M.group(id, label, symbol, aliases)
  return M.item(id, label, { symbol = symbol, aliases = aliases })
end

return M
