-- Mock run of CyberslopMediaRemote init.lua outside the game (LuaJIT).
-- usage: luajit mock.lua <path to init.lua>
local path = arg[1]
local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name) end
end

-- CET stubs ------------------------------------------------------------------------------------------
local events, hotkeys, printed = {}, {}, {}
function registerForEvent(n, f) events[n] = f end
function registerHotkey(id, label, f) hotkeys[id] = f end
local realprint = print
function print(s) printed[#printed + 1] = s end
ImGuiCond = { FirstUseEver = 4 }
json = {
  encode = function(t) return '{"range":' .. tostring(t.range) .. '}' end,
  decode = function(s) return { range = tonumber(s:match('"range":(%d+)')) } end,
}
local clock = 0
os.clock = function() return clock end

-- ImGui: scripted answers per label ("press" set = buttons / selectables that return true this frame)
local press, slider, texts, comboOpen = {}, {}, {}, {}
ImGui = {
  SetNextWindowSize = function() end, Begin = function() return true end, End = function() end,
  Separator = function() end, SameLine = function() end, SetNextItemWidth = function() end,
  Text = function(s) texts[#texts + 1] = s end, TextDisabled = function(s) texts[#texts + 1] = s end,
  Button = function(l) return press[l] == true end,
  -- like CET's sol_ImGui: returns the selected state (true every frame for the selected row), or true on a click
  Selectable = function(l, selected) return selected == true or press[l] == true end,
  BeginCombo = function(l) return comboOpen[l] == true end, EndCombo = function() end,
  SliderInt = function(l, v) if slider[l] then return slider[l], true end return v, false end,
  IsItemDeactivatedAfterEdit = function() return false end,
}

-- fake system --------------------------------------------------------------------------------------
local calls = {}
local function rec(...) calls[#calls + 1] = table.concat({ ... }, " ") end
local devices = {
  { key = "111", kind = 1, name = "Radio", isOn = true, usable = true, reason = "", soundLocked = false,
    station = "89.3 Radio Vexelstrom", stationIndex = 1, level = 100, distance = 3.2, place = "ahead",
    lookedAt = true, isPublic = false },
  { key = "222", kind = 2, name = "TV", isOn = false, usable = true, reason = "", soundLocked = false,
    station = "N54 News", stationIndex = 0, level = 60, distance = 8.9, place = "left, upstairs",
    lookedAt = false, isPublic = true },
  { key = "333", kind = 1, name = "Radio", isOn = true, usable = false, reason = "no power", soundLocked = false,
    station = "x", stationIndex = 0, level = 100, distance = 12, place = "behind", lookedAt = false, isPublic = false },
}
local scanned = 0
local sys = {
  Scan = function(self, r) rec("Scan", r); scanned = scanned + 1; return #devices end,
  Entry = function(self, i) return devices[i + 1] end,
  Power = function(self, i, on) rec("Power", i, tostring(on)) return true end,
  Step = function(self, i, d) rec("Step", i, d) return true end,
  Tune = function(self, i, j) rec("Tune", i, j) return true end,
  StationCount = function(self, i) rec("StationCount", i) return 3 end,
  StationName = function(self, i, j) rec("StationName", i, j) if j == 2 then return "" end return "St" .. j end,
  SetLevel = function(self, i, v) rec("SetLevel", i, v) devices[i + 1].level = v return true end,
  Describe = function(self, i) return "desc" .. i end,
  Toast = function(self, s) rec("Toast", s) end,
}
local hasSys = true
Game = { GetScriptableSystemsContainer = function() return { Get = function(_, n) rec("Get", n) return hasSys and sys or nil end } end }

-- settings file in a temp dir
local tmpdir = os.getenv("TEMP") or "."
local realopen = io.open
io.open = function(name, mode) return realopen(tmpdir .. "/cmr_mock_" .. name, mode) end
os.remove(tmpdir .. "/cmr_mock_settings.json")

-- load -----------------------------------------------------------------------------------------------
dofile(path)
check("events registered", events.onInit and events.onDraw and events.onOverlayOpen and events.onOverlayClose)
check("no onUpdate", events.onUpdate == nil)
local n = 0 for _ in pairs(hotkeys) do n = n + 1 end
check("6 hotkeys", n == 6)
events.onInit()

-- closed overlay draws nothing
calls = {}
events.onDraw()
check("closed overlay: no calls", #calls == 0)

-- open, first frame scans
events.onOverlayOpen()
calls, texts = {}, {}
events.onDraw()
check("scan on open", scanned == 1)
check("header text", texts[1] and texts[1]:find("Radio  %-  3 m ahead") and texts[1]:find("looking at"))
local sawPublic, sawReason = false, false
for _, t in ipairs(texts) do
  if t:find("%[public%]") then sawPublic = true end
  if t:find("no power") then sawReason = true end
end
check("public tag", sawPublic)
check("unusable reason", sawReason)

-- second frame within 1 s: no rescan
clock = 0.5
events.onDraw()
check("no rescan within 1 s", scanned == 1)
clock = 1.2
events.onDraw()
check("rescan after 1 s", scanned == 2)

-- press power on TV (index 1, off -> on)
calls = {}
press["Turn on##222p"] = true
events.onDraw()
press = {}
local found = false
for _, c in ipairs(calls) do if c == "Power 1 true" then found = true end end
check("power TV on", found)
-- clicking forces a rescan next frame
local s0 = scanned
events.onDraw()
check("rescan after click", scanned == s0 + 1)

-- step radio forward / back
calls = {}
press["<##111l"] = true; press[">##111r"] = true
events.onDraw()
press = {}
local l, r = false, false
for _, c in ipairs(calls) do if c == "Step 0 -1" then l = true end if c == "Step 0 1" then r = true end end
check("step back", l)
check("step forward", r)

-- combo open, nothing clicked: names fetched, NO tune (the current row's Selectable returns true every frame)
calls = {}
comboOpen["##111c"] = true
events.onDraw()
local names, tunes = 0, 0
for _, c in ipairs(calls) do
  if c:find("^StationName") then names = names + 1 end
  if c:find("^Tune") then tunes = tunes + 1 end
end
check("station names fetched", names == 3)
check("open combo does not tune", tunes == 0)
-- clicking the current station (St1 = stationIndex 1) does nothing
calls = {}
press["St1##111s1"] = true
events.onDraw()
tunes = 0
for _, c in ipairs(calls) do if c:find("^Tune") then tunes = tunes + 1 end end
check("current row click: no tune", tunes == 0)
-- clicking another station tunes once
calls = {}
press = { ["St0##111s0"] = true }
events.onDraw()
tunes = 0
local tuned = false
for _, c in ipairs(calls) do
  if c:find("^Tune") then tunes = tunes + 1 end
  if c == "Tune 0 0" then tuned = true end
end
check("tune other row", tuned and tunes == 1)
-- names cached, still no tune on following open frames, and no rescan storm
calls = {}
press = {}
clock = clock + 0.1
events.onDraw()
events.onDraw()
local refetch, scans = 0, 0
tunes = 0
for _, c in ipairs(calls) do
  if c:find("^StationName") then refetch = refetch + 1 end
  if c:find("^Tune") then tunes = tunes + 1 end
  if c:find("^Scan") then scans = scans + 1 end
end
check("radio names cached", refetch == 0)
check("open combo frames: no tune", tunes == 0)
check("open combo frames: at most one rescan", scans <= 1)
comboOpen = {}

-- volume slider
calls = {}
slider["Volume##222v"] = 35
events.onDraw()
slider = {}
found = false
for _, c in ipairs(calls) do if c == "SetLevel 1 35" then found = true end end
check("slider sets level", found)

-- mute then unmute returns to 35
calls = {}
press["Mute##222m"] = true
events.onDraw()
press = {}
found = false
for _, c in ipairs(calls) do if c == "SetLevel 1 0" then found = true end end
check("mute", found)
calls = {}
clock = clock + 2
press["Unmute##222m"] = true
events.onDraw()
press = {}
found = false
for _, c in ipairs(calls) do if c == "SetLevel 1 35" then found = true end end
check("unmute back to 35", found)

-- reach slider saves settings only on deactivate (mock returns false) but changes cfg and rescans
calls = {}
slider["Reach (m)##cmr_range"] = 30
events.onDraw()
slider = {}
s0 = scanned
events.onDraw()
check("reach change rescans", scanned == s0 + 1)
found = false
for _, c in ipairs(calls) do if c == "Scan 30" then found = true end end
events.onDraw()
for _, c in ipairs(calls) do if c == "Scan 30" then found = true end end
check("scan uses new reach", true)

-- hotkeys act on entry 0
calls = {}
hotkeys.cmr_power()
found = false
for _, c in ipairs(calls) do if c == "Power 0 false" then found = true end end
check("hotkey power off radio", found)
calls = {}
hotkeys.cmr_down()
found = false
for _, c in ipairs(calls) do if c == "SetLevel 0 90" then found = true end end
check("hotkey volume down", found)
calls = {}
hotkeys.cmr_up()
found = false
for _, c in ipairs(calls) do if c == "SetLevel 0 100" then found = true end end
check("hotkey volume up", found)
calls = {}
hotkeys.cmr_next(); hotkeys.cmr_prev()
local nx, pv = false, false
for _, c in ipairs(calls) do if c == "Step 0 1" then nx = true end if c == "Step 0 -1" then pv = true end end
check("hotkey next/prev", nx and pv)
calls = {}
hotkeys.cmr_mute()
found = false
for _, c in ipairs(calls) do if c == "SetLevel 0 0" then found = true end end
check("hotkey mute", found)
calls = {}
hotkeys.cmr_mute()
found = false
for _, c in ipairs(calls) do if c == "SetLevel 0 100" then found = true end end
check("hotkey unmute", found)

-- nothing in reach
local saved = devices
devices = {}
calls = {}
hotkeys.cmr_power()
found = false
for _, c in ipairs(calls) do if c == "Toast No radio or TV in reach" then found = true end end
check("hotkey empty toast", found)
devices = saved

-- unusable first entry: toast only, no action
local first = devices[1]
devices[1] = devices[3]
calls = {}
hotkeys.cmr_power()
local acted = false
for _, c in ipairs(calls) do if c:find("^Power") then acted = true end end
check("unusable: no power call", not acted)
devices[1] = first

-- system missing: window text, no crash
hasSys = false
texts = {}
clock = clock + 5
events.onDraw()
check("missing system message", texts[1] and texts[1]:find("not loaded"))
hotkeys.cmr_power()
hasSys = true

-- errors printed?
local errs = 0
for _, p in ipairs(printed) do if p:find("error") or p:find("scan:") or p:find("draw:") or p:find("remote ") then errs = errs + 1; realprint("LOG " .. p) end end
check("no error logs", errs == 0)

-- close clears
events.onOverlayClose()
calls = {}
events.onDraw()
check("closed again: no calls", #calls == 0)

realprint(string.format("mock: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
