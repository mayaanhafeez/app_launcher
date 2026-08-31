# OrbitLauncher

A resident native macOS launcher and nested command menu. AppKit owns the warm non-activating panel, rendering, app index, fuzzy matching, state, hotkey, and IPC. Lua 5.4 owns menu data, actions, providers, and flat theme tokens.

## Build and run

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
open .build/OrbitLauncher.app
swift run orbitctl toggle
```

The global hotkey is `Option-Space`. The app has no Dock or menu-bar item.

Copy `Config/config.lua` and `Config/theme.lua` to `~/.config/orbit/` to start customizing. Config changes rebuild the complete menu Lua state. Theme changes use a separate restricted state and only restyle the warm panel.

## IPC

```sh
orbitctl toggle [route]
orbitctl show [route]
orbitctl hide
orbitctl invoke <node-id>
orbitctl reload
orbitctl ping
```

The Unix socket is `~/Library/Containers/com.orbit.launcher/Data/tmp/orbit.sock` and is mode `0600`.

## Lua scripting

Lua defines arbitrary menu trees. An item without an action is a category. Dotted IDs infer their parent, or `parent` can be set explicitly:

```lua
return {
  items = {
    { id = "root", label = "Go" },
    { id = "dev", label = "Development", symbol = "hammer" },
    {
      id = "dev.server",
      label = "Run local server",
      detail = "Opens in Terminal",
      shell = "cd ~/code/my-app && npm run dev",
    },
    {
      id = "dev.finder",
      label = "Open project in Finder",
      applescript = 'tell application "Finder" to open POSIX file "/Users/me/code/my-app"',
    },
    {
      id = "dev.xcode",
      label = "Open Xcode directly",
      open = "/Applications/Xcode.app",
    },
    {
      id = "dev.docs",
      label = "Open documentation",
      url = "https://developer.apple.com/documentation/",
    },
  },
}
```

`shell` commands always open in Terminal and are the default action type. The command is Base64-transported into the terminal session, so quotes, newlines, pipes, and redirects are preserved. `applescript` is passed directly to `/usr/bin/osascript`. `open` launches an app bundle directly through `NSWorkspace`; `url` opens a URL through the user's default handler.

Advanced handlers may use the same helpers:

```lua
{
  id = "dev.dynamic",
  label = "Dynamic action",
  action = function()
    terminal("printf '%s\\n' 'hello from Lua'")
    osascript('display notification "Started" with title "OrbitLauncher"')
  end,
}
```

`run(command)` remains an alias of `terminal(command)`. Lua has no `io` module and `os.execute` is removed; all external execution goes through `terminal`, `run`, or `osascript` and is logged by the host. Provider functions run in isolated states without these execution helpers.

Supported item fields are `id`, `parent`, `label`, `detail`, `symbol`, `provider`, `shell`, `applescript`, `open`, `url`, and `action`. UI layout remains native; new visual behavior should be implemented as a native row type rather than Lua layout.
