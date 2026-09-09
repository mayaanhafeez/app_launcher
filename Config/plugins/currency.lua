-- Currency conversion. Type `50 eur to usd`, or just `eur usd` for the rate.
--
-- This cannot be a provider, and that is the whole design constraint. A provider is
-- re-loaded into a throwaway sandbox on every keystroke with `io` nil'd, no execution
-- globals and a 0.15s budget -- it is a pure function of the query and has no way to
-- reach the network. So it is a `command`, like `plugins/find.lua`.
--
-- **The rates are cached per base currency per day, and that matters more here than
-- anywhere else.** A command row runs while you type, so `50 eur to usd` would be five
-- or six HTTP requests to spell out. The cache file is keyed by base *and* date, so the
-- first keystroke that names a base fetches once and every later one reads a local
-- file; a new day misses and re-fetches. `commands.cache_size` does not help by itself,
-- because each distinct query is its own cache entry.
--
-- Rates are the ECB's daily reference set via api.frankfurter.dev -- no API key, no
-- attribution requirement, and one fetch returns every currency against the base.
--
-- Parsing is deliberately loose: pick the first number as the amount (default 1), and
-- take three-letter words as the currency codes. "to" survives that filter by being two
-- letters, so `50 eur to usd` and `50 eur usd` parse identically.

local SCRIPT = [==[
q={query}
[ -z "$q" ] && exit 0

amount=$(printf '%s\n' "$q" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+([.][0-9]+)?$/) { print $i; exit } }')
[ -z "$amount" ] && amount=1
set -- $(printf '%s\n' "$q" | awk '{ for (i = 1; i <= NF; i++) if (tolower($i) ~ /^[a-z][a-z][a-z]$/) printf "%s ", toupper($i) }')
from=$1; to=$2
[ -z "$from" ] || [ -z "$to" ] && exit 0

# One fetch per base per day. `-s` keeps curl's progress meter out of the rows, and a
# failed fetch leaves no file rather than caching an error page.
dir="${XDG_CACHE_HOME:-$HOME/.cache}/kitsune"
cache="$dir/fx-$from-$(date +%Y%m%d).json"
if [ ! -s "$cache" ]; then
  mkdir -p "$dir"
  curl -fsS --max-time 4 "https://api.frankfurter.dev/v1/latest?base=$from" -o "$cache.tmp" 2>/dev/null &&
    mv "$cache.tmp" "$cache" || rm -f "$cache.tmp"
fi
[ -s "$cache" ] || {
  printf '{"label":"No rates for %s","detail":"Unknown currency, or the fetch failed","symbol":"exclamationmark.triangle"}\n' "$from"
  exit 0
}

# The payload is one flat object: {"amount":1.0,"base":"EUR","date":"...","rates":{...}}.
# Splitting on commas makes every rate its own record, so the one naming the target
# currency reduces to its number once the non-numeric characters are stripped.
rate=$(awk -v to="$to" 'BEGIN { RS = "," } index($0, "\"" to "\":") { gsub(/[^0-9.]/, "", $0); print; exit }' "$cache")
[ -z "$rate" ] && {
  printf '{"label":"No rate for %s","detail":"%s is not in the %s table","symbol":"exclamationmark.triangle"}\n' "$to" "$to" "$from"
  exit 0
}

awk -v a="$amount" -v r="$rate" -v f="$from" -v t="$to" 'BEGIN {
  v = a * r
  fmt = (v >= 1 || v == 0) ? "%.2f" : "%.6g"
  value = sprintf(fmt, v)
  printf "{\"label\":\"%s %s\",\"detail\":\"%s %s  ·  1 %s = %.6g %s\",\"symbol\":\"dollarsign.circle\"," \
         "\"value\":\"fx\",\"applescript\":\"set the clipboard to \\\"%s\\\"\"}\n",
         value, t, a, f, f, r, t, value
}'
]==]

local item, group = require("item").item, require("item").group

return {
  items = {
    group("currency", "Currency", "dollarsign.circle", { "fx", "convert", "rate", "exchange" }),
    item("currency.convert", "Convert", {
      symbol = "arrow.left.arrow.right", title = "Currency  ·  e.g. 50 eur to usd",
      detail = "Type an amount and two currency codes",
      command = SCRIPT,
    }),
  },
}
