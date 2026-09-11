-- Keeping things current. Not folded into `homebrew.lua`: macOS, Kitsune itself and
-- the config reload have nothing to do with Homebrew.
local item, group = require("item").item, require("item").group

return {
  items = {
    group("update", "Update", "arrow.clockwise"),
    item("update.homebrew", "Homebrew Packages", { shell = "brew update && brew upgrade && brew cleanup" }),
    item("update.macos", "macOS Software Update", { shell = "softwareupdate --list; echo; read -r '?Install all updates? [y/N] ' answer; [[ $answer == [Yy]* ]] && sudo softwareupdate --install --all" }),
    item("update.kitsune", "KitsuneLauncher", { shell = "cd ~/personal/app_launcher && git pull && ./scripts/build-app.sh" }),
    item("update.reload", "Reload Lua Config", { shell = "~/.config/kitsune/reload 2>/dev/null || true" }),
  },
}
