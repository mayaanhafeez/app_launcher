-- Keeping things current. Not folded into `homebrew.lua`: macOS updates have nothing
-- to do with Homebrew. There is no reload row -- the config reloads itself on save, and
-- the menu bar item has Reload Config for anything else.
local item, group = require("item").item, require("item").group

return {
  items = {
    group("update", "Update", "arrow.clockwise"),
    item("update.homebrew", "Homebrew Packages", { shell = "brew update && brew upgrade && brew cleanup" }),
    item("update.macos", "macOS Software Update", { shell = "softwareupdate --list; echo; read -r '?Install all updates? [y/N] ' answer; [[ $answer == [Yy]* ]] && sudo softwareupdate --install --all" }),
  },
}
