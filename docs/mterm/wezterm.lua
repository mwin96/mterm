local wezterm = require("wezterm")

local config = wezterm.config_builder()

local is_windows = os.getenv("OS") and os.getenv("OS"):lower():find("windows")
local is_macos = wezterm.target_triple:lower():find("darwin") ~= nil
local function directory_exists(path)
  local ok, _, code = os.rename(path, path)
  return ok or code == 13
end
local palette = {
  base = "#232136",
  surface = "#2a273f",
  overlay = "#393552",
  muted = "#6e6a86",
  subtle = "#908caa",
  inactive_text = "#c7c4d8",
  text = "#e0def4",
  love = "#eb6f92",
  gold = "#f6c177",
  foam = "#9ccfd8",
  iris = "#c4a7e7",
}
local ambient_base = "#191724"
local ambient_aurora_path = wezterm.config_dir .. "/assets/mterm-aurora.png"
local ambient_dots_path = wezterm.config_dir .. "/assets/mterm-dots.png"
local normal_update_interval = 100
local calm_update_interval = 1000
local middot = utf8.char(0x00b7)
local active_bar = utf8.char(0x258e)
local title_separator = " " .. middot .. " "
local animation_ticks = {}

local animated_background = {
  {
    source = {
      Color = ambient_base,
    },
    width = "100%",
    height = "100%",
    opacity = 0.7,
  },
  {
    source = {
      File = ambient_aurora_path,
    },
    attachment = "Fixed",
    repeat_x = "NoRepeat",
    repeat_y = "NoRepeat",
    width = "Cover",
    height = "Cover",
    vertical_align = "Middle",
    horizontal_align = "Center",
    opacity = 1.0,
    hsb = {
      brightness = 1.08,
      saturation = 1.0,
    },
  },
  {
    source = {
      File = ambient_dots_path,
    },
    attachment = "Fixed",
    repeat_x = "NoRepeat",
    repeat_y = "NoRepeat",
    width = "Cover",
    height = "Cover",
    vertical_align = "Middle",
    horizontal_align = "Center",
    opacity = 1.0,
  },
}

local calm_background = {
  {
    source = {
      Color = ambient_base,
    },
    width = "100%",
    height = "100%",
    opacity = 0.7,
  },
}

local spinner_frames = {
  utf8.char(0x280b),
  utf8.char(0x2819),
  utf8.char(0x2839),
  utf8.char(0x2838),
  utf8.char(0x283c),
  utf8.char(0x2834),
  utf8.char(0x2826),
  utf8.char(0x2827),
  utf8.char(0x2807),
  utf8.char(0x280f),
}

local active_backgrounds = {
  "#17131f",
  "#181420",
  "#1a1523",
  "#1c1726",
  "#1f192a",
  "#221b2e",
  "#251d32",
  "#282036",
  "#251d32",
  "#221b2e",
  "#1f192a",
  "#1c1726",
  "#1a1523",
  "#181420",
}

local active_accents = {
  "#b9a2d6",
  "#bca5db",
  "#c0a8e0",
  palette.iris,
  "#c0b0e1",
  "#b8b8de",
  "#afbfdc",
  "#a6c8da",
  palette.foam,
  "#a6c8da",
  "#afbfdc",
  "#b8b8de",
  "#c0b0e1",
  "#bca5db",
}

local title_prefixes = {
  utf8.char(0x23f3),
  utf8.char(0x2705),
  utf8.char(0x25cb),
  utf8.char(0x1f514),
}

local state_styles = {
  working = {
    icon = spinner_frames[1],
    color = palette.iris,
  },
  done = {
    icon = utf8.char(0x2713),
    color = palette.foam,
  },
  idle = {
    icon = utf8.char(0x25cb),
    color = palette.muted,
  },
  input = {
    icon = "!",
    color = palette.love,
  },
  shell = {
    icon = ">",
    color = palette.subtle,
  },
}

-- Telemetry-card model/effort. Reads whichever AI harness settings file is
-- present: Claude Code (~/.claude) first, then Copilot CLI (~/.copilot).
local function read_agent_settings()
  local candidates = {
    { path = "/.claude/settings.json", fallback = "CLAUDE" },
    { path = "/.copilot/settings.json", fallback = "COPILOT" },
  }
  for _, candidate in ipairs(candidates) do
    local settings = io.open(wezterm.home_dir .. candidate.path, "r")
    if settings then
      local contents = settings:read("*a")
      settings:close()
      local model = contents:match('"model"%s*:%s*"([^"]+)"')
      local effort = contents:match('"effortLevel"%s*:%s*"([^"]+)"')

      model = model
          and model
            :upper()
            :gsub("%[%d+M%]$", "")
            :gsub("^CLAUDE%-", "")
            :gsub("%-SOL$", " SOL")
            :gsub("%-TERRA$", " TERRA")
        or candidate.fallback
      effort = effort and effort:upper() or "DEFAULT"
      return model, effort
    end
  end
  return "AGENT", "DEFAULT"
end

local agent_model, agent_effort = read_agent_settings()

local function infer_state(title, user_vars)
  local state = user_vars and user_vars.COPILOT_STATE or nil
  if state_styles[state] then
    return state
  end

  if title:find(title_separator .. "working", 1, true) then
    return "working"
  end
  if title:find(title_separator .. "done", 1, true) then
    return "done"
  end
  if title:find(title_separator .. "ready", 1, true) then
    return "idle"
  end
  if title:find(title_separator .. "needs input", 1, true) then
    return "input"
  end
  return nil
end

local function clean_session_title(title)
  for _, prefix in ipairs(title_prefixes) do
    if title:sub(1, #prefix) == prefix then
      title = title:sub(#prefix + 1):gsub("^%s+", "")
      break
    end
  end

  local separator = title:find(title_separator, 1, true)
  if separator then
    title = title:sub(1, separator - 1)
  end
  return title:gsub("^%s+", ""):gsub("%s+$", "")
end

local function tab_label(tab, state)
  if tab.tab_title and #tab.tab_title > 0 then
    return tab.tab_title
  end

  local user_vars = tab.active_pane.user_vars or {}
  if user_vars.COPILOT_LABEL and #user_vars.COPILOT_LABEL > 0 then
    return user_vars.COPILOT_LABEL
  end

  local title = tab.active_pane.title or "shell"
  if state then
    title = clean_session_title(title)
  end
  return #title > 0 and title or "shell"
end

local function current_repo(pane)
  local cwd_uri = pane:get_current_working_dir()
  if not cwd_uri then
    return "repos"
  end

  local path
  if type(cwd_uri) == "userdata" then
    path = cwd_uri.file_path
  else
    path = cwd_uri:gsub("^file://[^/]*", ""):gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
  end

  local repo = path:match("/Documents/Repos/([^/]+)") or path:match("([^/]+)/?$")
  if not repo or repo == "" or repo == "Repos" then
    return "repos"
  end
  return wezterm.truncate_right(repo, 18)
end

local repos_dir = wezterm.home_dir .. "/Documents/Repos"
config.default_cwd = os.getenv("WEZTERM_DEFAULT_CWD")
  or (directory_exists(repos_dir) and repos_dir)
  or wezterm.home_dir
config.color_scheme = "rose-pine-moon"
config.max_fps = 120
config.status_update_interval = normal_update_interval
config.background = animated_background
config.audible_bell = "Disabled"
config.visual_bell = {
  fade_in_duration_ms = 0,
  fade_out_duration_ms = 0,
}
-- Stop the cursor from blinking/flashing, even when an app requests a
-- blinking style via DECSCUSR. 0 disables the blink animation entirely.
config.default_cursor_style = "SteadyBar"
config.cursor_blink_rate = 0
config.text_blink_rate = 0
config.text_blink_rate_rapid = 0
config.scroll_to_bottom_on_input = true
config.font = wezterm.font("Hack Nerd Font", { weight = "DemiBold" })
config.window_decorations = "INTEGRATED_BUTTONS|RESIZE"
config.window_frame = {
  font = wezterm.font("Hack Nerd Font", { weight = "Bold" }),
  active_titlebar_bg = "rgba(25, 23, 36, 0.56)",
  inactive_titlebar_bg = "rgba(25, 23, 36, 0.68)",
  active_titlebar_fg = palette.text,
  inactive_titlebar_fg = palette.subtle,
}

-- Vertical tab bar (gilescope fork: giles-vertical-tabs-drag-reorder).
-- Left/Right positions require the fancy tab bar. Tabs can be dragged to
-- reorder, and right-clicking the tab bar opens a position picker.
config.use_fancy_tab_bar = true
config.tab_bar_position = "Left"
config.tab_bar_width = "360px"
config.tab_max_width = 160
config.inactive_pane_hsb = {
  saturation = 0.0,
  brightness = 0.5,
}

if is_windows then
  config.win32_system_backdrop = "Acrylic"
  config.window_background_opacity = 0.7
  config.window_frame.font_size = 10.0
end

if is_macos then
  config.integrated_title_button_style = "MacOsNative"
  config.integrated_title_button_alignment = "Left"
  config.window_background_opacity = 0.7
  config.macos_window_background_blur = 50
  config.font_size = 15.0
  config.window_frame.font_size = 13.0
end

local function find_tab(window, tab_id)
  for _, tab in ipairs(window:mux_window():tabs()) do
    if tostring(tab:tab_id()) == tostring(tab_id) then
      return tab
    end
  end
  return nil
end

local function prompt_tab_rename(window, pane, tab_id)
  local tab = find_tab(window, tab_id)
  if not tab then
    return
  end

  local current_title = tab:get_title()
  window:perform_action(
    wezterm.action.PromptInputLine({
      description = "Rename tab (leave blank to restore its automatic title)",
      initial_value = #current_title > 0 and current_title or nil,
      action = wezterm.action_callback(function(prompt_window, _, line)
        if line == nil then
          return
        end
        local target = find_tab(prompt_window, tab_id)
        if target then
          target:set_title(line)
        end
      end),
    }),
    pane
  )
end

local function prompt_tab_group(window, pane, tab_id)
  local tab = find_tab(window, tab_id)
  if not tab then
    return
  end

  local current_group = tab:get_group()
  window:perform_action(
    wezterm.action.PromptInputLine({
      description = current_group and "Rename divider (leave blank to remove it)"
        or "Name the divider above this tab",
      prompt = "Group name: ",
      initial_value = current_group,
      action = wezterm.action_callback(function(prompt_window, _, line)
        if line == nil then
          return
        end
        local target = find_tab(prompt_window, tab_id)
        if target then
          target:set_group(line)
        end
      end),
    }),
    pane
  )
end

wezterm.on("right-click-tab-action", function(window, pane, id)
  if not id then
    return
  end

  local action, tab_id = id:match("^([^:]+):(%d+)$")
  if action == "rename-tab" then
    prompt_tab_rename(window, pane, tab_id)
  elseif action == "add-group" or action == "rename-group" then
    prompt_tab_group(window, pane, tab_id)
  elseif action == "remove-group" then
    local tab = find_tab(window, tab_id)
    if tab then
      tab:set_group(nil)
    end
  end
end)

wezterm.on("format-tab-title", function(tab, _, _, effective_config, hover, max_width)
  local title = tab.active_pane.title or ""
  local state = infer_state(title, tab.active_pane.user_vars)
  local style = state_styles[state] or state_styles.shell
  local tick = animation_ticks[tab.window_id] or 0
  local calm = (effective_config.status_update_interval or normal_update_interval) >= calm_update_interval
  local icon = style.icon
  local icon_color = style.color

  if state == "working" and not calm then
    icon = spinner_frames[(tick % #spinner_frames) + 1]
    icon_color = active_accents[(tick % #active_accents) + 1]
  end

  local background = palette.base
  local accent = palette.muted
  if hover then
    background = palette.overlay
  elseif tab.is_active then
    if calm then
      background = palette.surface
      accent = palette.iris
    else
      local frame = (tick % #active_backgrounds) + 1
      background = active_backgrounds[frame]
      accent = active_accents[frame]
    end
  elseif state == "input" then
    background = "#2b2336"
  end

  local accent_text = tab.is_active and active_bar .. " " or "  "
  local reserved_width = wezterm.column_width(accent_text .. icon .. " ")
  local label_width = math.max(20, (max_width or effective_config.tab_max_width or 160) - reserved_width)
  local label = wezterm.truncate_right(tab_label(tab, state), label_width)

  return {
    { Background = { Color = background } },
    { Foreground = { Color = accent } },
    { Text = accent_text },
    { Foreground = { Color = icon_color } },
    { Text = icon .. " " },
    { Foreground = { Color = tab.is_active and palette.text or palette.inactive_text } },
    { Text = label },
    { Text = " " },
  }
end)

wezterm.on("update-status", function(window, pane)
  local mux_window = window:mux_window()
  local window_id = mux_window:window_id()
  animation_ticks[window_id] = ((animation_ticks[window_id] or 0) + 1) % 1000

  local working = 0
  local attention = 0
  local total = 0
  for _, tab in ipairs(mux_window:tabs()) do
    local tab_pane = tab:active_pane()
    local state = infer_state(tab_pane:get_title() or "", tab_pane:get_user_vars())
    if state then
      total = total + 1
      if state == "working" then
        working = working + 1
      elseif state == "input" then
        attention = attention + 1
      end
    end
  end

  local calm = (window:effective_config().status_update_interval or normal_update_interval) >= calm_update_interval
  local tick = animation_ticks[window_id]
  local mode = calm and "CALM" or spinner_frames[(tick % #spinner_frames) + 1] .. " AUTO"
  local mode_color = calm and palette.subtle or active_accents[(tick % #active_accents) + 1]
  local session_text = string.format("%d/%d", working, total)
  if attention > 0 then
    session_text = session_text .. " !" .. attention
  end

  local separator = " " .. middot .. " "
  local clock = wezterm.strftime("%I:%M %p"):gsub("^0", "")
  window:set_right_status(wezterm.format({
    { Foreground = { Color = mode_color } },
    { Text = " " .. mode },
    { Foreground = { Color = palette.muted } },
    { Text = separator },
    { Foreground = { Color = palette.iris } },
    { Text = agent_model },
    { Foreground = { Color = palette.muted } },
    { Text = separator },
    { Foreground = { Color = palette.foam } },
    { Text = agent_effort },
    { Foreground = { Color = palette.muted } },
    { Text = separator },
    { Foreground = { Color = palette.text } },
    { Text = current_repo(pane) },
    { Foreground = { Color = palette.muted } },
    { Text = separator },
    { Foreground = { Color = attention > 0 and palette.love or palette.gold } },
    { Text = session_text },
    { Foreground = { Color = palette.muted } },
    { Text = separator },
    { Foreground = { Color = palette.subtle } },
    { Text = clock .. " " },
  }))
end)

wezterm.on("toggle-calm-mode", function(window)
  local overrides = window:get_config_overrides() or {}
  local was_calm = overrides.status_update_interval == calm_update_interval
  if was_calm then
    overrides.background = nil
    overrides.status_update_interval = nil
  else
    overrides.background = calm_background
    overrides.status_update_interval = calm_update_interval
  end
  window:set_config_overrides(overrides)
  window:toast_notification(
    "MTerm",
    was_calm and "Ambient motion restored" or "Calm mode enabled",
    nil,
    1500
  )
end)

config.keys = {
  {
    key = "LeftArrow",
    mods = "CMD|SHIFT",
    action = wezterm.action.MoveTabRelative(-1),
  },
  {
    key = "RightArrow",
    mods = "CMD|SHIFT",
    action = wezterm.action.MoveTabRelative(1),
  },
  {
    key = "R",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      prompt_tab_rename(window, pane, window:active_tab():tab_id())
    end),
  },
  {
    key = "G",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      prompt_tab_group(window, pane, window:active_tab():tab_id())
    end),
  },
  {
    key = "C",
    mods = "CMD|SHIFT",
    action = wezterm.action.EmitEvent("toggle-calm-mode"),
  },
}

-- Keep the Mac awake while WezTerm is open. caffeinate is bound to the WezTerm
-- GUI process via `-w $PPID`, so the assertion is released automatically when
-- WezTerm quits (nothing left running to keep the Mac awake afterwards).
wezterm.on("gui-startup", function(cmd)
  local mux = wezterm.mux
  mux.spawn_window(cmd or {})
  if is_macos then
    wezterm.background_child_process({
      "/bin/sh",
      "-c",
      "exec caffeinate -dim -w $PPID",
    })
  end
end)

return config
