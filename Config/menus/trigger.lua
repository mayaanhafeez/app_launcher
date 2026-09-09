-- Things that fire once: capture, share, toggle, measure.
local item, group = require("item").item, require("item").group

return {
  items = {
    group("trigger", "Trigger", "bolt"),
    item("trigger.emoji", "Emoji & Symbols", { applescript = 'tell application "System Events" to key code 49 using {control down, command down}' }),
    group("trigger.capture", "Capture", "camera"),
    item("trigger.capture.screenshot", "Screenshot", { open = "/System/Applications/Utilities/Screenshot.app" }),
    item("trigger.capture.screen", "Capture Entire Screen", { shell = "screencapture -i ~/Desktop/screenshot-$(date +%s).png" }),
    item("trigger.capture.color", "Color", { open = "/System/Applications/Utilities/Digital Color Meter.app" }),
    group("trigger.share", "Share", "square.and.arrow.up"),
    item("trigger.share.airdrop", "AirDrop", { url = "file:///System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app" }),
    group("trigger.toggle", "Toggle", "switch.2"),
    item("trigger.toggle.dark", "Dark Appearance", { applescript = 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode' }),
    item("trigger.toggle.dnd", "Do Not Disturb", { applescript = 'tell application "System Events" to keystroke "d" using {option down, command down, control down}' }),
    group("trigger.tests", "Speed Test", "speedometer"),
    item("trigger.tests.network", "Network", { shell = "networkQuality" }),
    item("trigger.tests.disk", "Disk", { shell = "time dd if=/dev/zero of=/tmp/kitsune-speed-test bs=1m count=1024 conv=sync; rm -f /tmp/kitsune-speed-test" }),
  },
}
