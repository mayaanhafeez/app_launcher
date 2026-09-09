-- Documentation, one row per thing worth having a shortcut to.
local item, group = require("item").item, require("item").group

return {
  items = {
    group("learn", "Learn", "book"),
    item("learn.shortcuts", "Keyboard Shortcuts", { url = "https://support.apple.com/102650" }),
    item("learn.macos", "macOS User Guide", { url = "https://support.apple.com/guide/mac-help/welcome/mac" }),
    item("learn.homebrew", "Homebrew", { url = "https://docs.brew.sh/" }),
    item("learn.neovim", "Neovim", { url = "https://neovim.io/doc/" }),
    item("learn.shell", "Zsh", { url = "https://zsh.sourceforge.io/Doc/" }),
    item("learn.lua", "Lua 5.4", { url = "https://www.lua.org/manual/5.4/" }),
  },
}
