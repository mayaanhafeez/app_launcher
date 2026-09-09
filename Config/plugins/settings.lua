-- macOS System Settings, as a browsable tree.
--
-- Every row is a `url` opening `x-apple.systempreferences:<bundle-id>`, optionally with
-- `?<Anchor>` to land on one section of a pane. Two facts about that scheme decide the
-- shape of this file:
--
-- 1. **Panes are enumerable; sections are not.** The top-level panes are real bundles
--    under /System/Library/ExtensionKit/Extensions (plus GeneralSettings.appex inside
--    System Settings.app itself), so their identifiers can be read off disk. The anchors
--    that address a *section* of a pane exist only as string literals inside each pane's
--    own binary — nothing lists them. That is why this is a hand-maintained list rather
--    than a native index: the nesting is exactly the part macOS will not tell you.
--
-- 2. **An unknown identifier fails silently.** System Settings opens on whatever it was
--    last showing rather than reporting the bad URL, so a typo here reads as the row
--    "doing nothing". Every identifier below was read out of the bundle it names on
--    macOS 26, and the Privacy and Accessibility anchors were extracted from those two
--    extensions' binaries. Verify a new one the same way before adding it:
--
--      plutil -extract CFBundleIdentifier raw \
--        /System/Library/ExtensionKit/Extensions/NAME.appex/Contents/Info.plist
--      strings -a /System/Library/ExtensionKit/Extensions/NAME.appex/Contents/MacOS/* \
--        | grep -E '^[A-Z][A-Za-z]+_[A-Za-z]+$'
--
-- Panes come and go between macOS releases, and a row pointing at one this Mac does not
-- have is harmless — it opens System Settings and stops — so the list is not gated on
-- what is installed.

local function item(id, label, fields)
  fields = fields or {}
  fields.id = id
  fields.label = label
  return fields
end

-- A pane row. `target` is the bundle identifier, with `?Anchor` appended when the row
-- addresses a section rather than the pane itself.
local function pane(id, label, target, detail)
  return item(id, label, { url = "x-apple.systempreferences:" .. target, detail = detail or "" })
end

-- A grouping row: no action of any kind, which is what makes it a submenu.
local function group(id, label, symbol, aliases)
  return item(id, label, { symbol = symbol, aliases = aliases })
end

local items = {
  group("settings", "System Settings", "gearshape",
        { "prefs", "preferences", "sysprefs", "panes", "system-settings" }),
  item("settings.open", "Open System Settings", { symbol = "gear",
       detail = "The app itself", open = "/System/Applications/System Settings.app" }),

  -- Network & sharing -------------------------------------------------------
  group("settings.network", "Network", "wifi"),
  pane("settings.network.wifi", "Wi-Fi", "com.apple.wifi-settings-extension"),
  pane("settings.network.bluetooth", "Bluetooth", "com.apple.BluetoothSettings"),
  pane("settings.network.network", "Network", "com.apple.Network-Settings.extension",
       "Interfaces, VPN, firewall"),
  pane("settings.network.sharing", "Sharing", "com.apple.Sharing-Settings.extension",
       "Screen sharing, remote login, media"),
  pane("settings.network.airdrop", "AirDrop & Handoff", "com.apple.AirDrop-Handoff-Settings.extension"),

  -- Privacy & Security ------------------------------------------------------
  -- Anchors extracted from SecurityPrivacyExtension.appex. This is the pane where
  -- section-level links earn their keep: everything below is four clicks deep in the
  -- real UI, and "which apps have screen recording" is a thing you look up, not browse.
  group("settings.privacy", "Privacy & Security", "hand.raised",
        { "privacy", "security", "permissions", "tcc" }),
  pane("settings.privacy.overview", "Privacy & Security", "com.apple.settings.PrivacySecurity.extension",
       "The whole pane"),
  pane("settings.privacy.accessibility", "Accessibility Access",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
       "Apps allowed to control your Mac"),
  pane("settings.privacy.automation", "Automation",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
       "Apps allowed to control other apps"),
  pane("settings.privacy.screen-recording", "Screen & System Audio Recording",
       "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"),
  pane("settings.privacy.input-monitoring", "Input Monitoring",
       "com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture"),
  pane("settings.privacy.full-disk", "Files & Folders",
       "com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders"),
  pane("settings.privacy.desktop-folder", "Desktop Folder",
       "com.apple.settings.PrivacySecurity.extension?Privacy_DesktopFolder"),
  pane("settings.privacy.documents-folder", "Documents Folder",
       "com.apple.settings.PrivacySecurity.extension?Privacy_DocumentsFolder"),
  pane("settings.privacy.downloads-folder", "Downloads Folder",
       "com.apple.settings.PrivacySecurity.extension?Privacy_DownloadsFolder"),
  pane("settings.privacy.network-volumes", "Network Volumes",
       "com.apple.settings.PrivacySecurity.extension?Privacy_NetworkVolume"),
  pane("settings.privacy.removable-volumes", "Removable Volumes",
       "com.apple.settings.PrivacySecurity.extension?Privacy_RemovableVolume"),
  pane("settings.privacy.camera", "Camera",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Camera"),
  pane("settings.privacy.microphone", "Microphone",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"),
  pane("settings.privacy.photos", "Photos",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Photos"),
  pane("settings.privacy.calendars", "Calendars",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Calendars"),
  pane("settings.privacy.pasteboard", "Pasteboard",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard"),
  pane("settings.privacy.location", "Location Services",
       "com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"),
  pane("settings.privacy.system-services", "System Services",
       "com.apple.settings.PrivacySecurity.extension?Privacy_SystemServices",
       "Location for system services"),
  pane("settings.privacy.dev-tools", "Developer Tools",
       "com.apple.settings.PrivacySecurity.extension?Privacy_DevTools"),
  pane("settings.privacy.analytics", "Analytics & Improvements",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Analytics"),
  pane("settings.privacy.advertising", "Apple Advertising",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Advertising"),
  pane("settings.privacy.sensitive-content", "Sensitive Content Warning",
       "com.apple.settings.PrivacySecurity.extension?Privacy_NudityDetection"),
  pane("settings.privacy.blocklist", "Blocklist",
       "com.apple.settings.PrivacySecurity.extension?Privacy_Blocklist"),
  pane("settings.privacy.intelligence-report", "Apple Intelligence Report",
       "com.apple.settings.PrivacySecurity.extension?Privacy_AppleIntelligenceReport"),
  pane("settings.privacy.icloud-search-report", "iCloud Search Report",
       "com.apple.settings.PrivacySecurity.extension?Privacy_iCloudSearchReport"),

  -- Accessibility -----------------------------------------------------------
  -- Anchors extracted from AccessibilitySettingsExtension.appex.
  group("settings.accessibility", "Accessibility", "accessibility", { "a11y" }),
  pane("settings.accessibility.overview", "Accessibility",
       "com.apple.Accessibility-Settings.extension", "The whole pane"),
  pane("settings.accessibility.display", "Display",
       "com.apple.Accessibility-Settings.extension?Seeing_Display",
       "Reduce motion, transparency, contrast"),
  pane("settings.accessibility.zoom", "Zoom",
       "com.apple.Accessibility-Settings.extension?Seeing_Zoom"),
  pane("settings.accessibility.voiceover", "VoiceOver",
       "com.apple.Accessibility-Settings.extension?Seeing_VoiceOver"),
  pane("settings.accessibility.color-filters", "Color Filters",
       "com.apple.Accessibility-Settings.extension?Seeing_ColorFilters"),
  pane("settings.accessibility.pointer", "Pointer",
       "com.apple.Accessibility-Settings.extension?Seeing_Cursor",
       "Pointer size and colour"),
  pane("settings.accessibility.descriptions", "Audio Descriptions",
       "com.apple.Accessibility-Settings.extension?Media_Descriptions"),

  -- Desktop & display -------------------------------------------------------
  group("settings.display", "Desktop & Display", "menubar.dock.rectangle",
        { "dock", "display", "screen" }),
  pane("settings.display.appearance", "Appearance", "com.apple.Appearance-Settings.extension",
       "Light, dark, accent colour"),
  pane("settings.display.displays", "Displays", "com.apple.Displays-Settings.extension",
       "Resolution, arrangement, Night Shift"),
  pane("settings.display.desktop", "Desktop & Dock", "com.apple.Desktop-Settings.extension",
       "Dock, Mission Control, Hot Corners"),
  pane("settings.display.wallpaper", "Wallpaper", "com.apple.Wallpaper-Settings.extension"),
  pane("settings.display.lock-screen", "Lock Screen", "com.apple.Lock-Screen-Settings.extension",
       "Screen saver, sleep, require password"),
  pane("settings.display.control-center", "Control Center", "com.apple.ControlCenter-Settings.extension",
       "Menu bar and Control Center modules"),
  pane("settings.display.notifications", "Notifications", "com.apple.Notifications-Settings.extension"),
  pane("settings.display.focus", "Focus", "com.apple.Focus-Settings.extension",
       "Do Not Disturb and friends"),

  -- Input -------------------------------------------------------------------
  group("settings.input", "Keyboard & Input", "keyboard", { "input" }),
  pane("settings.input.keyboard", "Keyboard", "com.apple.Keyboard-Settings.extension",
       "Shortcuts, text replacement, input sources"),
  pane("settings.input.trackpad", "Trackpad", "com.apple.Trackpad-Settings.extension"),
  pane("settings.input.mouse", "Mouse", "com.apple.Mouse-Settings.extension"),
  pane("settings.input.game-controllers", "Game Controllers", "com.apple.Game-Controller-Settings.extension"),
  pane("settings.input.print-scan", "Printers & Scanners", "com.apple.Print-Scan-Settings.extension"),
  pane("settings.input.sound", "Sound", "com.apple.Sound-Settings.extension",
       "Output, input, alert sounds"),

  -- Accounts ----------------------------------------------------------------
  group("settings.accounts", "Users & Accounts", "person.crop.circle", { "accounts", "users" }),
  pane("settings.accounts.apple-account", "Apple Account", "com.apple.systempreferences.AppleIDSettings",
       "iCloud, subscriptions, devices"),
  pane("settings.accounts.users-groups", "Users & Groups", "com.apple.Users-Groups-Settings.extension"),
  pane("settings.accounts.touch-id", "Touch ID & Password", "com.apple.Touch-ID-Settings.extension"),
  pane("settings.accounts.internet-accounts", "Internet Accounts", "com.apple.Internet-Accounts-Settings.extension",
       "Mail, Calendar and Contacts providers"),
  pane("settings.accounts.wallet", "Wallet & Apple Pay", "com.apple.WalletSettingsExtension"),
  pane("settings.accounts.family", "Family", "com.apple.Family-Settings.extension"),
  pane("settings.accounts.screen-time", "Screen Time", "com.apple.Screen-Time-Settings.extension"),
  pane("settings.accounts.game-center", "Game Center", "com.apple.Game-Center-Settings.extension"),

  -- General -----------------------------------------------------------------
  group("settings.general", "General", "gear"),
  pane("settings.general.about", "About", "com.apple.systempreferences.GeneralSettings",
       "Name, chip, memory, serial number"),
  pane("settings.general.software-update", "Software Update", "com.apple.Software-Update-Settings.extension"),
  pane("settings.general.storage", "Storage", "com.apple.settings.Storage"),
  pane("settings.general.login-items", "Login Items & Extensions", "com.apple.LoginItems-Settings.extension",
       "What opens at login, and app extensions"),
  pane("settings.general.language", "Language & Region", "com.apple.Localization-Settings.extension"),
  pane("settings.general.date-time", "Date & Time", "com.apple.Date-Time-Settings.extension"),
  pane("settings.general.time-machine", "Time Machine", "com.apple.Time-Machine-Settings.extension"),
  pane("settings.general.startup-disk", "Startup Disk", "com.apple.Startup-Disk-Settings.extension"),
  pane("settings.general.transfer-reset", "Transfer or Reset", "com.apple.Transfer-Reset-Settings.extension",
       "Erase All Content and Settings"),
  pane("settings.general.system-extensions", "System Extensions", "com.apple.SystemExtensions-Settings.extension"),
  pane("settings.general.device-management", "Device Management", "com.apple.Profiles-Settings.extension",
       "Configuration profiles"),
  pane("settings.general.background-security", "Background Security Improvements",
       "com.apple.SecurityImprovements-Settings.extension"),
  pane("settings.general.coverage", "AppleCare & Warranty", "com.apple.Coverage-Settings.extension"),
  pane("settings.general.cd-dvd", "CDs & DVDs", "com.apple.CD-DVD-Settings.extension"),

  -- Everything else ---------------------------------------------------------
  group("settings.system", "System", "cpu"),
  pane("settings.system.battery", "Battery", "com.apple.Battery-Settings.extension",
       "Power mode, low power, energy history"),
  pane("settings.system.siri", "Apple Intelligence & Siri", "com.apple.Siri-Settings.extension"),
  pane("settings.system.spotlight", "Spotlight", "com.apple.Spotlight-Settings.extension",
       "Search results and privacy"),
  pane("settings.system.classroom", "Classroom", "com.apple.Classroom-Settings.extension"),
  pane("settings.system.class-progress", "Class Progress", "com.apple.ClassKit-Settings.extension"),
}

return { items = items }
