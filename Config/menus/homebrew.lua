-- Installing and removing things. Both menus are Homebrew end to end, which is why
-- they share a file; `update` is separate because it is not only Homebrew.
--
-- `read -r '?Prompt: '` works because a `shell` item is `eval`ed inside a Terminal
-- window's own interactive shell, which leaves stdin on the tty. Piping the script into
-- a shell instead would put it on stdin -- exactly where `read` reads from -- and the
-- prompt would consume the script's own next line.
--
-- A `command = "..."` row is the other way to fill a menu: its stdout becomes rows
-- while the menu is open, one row per line, either tab-separated
-- `label<TAB>detail<TAB>shell-to-run` or a JSON object per line. It runs while you
-- type, so it must be a *read-only* query. Uncomment to try it:
--
--   item("brew", "Brew Search", { symbol = "shippingbox", detail = "Search Homebrew",
--     command = "brew search --formula {query} | head -50 | " ..
--               "awk '{ printf \"%s\\tformula\\tbrew install %s\\n\", $1, $1 }'" }),
local item, group = require("item").item, require("item").group

return {
  items = {
    -- Typing inside Install offers to install what you typed (see plugins/brew.lua).
    item("install", "Install", { symbol = "square.and.arrow.down", provider = "brew" }),
    item("install.formula", "Homebrew Formula", { shell = "read -r '?Formula: ' name; [[ -n $name ]] && brew install --formula $name" }),
    item("install.cask", "Homebrew App", { shell = "read -r '?Cask: ' name; [[ -n $name ]] && brew install --cask $name" }),
    item("install.update", "Update Homebrew", { shell = "brew update" }),
    item("install.upgrade", "Upgrade Everything", { shell = "brew update && brew upgrade && brew cleanup" }),
    group("install.development", "Development", "hammer"),
    item("install.development.node", "Node.js", { shell = "brew install node" }),
    item("install.development.go", "Go", { shell = "brew install go" }),
    item("install.development.python", "Python", { shell = "brew install python" }),
    item("install.development.rust", "Rust", { shell = "brew install rustup-init && rustup-init" }),
    item("install.development.java", "Java", { shell = "brew install openjdk" }),
    group("install.editor", "Editor", "doc.text"),
    item("install.editor.vscode", "Visual Studio Code", { shell = "brew install --cask visual-studio-code" }),
    item("install.editor.cursor", "Cursor", { shell = "brew install --cask cursor" }),
    item("install.editor.zed", "Zed", { shell = "brew install --cask zed" }),
    group("install.browser", "Browser", "globe"),
    item("install.browser.chrome", "Google Chrome", { shell = "brew install --cask google-chrome" }),
    item("install.browser.firefox", "Firefox", { shell = "brew install --cask firefox" }),
    item("install.browser.brave", "Brave", { shell = "brew install --cask brave-browser" }),
    group("install.terminal", "Terminal", "terminal"),
    item("install.terminal.ghostty", "Ghostty", { shell = "brew install --cask ghostty" }),
    item("install.terminal.iterm", "iTerm2", { shell = "brew install --cask iterm2" }),

    group("remove", "Remove", "trash", { "uninstall" }),
    item("remove.formula", "Homebrew Formula", { shell = "brew list --formula; read -r '?Remove formula: ' name; [[ -n $name ]] && brew uninstall --formula $name" }),
    item("remove.cask", "Homebrew App", { shell = "brew list --cask; read -r '?Remove cask: ' name; [[ -n $name ]] && brew uninstall --cask $name" }),
    item("remove.cleanup", "Homebrew Cleanup", { shell = "brew cleanup --prune=all" }),
  },
}
