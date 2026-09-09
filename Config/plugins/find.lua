-- File search, backed by Spotlight's index.
--
-- Kitsune's built-in path mode (`/` or `~` at the top level) is *navigation*: it splits
-- the query at its last separator and lists that one directory. It never descends and
-- never looks inside a file, so it only helps when you already know roughly where the
-- thing is. This is the other half -- `mdfind`, which reads the same index Spotlight
-- does, so a full-text search over the whole disk returns in milliseconds.
--
-- Three constraints shape the file:
--
-- 1. **`command`, not `provider`.** A provider is re-loaded into a sandbox per
--    keystroke with `io` nil'd and no execution globals, so it is a pure function of
--    the query. Only the host can spawn `mdfind`.
--
-- 2. **The command filters on `{query}` itself.** Command rows are appended *after*
--    the fuzzy filter, exactly like provider rows, so nothing narrows them for you.
--
-- 3. **Rows are emitted as JSON, one per line, carrying `open`.** The tab-separated
--    form's third field is `shell`, which would open a terminal window just to hand a
--    path to `open`. A JSON row's `open` goes straight to NSWorkspace, and Tab on the
--    row still gives Reveal in Finder / Copy Path / Open With.
--
-- An empty query -- or one that looks like a flag, since mdfind has no `--` separator
-- to end its options -- exits before running anything: mdfind prints its usage to stdout,
-- so a bad invocation would arrive as rows rather than as an error.

-- Path in, one JSON row out: basename as the label, containing directory as the detail
-- with $HOME written back as `~`.
local ROWS = [==[
awk -v home="$HOME" '
function esc(s,   out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\"" || c == "\\") out = out "\\" c
    else if (c == "\t") out = out " "
    else out = out c
  }
  return out
}
{
  path = $0
  if (path == "") next
  n = split(path, parts, "/")
  name = parts[n]
  dir = substr(path, 1, length(path) - length(name) - 1)
  if (dir == "") dir = "/"
  if (index(dir, home) == 1) dir = "~" substr(dir, length(home) + 1)
  printf "{\"label\":\"%s\",\"detail\":\"%s\",\"symbol\":\"doc\",\"value\":\"%s\",\"open\":\"%s\"}\n",
         esc(name), esc(dir), esc(path), esc(path)
}'
]==]

-- `head` bounds the output before awk ever sees it; `commands.max_rows` is the backstop.
local function search(flags)
  return 'q={query}; case "$q" in ""|-*) exit 0 ;; esac; mdfind ' .. flags ..
         ' "$q" 2>/dev/null | head -50 | ' .. ROWS
end

local item, group = require("item").item, require("item").group

return {
  items = {
    group("find", "Find Files", "doc.text.magnifyingglass",
          { "mdfind", "spotlight", "file-search" }),
    item("find.name", "By Name", {
      symbol = "textformat", detail = "Filenames, anywhere Spotlight indexes",
      command = search("-name"),
    }),
    item("find.content", "By Content", {
      symbol = "text.magnifyingglass", detail = "Full text inside files",
      command = search(""),
    }),
    item("find.home", "By Content in Home", {
      symbol = "house", detail = "Full text under ~",
      command = 'q={query}; case "$q" in ""|-*) exit 0 ;; esac; mdfind -onlyin "$HOME" "$q" 2>/dev/null | head -50 | ' .. ROWS,
    }),
  },
}
