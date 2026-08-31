-- OrbitLauncher config. Copy to ~/.config/orbit/config.lua.
-- Reloads on save. `~/.config/orbit` is on package.path, so this behaves like a
-- Neovim config: split it up and `require` the pieces.
--
-- Item fields:
--   id / parent   dotted ids infer the parent; an item with no action is a submenu
--   label         row text            title    header text when open (defaults to label)
--   detail        subtitle            symbol   SF Symbol name
--   icon          image file path     aliases  extra route names, also searchable
--   provider      name of a function in `providers` that supplies rows at query time
--   shell | applescript | open | url | action(query)
--
-- Any of shell/applescript/open/url may contain {query}, replaced by what is typed
-- and escaped for its destination. `action` handlers receive it as an argument.

local function item(id, label, fields)
  fields = fields or {}
  fields.id = id
  fields.label = label
  return fields
end

local items = {
  -- A provider on `root` runs on every keystroke at the top level, so its rows
  -- appear next to the app results: a calculator, base conversion, web fallbacks.
  item("root", "Go", { provider = "smart" }),
  item("apps", "Apps", { detail = "Installed applications", symbol = "square.grid.2x2", aliases = { "app", "applications" } }),
  item("learn", "Learn", { symbol = "book" }),
  item("trigger", "Trigger", { symbol = "bolt" }),
  item("style", "Style", { symbol = "paintpalette" }),
  item("setup", "Setup", { symbol = "gearshape", aliases = { "settings" } }),
  -- Typing inside Install offers to install what you typed (see plugins/brew.lua).
  item("install", "Install", { symbol = "square.and.arrow.down", provider = "brew" }),
  item("remove", "Remove", { symbol = "trash", aliases = { "uninstall" } }),
  item("update", "Update", { symbol = "arrow.clockwise" }),
  item("about", "About", { symbol = "info.circle", url = "https://github.com/mayaanhafeez/app_launcher" }),
  item("system", "System", { symbol = "power", title = "Session", aliases = { "power", "power-menu" } }),

  item("system.screensaver", "Screensaver", { shell = "open -a ScreenSaverEngine" }),
  item("system.lock", "Lock", { shell = "/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend || pmset displaysleepnow" }),
  item("system.sleep", "Sleep", { shell = "pmset sleepnow" }),
  item("system.logout", "Log Out", { applescript = 'tell application "System Events" to log out' }),
  item("system.restart", "Restart", { applescript = 'tell application "System Events" to restart' }),
  item("system.shutdown", "Shut Down", { applescript = 'tell application "System Events" to shut down' }),

  item("learn.shortcuts", "Keyboard Shortcuts", { url = "https://support.apple.com/102650" }),
  item("learn.macos", "macOS User Guide", { url = "https://support.apple.com/guide/mac-help/welcome/mac" }),
  item("learn.homebrew", "Homebrew", { url = "https://docs.brew.sh/" }),
  item("learn.neovim", "Neovim", { url = "https://neovim.io/doc/" }),
  item("learn.shell", "Zsh", { url = "https://zsh.sourceforge.io/Doc/" }),
  item("learn.lua", "Lua 5.4", { url = "https://www.lua.org/manual/5.4/" }),

  item("trigger.emoji", "Emoji & Symbols", { applescript = 'tell application "System Events" to key code 49 using {control down, command down}' }),
  item("trigger.capture", "Capture", { symbol = "camera" }),
  item("trigger.capture.screenshot", "Screenshot", { open = "/System/Applications/Utilities/Screenshot.app" }),
  item("trigger.capture.screen", "Capture Entire Screen", { shell = "screencapture -i ~/Desktop/screenshot-$(date +%s).png" }),
  item("trigger.capture.color", "Color", { open = "/System/Applications/Utilities/Digital Color Meter.app" }),
  item("trigger.share", "Share", { symbol = "square.and.arrow.up" }),
  item("trigger.share.airdrop", "AirDrop", { url = "file:///System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app" }),
  item("trigger.toggle", "Toggle", { symbol = "switch.2" }),
  item("trigger.toggle.dark", "Dark Appearance", { applescript = 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode' }),
  item("trigger.toggle.dnd", "Do Not Disturb", { applescript = 'tell application "System Events" to keystroke "d" using {option down, command down, control down}' }),
  item("trigger.tests", "Speed Test", { symbol = "speedometer" }),
  item("trigger.tests.network", "Network", { shell = "networkQuality" }),
  item("trigger.tests.disk", "Disk", { shell = "time dd if=/dev/zero of=/tmp/orbit-speed-test bs=1m count=1024 conv=sync; rm -f /tmp/orbit-speed-test" }),

  item("style.wallpaper", "Wallpaper", { applescript = 'tell application "System Settings" to activate\ntell application "System Events" to tell process "System Settings" to keystroke "wallpaper"' }),
  item("style.appearance", "Appearance", { url = "x-apple.systempreferences:com.apple.Appearance-Settings.extension" }),
  item("style.fonts", "Fonts", { open = "/System/Applications/Font Book.app" }),
  item("style.desktop", "Desktop & Dock", { url = "x-apple.systempreferences:com.apple.Desktop-Settings.extension" }),
  item("style.displays", "Displays", { url = "x-apple.systempreferences:com.apple.Displays-Settings.extension" }),

  item("setup.system", "System Settings", { open = "/System/Applications/System Settings.app" }),
  item("setup.network", "Network", { url = "x-apple.systempreferences:com.apple.Network-Settings.extension" }),
  item("setup.bluetooth", "Bluetooth", { url = "x-apple.systempreferences:com.apple.BluetoothSettings" }),
  item("setup.keyboard", "Keyboard", { url = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension" }),
  item("setup.trackpad", "Trackpad", { url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension" }),
  item("setup.security", "Privacy & Security", { url = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension" }),
  item("setup.config", "Orbit Config", { shell = "${EDITOR:-nano} ~/.config/orbit/config.lua" }),
  item("setup.theme", "Orbit Theme", { shell = "${EDITOR:-nano} ~/.config/orbit/theme.lua" }),

  item("search", "Search", { symbol = "magnifyingglass", provider = "websearch", detail = "Type, then pick a destination" }),

  item("install.formula", "Homebrew Formula", { shell = "read -r '?Formula: ' name; [[ -n $name ]] && brew install --formula $name" }),
  item("install.cask", "Homebrew App", { shell = "read -r '?Cask: ' name; [[ -n $name ]] && brew install --cask $name" }),
  item("install.update", "Update Homebrew", { shell = "brew update" }),
  item("install.upgrade", "Upgrade Everything", { shell = "brew update && brew upgrade && brew cleanup" }),
  item("install.development", "Development", { symbol = "hammer" }),
  item("install.development.node", "Node.js", { shell = "brew install node" }),
  item("install.development.go", "Go", { shell = "brew install go" }),
  item("install.development.python", "Python", { shell = "brew install python" }),
  item("install.development.rust", "Rust", { shell = "brew install rustup-init && rustup-init" }),
  item("install.development.java", "Java", { shell = "brew install openjdk" }),
  item("install.editor", "Editor", { symbol = "doc.text" }),
  item("install.editor.vscode", "Visual Studio Code", { shell = "brew install --cask visual-studio-code" }),
  item("install.editor.cursor", "Cursor", { shell = "brew install --cask cursor" }),
  item("install.editor.zed", "Zed", { shell = "brew install --cask zed" }),
  item("install.browser", "Browser", { symbol = "globe" }),
  item("install.browser.chrome", "Google Chrome", { shell = "brew install --cask google-chrome" }),
  item("install.browser.firefox", "Firefox", { shell = "brew install --cask firefox" }),
  item("install.browser.brave", "Brave", { shell = "brew install --cask brave-browser" }),
  item("install.terminal", "Terminal", { symbol = "terminal" }),
  item("install.terminal.ghostty", "Ghostty", { shell = "brew install --cask ghostty" }),
  item("install.terminal.iterm", "iTerm2", { shell = "brew install --cask iterm2" }),

  item("remove.formula", "Homebrew Formula", { shell = "brew list --formula; read -r '?Remove formula: ' name; [[ -n $name ]] && brew uninstall --formula $name" }),
  item("remove.cask", "Homebrew App", { shell = "brew list --cask; read -r '?Remove cask: ' name; [[ -n $name ]] && brew uninstall --cask $name" }),
  item("remove.cleanup", "Homebrew Cleanup", { shell = "brew cleanup --prune=all" }),

  item("update.homebrew", "Homebrew Packages", { shell = "brew update && brew upgrade && brew cleanup" }),
  item("update.macos", "macOS Software Update", { shell = "softwareupdate --list; echo; read -r '?Install all updates? [y/N] ' answer; [[ $answer == [Yy]* ]] && sudo softwareupdate --install --all" }),
  item("update.orbit", "OrbitLauncher", { shell = "cd ~/personal/app_launcher && git pull && ./scripts/build-app.sh" }),
  item("update.reload", "Reload Lua Config", { shell = "~/.config/orbit/reload 2>/dev/null || true" }),
}

-- Plugins. Anything in ~/.config/orbit/plugins/ that returns { items = ..., providers = ... }.
local providers = {
  -- A provider is called with the current query and returns rows. It runs in an
  -- isolated state with no terminal/osascript/io, on a 0.15s budget, so it must be a
  -- pure function of the query — it *describes* an action and the host runs it.
  websearch = function(query)
    if query == "" then return {} end
    return {
      { label = "Google " .. query,  symbol = "globe",  value = "google",
        url = "https://www.google.com/search?q={query}" },
      { label = "GitHub " .. query,  symbol = "chevron.left.forwardslash.chevron.right", value = "github",
        url = "https://github.com/search?q={query}" },
      { label = "Man page for " .. query, symbol = "doc.text", value = "man",
        shell = "man {query}" },
    }
  end,
}

for _, name in ipairs({ "example", "smart", "text", "projects", "themes", "brew" }) do
  local ok, plugin = pcall(require, "plugins." .. name)
  if ok and type(plugin) == "table" then
    for _, entry in ipairs(plugin.items or {}) do items[#items + 1] = entry end
    for key, fn in pairs(plugin.providers or {}) do providers[key] = fn end
  end
end

return {
  hotkey = { key = "space", mods = { "option" } },

  -- Modal navigation, off by default. When on, the panel opens in NORMAL mode:
  --   j / k      move down / up          / or s   clear the query and start typing
  --   i          resume typing           a        append at the end of the query
  --   Escape     insert -> normal; in normal mode it clears, then goes back, then hides
  --   Enter      activate, in either mode
  -- Arrow keys keep working in both modes.
  vim = false,
  items = items,
  providers = providers,
}
