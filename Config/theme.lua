-- OrbitLauncher theme. Copy to ~/.config/orbit/theme.lua.
-- Reloads on save, in a restricted Lua state that can only restyle the panel.
-- Layout is native, so this token set is the whole appearance surface: if a value
-- is not here, it is not hardcoded somewhere else — file it as a missing token.

return {
  -- Colour scheme. Seeds bg/surface/fg/fg_muted/accent/border/selection_bg from an
  -- external scheme file; anything you set below still overrides it.
  --   "auto"            follow ~/.config/theme (so `set-theme` retints this too)
  --   "kanagawa"        a name, searched in this order:
  --                       ~/.config/orbit/themes/<name>.{toml,yaml,yml,conf,theme}
  --                       ~/omarchy/themes/<name>/colors.toml
  --                       ~/.config/{kitty,ghostty,btop}/themes/<name>
  --   "~/path/to/scheme.yaml"   an explicit file
  -- Formats: Base16 YAML (base00-base0F), Omarchy colors.toml, kitty .conf,
  -- ghostty, btop .theme. They are all flat key -> hex, so one reader takes them all.
  palette = "auto",

  -- Palette overrides. Uncomment to pin a role regardless of the palette; with all
  -- of them commented out the palette above is fully in charge.
  -- bg = "17191f",
  -- surface = "22252d",
  -- fg = "d8dee9",
  -- fg_muted = "7f8490",
  -- accent = "7aa2f7",
  -- border = "3b3f4a",
  -- selection_bg = "d8dee9",  -- defaults to fg
  -- selection_fg = "7aa2f7",  -- defaults to accent

  -- Alphas, composed onto the palette above
  bg_alpha = 0.82,        -- lower this to let more of the blur through
  border_alpha = 1.0,
  selection_alpha = 0.10, -- the selected row is a soft wash, not a solid slab
  detail_alpha = 0.55,
  chevron_alpha = 0.36,
  divider_alpha = 0.20,
  blur = 0.82,            -- >0.66 hudWindow, >0.33 menu, else opaque

  -- Geometry
  radius = 12,
  row_radius = 8,
  width = 380,
  max_height = 0.6,       -- fraction of the screen the panel may grow to
  border_width = 1,
  offset_y = 28,          -- above screen centre

  -- Spacing. Every value below is multiplied by spacing_scale.
  spacing_scale = 1.0,
  panel_padding = 12,     -- every edge, unless overridden per edge below
  -- padding_top = 12,
  -- padding_bottom = 12,
  -- padding_sides = 12,
  row_gap = 2,
  row_padding_x = 10,
  icon_slot = 34,
  icon_gap = 8,
  label_gap = 1,
  row_height = 44,
  row_height_detail = 56,
  divider_height = 15,
  header_gap = 8,
  selection_inset = 0,
  selection_bar = 0,      -- width of a left accent bar on the selected row

  -- Typography. One base size drives a proportional scale
  -- (caption .83, small .92, body 1.0, title 1.17, heading 1.33, icon 1.5).
  font = "",              -- empty means the system font
  font_size = 13,
  label_weight = "medium",
  detail_weight = "regular",
  detail_mode = "search", -- "search" | "always" | "never"
}
