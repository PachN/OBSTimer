--[[
  OBSTimer – Countdown-Script für OBS Studio

  Installation: OBS > Werkzeuge > Skripte > "+" > obstimer.lua auswählen.
  Die Datei obstimer.html muss im selben Ordner liegen wie dieses Script.

  Das Script steuert eine Browserquelle, die obstimer.html anzeigt. Alle
  Einstellungen (Zeit, Farben, Schrift, Hintergrund, Animation) werden im
  Skript-Fenster von OBS gemacht und als URL-Parameter an die Seite übergeben.
]]

obs = obslua

local SCRIPT_VERSION = "1.0.0"
local DEFAULT_SOURCE = "OBSTimer"

-- Laufzeit-Zustand
local state = "stop"      -- "stop" | "run" | "pause"
local end_ts = 0          -- Endzeitpunkt (Unix-Sekunden) wenn state == "run"
local paused_rem = 0      -- Restzeit in Sekunden wenn state == "pause"
local finished_handled = false
local last_url = nil
local last_scene = nil    -- zuletzt gesehene Programm-Szene (für Autostart)

local settings_ref = nil  -- aktuelle Script-Einstellungen
local cfg = {}

local hk = {}             -- Hotkey-IDs

-- Diagnose: schreibt Schritte ins OBS-Log ("[Lua: obstimer.lua] ...")
local DEBUG = false  -- auf true setzen, um die Schritte im OBS-Log zu sehen
local function dbg(msg)
  if DEBUG then obs.script_log(obs.LOG_INFO, "[OBSTimer] " .. msg) end
end

---------------------------------------------------------------------------
-- Hilfsfunktionen
---------------------------------------------------------------------------

local function now() return os.time() end

local function url_encode(s)
  s = tostring(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function path_encode(s)
  return (s:gsub("[^%w%-%._~/:]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- OBS-Farbwerte sind 0xAABBGGRR, die Seite erwartet RRGGBBAA
local function obs_color_to_hex(c)
  c = math.floor(tonumber(c) or 0)
  if c < 0 then c = c + 4294967296 end
  local r = c % 256
  local g = math.floor(c / 256) % 256
  local b = math.floor(c / 65536) % 256
  local a = math.floor(c / 16777216) % 256
  return string.format("%02x%02x%02x%02x", r, g, b, a)
end

local function html_url()
  local dir = script_path():gsub("\\", "/")
  if dir:sub(-1) ~= "/" then dir = dir .. "/" end
  if dir:sub(1, 1) ~= "/" then dir = "/" .. dir end -- Windows: /C:/...
  return "file://" .. path_encode(dir .. "obstimer.html")
end

-- Dauer aus den Einstellungen in Sekunden
local function configured_duration()
  if cfg.mode == "target" then
    local h, m = tostring(cfg.target or ""):match("^%s*(%d%d?):(%d%d)%s*$")
    h, m = tonumber(h), tonumber(m)
    if not h or not m or h > 23 or m > 59 then return 0 end
    local t = os.date("*t")
    t.hour, t.min, t.sec = h, m, 0
    local target = os.time(t)
    if target <= now() then
      t.day = t.day + 1
      target = os.time(t)
    end
    return target - now()
  end
  return (cfg.dur_h or 0) * 3600 + (cfg.dur_m or 0) * 60 + (cfg.dur_s or 0)
end

local function remaining()
  if state == "run" then return math.max(0, end_ts - now()) end
  if state == "pause" then return math.max(0, paused_rem) end
  return configured_duration()
end

---------------------------------------------------------------------------
-- Browserquelle aktualisieren
---------------------------------------------------------------------------

local function build_url()
  local p = {}
  local function add(k, v) p[#p + 1] = k .. "=" .. url_encode(v) end
  local function flag(v) return v and "1" or "0" end

  add("state", state)
  if state == "run" then
    add("end", string.format("%.0f", end_ts * 1000))
  else
    add("rem", string.format("%.0f", remaining() * 1000))
  end
  add("days", flag(cfg.show_days))
  add("hours", flag(cfg.show_hours))
  add("labels", flag(cfg.show_labels))
  add("shadow", flag(cfg.shadow))
  add("endtext", cfg.endtext or "")
  add("color", cfg.color)
  add("font", cfg.font_face or "Arial")
  add("size", cfg.font_size or 64)
  add("bold", flag(cfg.bold))
  add("italic", flag(cfg.italic))
  add("bg", cfg.bg_mode or "none")
  add("bgcolor", cfg.bgcolor)
  add("radius", cfg.radius or 12)
  add("pos", cfg.pos or "mc")
  add("margin", cfg.margin or 40)
  add("anim", cfg.anim or "gradient")
  add("c1", cfg.c1)
  add("c2", cfg.c2)
  add("c3", cfg.c3)
  add("base", cfg.base)
  add("speed", string.format("%.2f", cfg.speed or 1))
  return html_url() .. "?" .. table.concat(p, "&")
end

local function push_to_source(force)
  if not cfg.source or cfg.source == "" then return end
  local url = build_url()
  if not force and url == last_url then return end
  local source = obs.obs_get_source_by_name(cfg.source)
  if source == nil then return end
  local s = obs.obs_data_create()
  obs.obs_data_set_bool(s, "is_local_file", false)
  obs.obs_data_set_string(s, "url", url)
  obs.obs_data_set_int(s, "width", cfg.width or 1920)
  obs.obs_data_set_int(s, "height", cfg.height or 1080)
  obs.obs_source_update(source, s)
  obs.obs_data_release(s)
  obs.obs_source_release(source)
  last_url = url
end

---------------------------------------------------------------------------
-- Steuerung
---------------------------------------------------------------------------

local function start()
  if state == "pause" then
    end_ts = now() + paused_rem
  else
    end_ts = now() + configured_duration()
  end
  state = "run"
  finished_handled = false
  push_to_source()
end

local function pause()
  if state ~= "run" then return end
  paused_rem = math.max(0, end_ts - now())
  state = "pause"
  push_to_source()
end

local function start_pause()
  if state == "run" then pause() else start() end
end

local function reset()
  state = "stop"
  finished_handled = false
  push_to_source()
end

local function add_seconds(delta)
  if state == "run" then
    end_ts = math.max(now(), end_ts + delta)
    if end_ts > now() then finished_handled = false end
  elseif state == "pause" then
    paused_rem = math.max(0, paused_rem + delta)
  else
    -- Im Stopp-Zustand wird die eingestellte Dauer verändert
    if cfg.mode ~= "target" and settings_ref ~= nil then
      local total = math.max(0, configured_duration() + delta)
      cfg.dur_h = math.floor(total / 3600)
      cfg.dur_m = math.floor(total % 3600 / 60)
      cfg.dur_s = total % 60
      obs.obs_data_set_int(settings_ref, "dur_h", cfg.dur_h)
      obs.obs_data_set_int(settings_ref, "dur_m", cfg.dur_m)
      obs.obs_data_set_int(settings_ref, "dur_s", cfg.dur_s)
    end
  end
  push_to_source()
end

local function on_finished()
  if cfg.end_scene and cfg.end_scene ~= "" then
    local scene = obs.obs_get_source_by_name(cfg.end_scene)
    if scene ~= nil then
      obs.obs_frontend_set_current_scene(scene)
      obs.obs_source_release(scene)
    end
  end
end

local function current_scene_name()
  local scene = obs.obs_frontend_get_current_scene()
  if scene == nil then return nil end
  local name = obs.obs_source_get_name(scene)
  obs.obs_source_release(scene)
  return name
end

-- Läuft alle 250 ms. Wichtig: Das Script registriert bewusst KEINEN
-- Frontend-Event-Callback. OBS hält während dieses Timers die Sperre des
-- Scripts; ein Szenenwechsel von hier aus löst im UI-Thread ein
-- SCENE_CHANGED-Event aus, und ein Lua-Event-Callback würde dann auf genau
-- diese Sperre warten (Deadlock/Absturz). Szenenwechsel werden deshalb hier
-- per Abfrage erkannt.
local first_tick = true
local function tick()
  if first_tick then first_tick = false; dbg("erster Timer-Durchlauf") end
  -- Quelle nach dem Start von OBS einmal befüllen, sobald sie existiert
  if last_url == nil then push_to_source(true) end

  local name = current_scene_name()
  if name ~= last_scene then
    local first = last_scene == nil
    last_scene = name
    if not first and cfg.auto_scene and cfg.auto_scene ~= "" and name == cfg.auto_scene and state ~= "run" then
      if cfg.auto_reset then state = "stop" end
      start()
    end
  end

  if state == "run" and not finished_handled and now() >= end_ts then
    finished_handled = true
    on_finished()
    last_scene = current_scene_name()
  end
end

---------------------------------------------------------------------------
-- Einstellungs-Oberfläche
---------------------------------------------------------------------------

local function read_settings(s)
  cfg.source      = obs.obs_data_get_string(s, "source")
  cfg.width       = obs.obs_data_get_int(s, "width")
  cfg.pos         = obs.obs_data_get_string(s, "pos")
  cfg.margin      = obs.obs_data_get_int(s, "margin")
  cfg.height      = obs.obs_data_get_int(s, "height")
  cfg.mode        = obs.obs_data_get_string(s, "mode")
  cfg.dur_h       = obs.obs_data_get_int(s, "dur_h")
  cfg.dur_m       = obs.obs_data_get_int(s, "dur_m")
  cfg.dur_s       = obs.obs_data_get_int(s, "dur_s")
  cfg.target      = obs.obs_data_get_string(s, "target")
  cfg.show_days   = obs.obs_data_get_bool(s, "show_days")
  cfg.show_hours  = obs.obs_data_get_bool(s, "show_hours")
  cfg.show_labels = obs.obs_data_get_bool(s, "show_labels")
  cfg.shadow      = obs.obs_data_get_bool(s, "shadow")
  cfg.endtext     = obs.obs_data_get_string(s, "endtext")
  cfg.color       = obs_color_to_hex(obs.obs_data_get_int(s, "color"))

  -- Nur eine selbst gewählte Schrift auslesen; der Standard steht unten
  cfg.font_face, cfg.font_size, cfg.bold, cfg.italic = "Arial", 96, true, false
  local font = nil
  if obs.obs_data_has_user_value(s, "font") then font = obs.obs_data_get_obj(s, "font") end
  if font ~= nil then
    cfg.font_face = obs.obs_data_get_string(font, "face")
    cfg.font_size = obs.obs_data_get_int(font, "size")
    local flags = obs.obs_data_get_int(font, "flags")
    cfg.bold = flags % 2 == 1
    cfg.italic = math.floor(flags / 2) % 2 == 1
    obs.obs_data_release(font)
  end
  if not cfg.font_face or cfg.font_face == "" then cfg.font_face = "Arial" end
  if not cfg.font_size or cfg.font_size <= 0 then cfg.font_size = 96 end

  cfg.bg_mode     = obs.obs_data_get_string(s, "bg_mode")
  cfg.bgcolor     = obs_color_to_hex(obs.obs_data_get_int(s, "bgcolor"))
  cfg.radius      = obs.obs_data_get_int(s, "radius")
  cfg.anim        = obs.obs_data_get_string(s, "anim")
  cfg.c1          = obs_color_to_hex(obs.obs_data_get_int(s, "c1"))
  cfg.c2          = obs_color_to_hex(obs.obs_data_get_int(s, "c2"))
  cfg.c3          = obs_color_to_hex(obs.obs_data_get_int(s, "c3"))
  cfg.base        = obs_color_to_hex(obs.obs_data_get_int(s, "base"))
  cfg.speed       = obs.obs_data_get_double(s, "speed")

  cfg.auto_scene  = obs.obs_data_get_string(s, "auto_scene")
  cfg.auto_reset  = obs.obs_data_get_bool(s, "auto_reset")
  cfg.end_scene   = obs.obs_data_get_string(s, "end_scene")
end

local function fill_scene_list(list)
  obs.obs_property_list_add_string(list, "(keine)", "")
  local scenes = obs.obs_frontend_get_scenes()
  if scenes ~= nil then
    for _, scene in ipairs(scenes) do
      local name = obs.obs_source_get_name(scene)
      obs.obs_property_list_add_string(list, name, name)
    end
    obs.source_list_release(scenes)
  end
end

local function fill_source_list(list)
  obs.obs_property_list_clear(list)
  obs.obs_property_list_add_string(list, "(bitte wählen)", "")
  local sources = obs.obs_enum_sources()
  if sources ~= nil then
    for _, src in ipairs(sources) do
      if obs.obs_source_get_unversioned_id(src) == "browser_source" then
        local name = obs.obs_source_get_name(src)
        obs.obs_property_list_add_string(list, name, name)
      end
    end
  end
  obs.source_list_release(sources)
end

local function on_bg_mode_changed(props, prop, s)
  local mode = obs.obs_data_get_string(s, "bg_mode")
  local solid, anim = mode == "solid", mode == "anim"
  obs.obs_property_set_visible(obs.obs_properties_get(props, "bgcolor"), solid)
  obs.obs_property_set_visible(obs.obs_properties_get(props, "radius"), mode ~= "none")
  for _, k in ipairs({ "anim", "c1", "c2", "c3", "base", "speed" }) do
    obs.obs_property_set_visible(obs.obs_properties_get(props, k), anim)
  end
  return true
end

local function on_mode_changed(props, prop, s)
  local target = obs.obs_data_get_string(s, "mode") == "target"
  obs.obs_property_set_visible(obs.obs_properties_get(props, "target"), target)
  for _, k in ipairs({ "dur_h", "dur_m", "dur_s" }) do
    obs.obs_property_set_visible(obs.obs_properties_get(props, k), not target)
  end
  return true
end

local function btn_create_source(props, prop)
  local name = DEFAULT_SOURCE
  local existing = obs.obs_get_source_by_name(name)
  if existing == nil then
    local s = obs.obs_data_create()
    obs.obs_data_set_int(s, "width", cfg.width or 1920)
    obs.obs_data_set_int(s, "height", cfg.height or 1080)
    obs.obs_data_set_bool(s, "is_local_file", false)
    obs.obs_data_set_string(s, "url", "about:blank")
    local src = obs.obs_source_create("browser_source", name, s, nil)
    obs.obs_data_release(s)
    local scene_src = obs.obs_frontend_get_current_scene()
    if scene_src ~= nil then
      local scene = obs.obs_scene_from_source(scene_src)
      obs.obs_scene_add(scene, src)
      obs.obs_source_release(scene_src)
    end
    obs.obs_source_release(src)
  else
    obs.obs_source_release(existing)
  end
  if settings_ref ~= nil then
    obs.obs_data_set_string(settings_ref, "source", name)
    cfg.source = name
  end
  fill_source_list(obs.obs_properties_get(props, "source"))
  push_to_source(true)
  return true
end

local function btn_refresh(props, prop)
  fill_source_list(obs.obs_properties_get(props, "source"))
  return true
end

function script_description()
  return [[<h2>OBSTimer</h2>
<p>Countdown für OBS mit soliden oder animierten Hintergründen.</p>
<p>1. Browserquelle erstellen lassen (Button unten) oder eine vorhandene auswählen.<br>
2. Zeit und Aussehen einstellen.<br>
3. Mit <b>Start / Pause</b> oder per Hotkey steuern
(Einstellungen &gt; Hotkeys &gt; „OBSTimer“).</p>
<p><small>Version ]] .. SCRIPT_VERSION .. [[</small></p>]]
end

function script_properties()
  local props = obs.obs_properties_create()

  -- Steuerung
  obs.obs_properties_add_button(props, "btn_startpause", "▶ Start / ⏸ Pause", function() start_pause() return false end)
  obs.obs_properties_add_button(props, "btn_reset", "⟲ Zurücksetzen", function() reset() return false end)
  obs.obs_properties_add_button(props, "btn_plus", "+1 Minute", function() add_seconds(60) return true end)
  obs.obs_properties_add_button(props, "btn_minus", "−1 Minute", function() add_seconds(-60) return true end)

  -- Quelle
  local src = obs.obs_properties_add_list(props, "source", "Browserquelle",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  fill_source_list(src)
  obs.obs_properties_add_button(props, "btn_create", "Browserquelle „" .. DEFAULT_SOURCE .. "“ in aktueller Szene erstellen", btn_create_source)
  obs.obs_properties_add_button(props, "btn_refresh", "Quellenliste aktualisieren", btn_refresh)
  obs.obs_properties_add_int(props, "width", "Breite (px)", 100, 3840, 10)
  obs.obs_properties_add_int(props, "height", "Höhe (px)", 50, 2160, 10)

  local pos = obs.obs_properties_add_list(props, "pos", "Position des Countdowns",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  for _, e in ipairs({
    { "Oben links", "tl" }, { "Oben Mitte", "tc" }, { "Oben rechts", "tr" },
    { "Mitte links", "ml" }, { "Mitte", "mc" }, { "Mitte rechts", "mr" },
    { "Unten links", "bl" }, { "Unten Mitte", "bc" }, { "Unten rechts", "br" },
  }) do obs.obs_property_list_add_string(pos, e[1], e[2]) end
  obs.obs_properties_add_int(props, "margin", "Abstand zum Rand (px)", 0, 1000, 5)

  -- Zeit
  local mode = obs.obs_properties_add_list(props, "mode", "Modus",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(mode, "Dauer", "duration")
  obs.obs_property_list_add_string(mode, "Zielzeit (Uhrzeit)", "target")
  obs.obs_property_set_modified_callback(mode, on_mode_changed)
  obs.obs_properties_add_int(props, "dur_h", "Stunden", 0, 999, 1)
  obs.obs_properties_add_int(props, "dur_m", "Minuten", 0, 59, 1)
  obs.obs_properties_add_int(props, "dur_s", "Sekunden", 0, 59, 1)
  obs.obs_properties_add_text(props, "target", "Zielzeit (HH:MM)", obs.OBS_TEXT_DEFAULT)

  -- Anzeige
  obs.obs_properties_add_bool(props, "show_days", "Tage anzeigen")
  obs.obs_properties_add_bool(props, "show_hours", "Stunden anzeigen")
  obs.obs_properties_add_bool(props, "show_labels", "Beschriftungen (Tage/Std/Min/Sek)")
  obs.obs_properties_add_bool(props, "shadow", "Textschatten")
  obs.obs_properties_add_text(props, "endtext", "Text bei Ablauf", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_font(props, "font", "Schrift")
  obs.obs_properties_add_color_alpha(props, "color", "Textfarbe")

  -- Hintergrund
  local bg = obs.obs_properties_add_list(props, "bg_mode", "Hintergrund",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(bg, "Transparent", "none")
  obs.obs_property_list_add_string(bg, "Einfarbig", "solid")
  obs.obs_property_list_add_string(bg, "Animiert", "anim")
  obs.obs_property_set_modified_callback(bg, on_bg_mode_changed)
  obs.obs_properties_add_color_alpha(props, "bgcolor", "Hintergrundfarbe")
  obs.obs_properties_add_int_slider(props, "radius", "Eckenradius (px)", 0, 100, 1)

  local anim = obs.obs_properties_add_list(props, "anim", "Animations-Stil",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(anim, "Farbverlauf", "gradient")
  obs.obs_property_list_add_string(anim, "Aurora", "aurora")
  obs.obs_property_list_add_string(anim, "Wellen", "waves")
  obs.obs_property_list_add_string(anim, "Partikel-Netz", "particles")
  obs.obs_property_list_add_string(anim, "Sternenflug", "stars")
  obs.obs_property_list_add_string(anim, "Bokeh", "bokeh")
  obs.obs_property_list_add_string(anim, "Neon-Puls", "neon")
  obs.obs_property_list_add_string(anim, "Streifen", "stripes")
  obs.obs_property_list_add_string(anim, "Matrix", "matrix")
  obs.obs_properties_add_color_alpha(props, "c1", "Farbe 1")
  obs.obs_properties_add_color_alpha(props, "c2", "Farbe 2")
  obs.obs_properties_add_color_alpha(props, "c3", "Farbe 3")
  obs.obs_properties_add_color_alpha(props, "base", "Grundfarbe")
  obs.obs_properties_add_float_slider(props, "speed", "Geschwindigkeit", 0.1, 3.0, 0.1)

  -- Automatik
  local auto = obs.obs_properties_add_list(props, "auto_scene", "Automatisch starten, wenn Szene aktiv wird",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  fill_scene_list(auto)
  obs.obs_properties_add_bool(props, "auto_reset", "Dabei vorher zurücksetzen")
  local endscene = obs.obs_properties_add_list(props, "end_scene", "Bei Ablauf zu Szene wechseln",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  fill_scene_list(endscene)

  if settings_ref ~= nil then
    on_mode_changed(props, nil, settings_ref)
    on_bg_mode_changed(props, nil, settings_ref)
  end
  return props
end

-- Farben als 0xAABBGGRR
local function rgba(r, g, b, a) return a * 16777216 + b * 65536 + g * 256 + r end

function script_defaults(s)
  dbg("script_defaults")
  obs.obs_data_set_default_int(s, "width", 1920)
  obs.obs_data_set_default_int(s, "height", 1080)
  obs.obs_data_set_default_string(s, "pos", "mc")
  obs.obs_data_set_default_int(s, "margin", 40)
  obs.obs_data_set_default_string(s, "mode", "duration")
  obs.obs_data_set_default_int(s, "dur_h", 0)
  obs.obs_data_set_default_int(s, "dur_m", 10)
  obs.obs_data_set_default_int(s, "dur_s", 0)
  obs.obs_data_set_default_string(s, "target", "20:00")
  obs.obs_data_set_default_bool(s, "show_days", false)
  obs.obs_data_set_default_bool(s, "show_hours", false)
  obs.obs_data_set_default_bool(s, "show_labels", false)
  obs.obs_data_set_default_bool(s, "shadow", true)
  obs.obs_data_set_default_string(s, "endtext", "Stream startet jetzt!")
  obs.obs_data_set_default_int(s, "color", rgba(255, 255, 255, 255))

  -- Den Standard für die Schrift nur einmal setzen. Beim Neuladen des Scripts
  -- bleibt das Einstellungs-Objekt erhalten; ein erneutes
  -- obs_data_set_default_obj führte dann zu einem Absturz in obs_data_release.
  if not obs.obs_data_has_default_value(s, "font") then
    local font = obs.obs_data_create()
    obs.obs_data_set_string(font, "face", "Arial")
    obs.obs_data_set_int(font, "size", 96)
    obs.obs_data_set_int(font, "flags", 1)
    obs.obs_data_set_default_obj(s, "font", font)
    obs.obs_data_release(font)
  end

  obs.obs_data_set_default_string(s, "bg_mode", "anim")
  obs.obs_data_set_default_int(s, "bgcolor", rgba(0, 0, 0, 180))
  obs.obs_data_set_default_int(s, "radius", 12)
  obs.obs_data_set_default_string(s, "anim", "gradient")
  obs.obs_data_set_default_int(s, "c1", rgba(106, 92, 255, 255))
  obs.obs_data_set_default_int(s, "c2", rgba(255, 79, 163, 255))
  obs.obs_data_set_default_int(s, "c3", rgba(34, 211, 238, 255))
  obs.obs_data_set_default_int(s, "base", rgba(11, 11, 26, 255))
  obs.obs_data_set_default_double(s, "speed", 1.0)
  obs.obs_data_set_default_bool(s, "auto_reset", true)
end

function script_update(s)
  dbg("script_update")
  settings_ref = s
  read_settings(s)
  push_to_source()
end

---------------------------------------------------------------------------
-- Hotkeys
---------------------------------------------------------------------------

local HOTKEYS = {
  { id = "obstimer.startpause", label = "OBSTimer: Start / Pause", fn = start_pause },
  { id = "obstimer.reset",      label = "OBSTimer: Zurücksetzen", fn = reset },
  { id = "obstimer.plus1",      label = "OBSTimer: +1 Minute",    fn = function() add_seconds(60) end },
  { id = "obstimer.minus1",     label = "OBSTimer: −1 Minute",    fn = function() add_seconds(-60) end },
}

function script_load(s)
  dbg("script_load: Start")
  settings_ref = s
  read_settings(s)
  dbg("script_load: Einstellungen gelesen")
  for _, h in ipairs(HOTKEYS) do
    local fn = h.fn
    hk[h.id] = obs.obs_hotkey_register_frontend(h.id, h.label, function(pressed)
      if pressed then fn() end
    end)
    local arr = obs.obs_data_get_array(s, h.id)
    obs.obs_hotkey_load(hk[h.id], arr)
    obs.obs_data_array_release(arr)
  end
  dbg("script_load: Hotkeys registriert")
  -- Die Quelle wird nicht hier, sondern beim ersten Timer-Durchlauf befüllt
  last_url = nil
  obs.timer_add(tick, 250)
  dbg("script_load: Ende")
end

function script_save(s)
  dbg("script_save")
  for _, h in ipairs(HOTKEYS) do
    local arr = obs.obs_hotkey_save(hk[h.id])
    obs.obs_data_set_array(s, h.id, arr)
    obs.obs_data_array_release(arr)
  end
end

function script_unload()
  dbg("script_unload")
end
