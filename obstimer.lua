--[[
  OBSTimer – Countdown-Quelle für OBS Studio

  Installation: OBS > Werkzeuge > Skripte > "+" > obstimer.lua auswählen.
  Die Datei obstimer.html muss im selben Ordner liegen wie dieses Script.

  Das Script registriert eine eigene Quelle "OBSTimer". Du fügst sie wie jede
  andere Quelle in eine Szene ein; ein Doppelklick auf die Quelle öffnet alle
  Einstellungen. Intern rendert jede OBSTimer-Quelle eine private
  Browserquelle mit obstimer.html; die Einstellungen werden als URL-Parameter
  übergeben.
]]

obs = obslua

local SCRIPT_VERSION = "2.0.0"
local SOURCE_ID = "obstimer_source"
local SOURCE_NAME = "OBSTimer"

-- Alle aktiven OBSTimer-Quellen (Schlüssel: Instanz-Tabelle)
local instances = {}

local hk = {}             -- Hotkey-IDs (global, wirken auf alle Timer)

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

-- Farben als 0xAABBGGRR
local function rgba(r, g, b, a) return a * 16777216 + b * 65536 + g * 256 + r end

local SCRIPT_DIR = nil
local function html_url()
  local dir = (SCRIPT_DIR or script_path()):gsub("\\", "/")
  if dir:sub(-1) ~= "/" then dir = dir .. "/" end
  if dir:sub(1, 1) ~= "/" then dir = "/" .. dir end -- Windows: /C:/...
  return "file://" .. path_encode(dir .. "obstimer.html")
end

---------------------------------------------------------------------------
-- Einstellungen einer Quelle lesen
---------------------------------------------------------------------------

local function read_settings(s)
  local cfg = {}
  cfg.width       = obs.obs_data_get_int(s, "width")
  cfg.height      = obs.obs_data_get_int(s, "height")
  cfg.pos         = obs.obs_data_get_string(s, "pos")
  cfg.margin      = obs.obs_data_get_int(s, "margin")
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

  -- Nur eine selbst gewählte Schrift auslesen. Den Standard-Wert (ein
  -- obs_data-Objekt) fassen wir nicht an: das führte beim Neuladen des
  -- Scripts zu einem Absturz in obs_data_release.
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

  cfg.auto_start  = obs.obs_data_get_bool(s, "auto_start")
  cfg.auto_reset  = obs.obs_data_get_bool(s, "auto_reset")
  cfg.end_scene   = obs.obs_data_get_string(s, "end_scene")
  if cfg.width <= 0 then cfg.width = 1920 end
  if cfg.height <= 0 then cfg.height = 1080 end
  return cfg
end

---------------------------------------------------------------------------
-- Timer-Logik pro Quelle
---------------------------------------------------------------------------

-- Dauer aus den Einstellungen in Sekunden
local function configured_duration(d)
  local cfg = d.cfg
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

local function remaining(d)
  if d.state == "run" then return math.max(0, d.end_ts - now()) end
  if d.state == "pause" then return math.max(0, d.paused_rem) end
  return configured_duration(d)
end

local function build_url(d)
  local cfg = d.cfg
  local p = {}
  local function add(k, v) p[#p + 1] = k .. "=" .. url_encode(v) end
  local function flag(v) return v and "1" or "0" end

  add("state", d.state)
  if d.state == "run" then
    add("end", string.format("%.0f", d.end_ts * 1000))
  else
    add("rem", string.format("%.0f", remaining(d) * 1000))
  end
  add("days", flag(cfg.show_days))
  add("hours", flag(cfg.show_hours))
  add("labels", flag(cfg.show_labels))
  add("shadow", flag(cfg.shadow))
  add("endtext", cfg.endtext or "")
  add("color", cfg.color)
  add("font", cfg.font_face)
  add("size", cfg.font_size)
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

-- Überträgt den aktuellen Zustand an die interne Browserquelle
local function push(d, force)
  if d.browser == nil then return end
  local url = build_url(d)
  local size = d.cfg.width .. "x" .. d.cfg.height
  if not force and url == d.last_url and size == d.last_size then return end
  local s = obs.obs_data_create()
  obs.obs_data_set_bool(s, "is_local_file", false)
  obs.obs_data_set_string(s, "url", url)
  obs.obs_data_set_int(s, "width", d.cfg.width)
  obs.obs_data_set_int(s, "height", d.cfg.height)
  obs.obs_source_update(d.browser, s)
  obs.obs_data_release(s)
  d.last_url = url
  d.last_size = size
end

local function start(d)
  if d.state == "pause" then
    d.end_ts = now() + d.paused_rem
  else
    d.end_ts = now() + configured_duration(d)
  end
  d.state = "run"
  d.finished_handled = false
  push(d)
end

local function pause(d)
  if d.state ~= "run" then return end
  d.paused_rem = math.max(0, d.end_ts - now())
  d.state = "pause"
  push(d)
end

local function start_pause(d)
  if d.state == "run" then pause(d) else start(d) end
end

local function reset(d)
  d.state = "stop"
  d.finished_handled = false
  push(d)
end

local function add_seconds(d, delta)
  if d.state == "run" then
    d.end_ts = math.max(now(), d.end_ts + delta)
    if d.end_ts > now() then d.finished_handled = false end
  elseif d.state == "pause" then
    d.paused_rem = math.max(0, d.paused_rem + delta)
  elseif d.cfg.mode ~= "target" then
    -- Im Stopp-Zustand wird die eingestellte Dauer der Quelle verändert
    local total = math.max(0, configured_duration(d) + delta)
    local s = obs.obs_source_get_settings(d.source)
    obs.obs_data_set_int(s, "dur_h", math.floor(total / 3600))
    obs.obs_data_set_int(s, "dur_m", math.floor(total % 3600 / 60))
    obs.obs_data_set_int(s, "dur_s", total % 60)
    d.cfg = read_settings(s)
    obs.obs_data_release(s)
  end
  push(d)
end

local function for_all(fn)
  for d in pairs(instances) do fn(d) end
end

---------------------------------------------------------------------------
-- Globaler Timer: Ablauf erkennen, Szene wechseln
---------------------------------------------------------------------------

local function switch_scene(name)
  if not name or name == "" then return end
  local scene = obs.obs_get_source_by_name(name)
  if scene ~= nil then
    obs.obs_frontend_set_current_scene(scene)
    obs.obs_source_release(scene)
  end
end

-- Läuft alle 250 ms. Wichtig: Das Script registriert bewusst KEINEN
-- Frontend-Event-Callback. OBS hält während dieses Timers die Sperre des
-- Scripts; ein Szenenwechsel von hier aus löst im UI-Thread ein
-- SCENE_CHANGED-Event aus, und ein Lua-Event-Callback würde dann auf genau
-- diese Sperre warten (Deadlock/Absturz).
local function tick()
  local target = nil
  for d in pairs(instances) do
    if d.state == "run" and not d.finished_handled and now() >= d.end_ts then
      d.finished_handled = true
      if d.cfg.end_scene ~= "" and target == nil then target = d.cfg.end_scene end
    end
  end
  if target then switch_scene(target) end
end

---------------------------------------------------------------------------
-- Einstellungs-Oberfläche einer Quelle
---------------------------------------------------------------------------

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

local function source_properties(d)
  local props = obs.obs_properties_create()

  -- Steuerung
  if d ~= nil then
    obs.obs_properties_add_button(props, "btn_startpause", "▶ Start / ⏸ Pause", function() start_pause(d) return false end)
    obs.obs_properties_add_button(props, "btn_reset", "⟲ Zurücksetzen", function() reset(d) return false end)
    obs.obs_properties_add_button(props, "btn_plus", "+1 Minute", function() add_seconds(d, 60) return true end)
    obs.obs_properties_add_button(props, "btn_minus", "−1 Minute", function() add_seconds(d, -60) return true end)
  end

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

  -- Größe und Position
  obs.obs_properties_add_int(props, "width", "Breite (px)", 100, 7680, 10)
  obs.obs_properties_add_int(props, "height", "Höhe (px)", 50, 4320, 10)
  local pos = obs.obs_properties_add_list(props, "pos", "Position des Countdowns",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  for _, e in ipairs({
    { "Oben links", "tl" }, { "Oben Mitte", "tc" }, { "Oben rechts", "tr" },
    { "Mitte links", "ml" }, { "Mitte", "mc" }, { "Mitte rechts", "mr" },
    { "Unten links", "bl" }, { "Unten Mitte", "bc" }, { "Unten rechts", "br" },
  }) do obs.obs_property_list_add_string(pos, e[1], e[2]) end
  obs.obs_properties_add_int(props, "margin", "Abstand zum Rand (px)", 0, 1000, 5)

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
  obs.obs_properties_add_bool(props, "auto_start", "Automatisch starten, wenn die Quelle auf Sendung geht")
  obs.obs_properties_add_bool(props, "auto_reset", "Dabei vorher zurücksetzen")
  local endscene = obs.obs_properties_add_list(props, "end_scene", "Bei Ablauf zu Szene wechseln",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  fill_scene_list(endscene)

  if d ~= nil and d.source ~= nil then
    local s = obs.obs_source_get_settings(d.source)
    on_mode_changed(props, nil, s)
    on_bg_mode_changed(props, nil, s)
    obs.obs_data_release(s)
  end
  return props
end

local function source_defaults(s)
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

  -- Den Standard für die Schrift nur einmal setzen (siehe read_settings)
  if not obs.obs_data_has_default_value(s, "font") then
    local font = obs.obs_data_create()
    obs.obs_data_set_string(font, "face", "Arial")
    obs.obs_data_set_int(font, "size", 96)
    obs.obs_data_set_int(font, "flags", 1)
    obs.obs_data_set_default_obj(s, "font", font)
    obs.obs_data_release(font)
  end

  obs.obs_data_set_default_string(s, "bg_mode", "anim")
  obs.obs_data_set_default_int(s, "bgcolor", rgba(30, 30, 60, 200))
  obs.obs_data_set_default_int(s, "radius", 0)
  obs.obs_data_set_default_string(s, "anim", "gradient")
  obs.obs_data_set_default_int(s, "c1", rgba(106, 92, 255, 255))
  obs.obs_data_set_default_int(s, "c2", rgba(255, 79, 163, 255))
  obs.obs_data_set_default_int(s, "c3", rgba(34, 211, 238, 255))
  obs.obs_data_set_default_int(s, "base", rgba(20, 20, 45, 255))
  obs.obs_data_set_default_double(s, "speed", 1.0)
  obs.obs_data_set_default_bool(s, "auto_start", false)
  obs.obs_data_set_default_bool(s, "auto_reset", true)
end

---------------------------------------------------------------------------
-- Quellen-Definition
---------------------------------------------------------------------------

-- Die interne Browserquelle zeichnet nur, wenn OBS sie als "sichtbar"
-- führt. Eine Lua-Quelle kann OBS ihre Kind-Quelle nicht melden, deshalb
-- reichen wir Sichtbarkeit und Aktivität selbst weiter.
local function child_show(d, on)
  if d.browser == nil or d.showing == on then return end
  d.showing = on
  if on then obs.obs_source_inc_showing(d.browser) else obs.obs_source_dec_showing(d.browser) end
end

local function child_active(d, on)
  if d.browser == nil or d.active == on then return end
  if obs.obs_source_inc_active == nil then return end -- ältere OBS-Versionen
  d.active = on
  if on then obs.obs_source_inc_active(d.browser) else obs.obs_source_dec_active(d.browser) end
end

local source_def = {
  id = SOURCE_ID,
  type = obs.OBS_SOURCE_TYPE_INPUT,
  output_flags = obs.OBS_SOURCE_VIDEO + obs.OBS_SOURCE_CUSTOM_DRAW,
}

source_def.get_name = function() return SOURCE_NAME end

source_def.create = function(settings, source)
  local d = {
    source = source,
    state = "stop", end_ts = 0, paused_rem = 0,
    finished_handled = false,
  }
  d.cfg = read_settings(settings)
  local bs = obs.obs_data_create()
  obs.obs_data_set_bool(bs, "is_local_file", false)
  obs.obs_data_set_string(bs, "url", "about:blank")
  obs.obs_data_set_int(bs, "width", d.cfg.width)
  obs.obs_data_set_int(bs, "height", d.cfg.height)
  d.browser = obs.obs_source_create_private("browser_source", "OBSTimer (intern)", bs)
  obs.obs_data_release(bs)
  d.showing, d.active = false, false
  -- Nach dem Neuladen des Scripts ist die Quelle evtl. schon sichtbar
  if obs.obs_source_showing(source) then child_show(d, true) end
  if obs.obs_source_active(source) then child_active(d, true) end
  instances[d] = true
  push(d, true)
  dbg("Quelle erstellt")
  return d
end

source_def.destroy = function(d)
  if d == nil then return end
  instances[d] = nil
  if d.browser ~= nil then
    child_active(d, false)
    child_show(d, false)
    obs.obs_source_release(d.browser)
    d.browser = nil
  end
  dbg("Quelle entfernt")
end

source_def.update = function(d, settings)
  d.cfg = read_settings(settings)
  push(d)
end

source_def.get_defaults = function(settings) source_defaults(settings) end
source_def.get_properties = function(d) return source_properties(d) end
source_def.get_width = function(d) return d.cfg.width end
source_def.get_height = function(d) return d.cfg.height end

source_def.video_render = function(d, effect)
  if d.browser ~= nil then obs.obs_source_video_render(d.browser) end
end

source_def.show = function(d) child_show(d, true) end
source_def.hide = function(d) child_show(d, false) end
source_def.deactivate = function(d) child_active(d, false) end

-- Wird aufgerufen, wenn die Quelle auf Sendung (Programm) geht
source_def.activate = function(d)
  child_active(d, true)
  if d.cfg.auto_start and d.state ~= "run" then
    if d.cfg.auto_reset then d.state = "stop" end
    start(d)
  end
end

---------------------------------------------------------------------------
-- Script-Fenster (Werkzeuge > Skripte)
---------------------------------------------------------------------------

local function unique_name()
  local name, i = SOURCE_NAME, 1
  while true do
    local existing = obs.obs_get_source_by_name(name)
    if existing == nil then return name end
    obs.obs_source_release(existing)
    i = i + 1
    name = SOURCE_NAME .. " " .. i
  end
end

local function btn_create_source()
  local scene_src = obs.obs_frontend_get_current_scene()
  if scene_src == nil then return false end
  local src = obs.obs_source_create(SOURCE_ID, unique_name(), nil, nil)
  if src ~= nil then
    obs.obs_scene_add(obs.obs_scene_from_source(scene_src), src)
    obs.obs_source_release(src)
  end
  obs.obs_source_release(scene_src)
  return false
end

function script_description()
  return [[<h2>OBSTimer</h2>
<p>Countdown-Quelle für OBS mit soliden oder animierten Hintergründen.</p>
<p>Füge in einer Szene über <b>+ → OBSTimer</b> eine Timer-Quelle hinzu
(oder nutze den Button unten). Ein <b>Doppelklick auf die Quelle</b> öffnet
alle Einstellungen, inklusive Start/Pause.</p>
<p>Die Hotkeys (Einstellungen &gt; Hotkeys &gt; „OBSTimer“) wirken auf alle
OBSTimer-Quellen gleichzeitig.</p>
<p><small>Version ]] .. SCRIPT_VERSION .. [[</small></p>]]
end

function script_properties()
  local props = obs.obs_properties_create()
  obs.obs_properties_add_button(props, "btn_create", "OBSTimer-Quelle in aktueller Szene erstellen", btn_create_source)
  obs.obs_properties_add_button(props, "btn_all_startpause", "Alle Timer: Start / Pause", function() for_all(start_pause) return false end)
  obs.obs_properties_add_button(props, "btn_all_reset", "Alle Timer: Zurücksetzen", function() for_all(reset) return false end)
  return props
end

---------------------------------------------------------------------------
-- Hotkeys
---------------------------------------------------------------------------

local HOTKEYS = {
  { id = "obstimer.startpause", label = "OBSTimer: Start / Pause", fn = function() for_all(start_pause) end },
  { id = "obstimer.reset",      label = "OBSTimer: Zurücksetzen", fn = function() for_all(reset) end },
  { id = "obstimer.plus1",      label = "OBSTimer: +1 Minute",    fn = function() for_all(function(d) add_seconds(d, 60) end) end },
  { id = "obstimer.minus1",     label = "OBSTimer: −1 Minute",    fn = function() for_all(function(d) add_seconds(d, -60) end) end },
}

function script_load(s)
  dbg("script_load")
  SCRIPT_DIR = script_path()
  for _, h in ipairs(HOTKEYS) do
    local fn = h.fn
    hk[h.id] = obs.obs_hotkey_register_frontend(h.id, h.label, function(pressed)
      if pressed then fn() end
    end)
    local arr = obs.obs_data_get_array(s, h.id)
    obs.obs_hotkey_load(hk[h.id], arr)
    obs.obs_data_array_release(arr)
  end
  obs.obs_register_source(source_def)
  obs.timer_add(tick, 250)
end

function script_save(s)
  for _, h in ipairs(HOTKEYS) do
    local arr = obs.obs_hotkey_save(hk[h.id])
    obs.obs_data_set_array(s, h.id, arr)
    obs.obs_data_array_release(arr)
  end
end

function script_unload()
  dbg("script_unload")
end
