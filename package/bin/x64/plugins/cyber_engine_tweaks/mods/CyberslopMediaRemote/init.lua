-- Cyberslop Media Remote 1.0.2 (2026-11-22)
-- CET window + optional remote keys for the radios and TVs around V. All game work is in the redscript
-- system CyberslopMediaRemote.MediaRemoteSystem (r6\scripts\CyberslopMediaRemote); this file only draws.
-- Cost: no onUpdate; onDraw returns at once unless the CET overlay is open; while it is open the device
-- list is rebuilt once a second (plus right after a click). Station lists are cached.

local VERSION = "1.0.2"
local SYS = "CyberslopMediaRemote.MediaRemoteSystem"
local SETTINGS = "settings.json"

local cfg = { range = 20 }
local overlay = false
local list = {}          -- plain Lua copies of MediaRemoteEntry
local nextScan = 0
local radioNames = nil   -- { {pos, name}, ... } shared by all radios
local radioCount = -1
local tvNames = {}       -- key -> { {pos, name}, ... }
local beforeMute = {}    -- key -> level to return to on unmute (this session)

local function muteTarget(e)
  if e.level <= 0 then return beforeMute[e.key] or 100 end
  beforeMute[e.key] = e.level
  return 0
end

local function log(msg) print("[CyberslopMediaRemote] " .. msg) end

local function system()
  local ok, s = pcall(function() return Game.GetScriptableSystemsContainer():Get(SYS) end)
  if ok and s then return s end
  return nil
end

local function loadSettings()
  local f = io.open(SETTINGS, "r")
  if not f then return end
  local ok, t = pcall(function() return json.decode(f:read("*a")) end)
  f:close()
  if ok and type(t) == "table" and tonumber(t.range) then
    cfg.range = math.max(5, math.min(40, math.floor(tonumber(t.range))))
  end
end

local function saveSettings()
  local f = io.open(SETTINGS, "w")
  if not f then return end
  f:write(json.encode(cfg))
  f:close()
end

local function scan(sys)
  local n = sys:Scan(cfg.range)
  local out = {}
  for i = 0, n - 1 do
    local e = sys:Entry(i)
    if e then
      out[#out + 1] = {
        i = i, key = e.key, kind = e.kind, name = e.name, isOn = e.isOn, usable = e.usable,
        reason = e.reason, soundLocked = e.soundLocked, station = e.station, stationIndex = e.stationIndex,
        level = e.level, distance = e.distance, place = e.place, lookedAt = e.lookedAt, isPublic = e.isPublic,
      }
    end
  end
  list = out
end

local function stationList(sys, e)
  local count = sys:StationCount(e.i)
  if e.kind == 1 then
    if radioNames and count == radioCount then return radioNames end
    radioCount = count
  elseif tvNames[e.key] and #tvNames[e.key] > 0 then
    return tvNames[e.key]
  end
  local names = {}
  for j = 0, count - 1 do
    local s = sys:StationName(e.i, j)
    if s and s ~= "" then names[#names + 1] = { j, s } end
  end
  if e.kind == 1 then radioNames = names else tvNames[e.key] = names end
  return names
end

-- one device block
local function drawDevice(sys, e)
  local id = "##" .. e.key
  local head = string.format("%s  -  %.0f m %s%s%s", e.name, e.distance, e.place,
    e.isPublic and "  [public]" or "", e.lookedAt and "  << looking at" or "")
  ImGui.Separator()
  ImGui.Text(head)
  if not e.usable then
    ImGui.TextDisabled("  " .. e.reason)
    return
  end
  if ImGui.Button((e.isOn and "Turn off" or "Turn on") .. id .. "p", 70, 0) then
    sys:Power(e.i, not e.isOn)
    nextScan = 0
  end
  ImGui.SameLine()
  if ImGui.Button("<" .. id .. "l", 24, 0) then
    sys:Step(e.i, -1)
    nextScan = 0
  end
  ImGui.SameLine()
  ImGui.SetNextItemWidth(220)
  if ImGui.BeginCombo(id .. "c", e.station) then
    for _, row in ipairs(stationList(sys, e)) do
      -- CET's Selectable returns the row's selected state, not "clicked":
      -- the current row returns true every frame, so only a different row counts as a click.
      local cur = row[1] == e.stationIndex
      if ImGui.Selectable(row[2] .. id .. "s" .. row[1], cur) and not cur then
        sys:Tune(e.i, row[1])
        nextScan = 0
      end
    end
    ImGui.EndCombo()
  end
  ImGui.SameLine()
  if ImGui.Button(">" .. id .. "r", 24, 0) then
    sys:Step(e.i, 1)
    nextScan = 0
  end
  if e.soundLocked then
    ImGui.TextDisabled("  sound is off for this scene")
    return
  end
  ImGui.SetNextItemWidth(250)
  local fmt = e.level <= 0 and "muted" or "%d %%"
  local v, changed = ImGui.SliderInt("Volume" .. id .. "v", e.level, 0, 100, fmt)
  if changed and v ~= e.level then
    e.level = v
    sys:SetLevel(e.i, v)
  end
  ImGui.SameLine()
  if ImGui.Button((e.level <= 0 and "Unmute" or "Mute") .. id .. "m", 60, 0) then
    local target = muteTarget(e)
    e.level = target
    sys:SetLevel(e.i, target)
  end
end

local function draw()
  local sys = system()
  if not sys then
    ImGui.Text("Media Remote system not loaded (redscript part missing or not compiled).")
    return
  end
  local now = os.clock()
  if now >= nextScan then
    local ok, err = pcall(scan, sys)
    if not ok then log("scan: " .. tostring(err)) end
    nextScan = now + 1.0
  end
  ImGui.SetNextItemWidth(150)
  local r, changed = ImGui.SliderInt("Reach (m)##cmr_range", cfg.range, 5, 40)
  if changed then
    cfg.range = r
    nextScan = 0
  end
  if ImGui.IsItemDeactivatedAfterEdit() then saveSettings() end
  if #list == 0 then
    ImGui.TextDisabled("No radio or TV within reach. Look at one up to 40 m away to reach it.")
    return
  end
  for _, e in ipairs(list) do
    local ok, err = pcall(drawDevice, sys, e)
    if not ok then log("draw: " .. tostring(err)) break end
  end
end

-- remote keys: act on the device V looks at (up to 40 m), else the nearest within reach
local function remote(action)
  local ok, err = pcall(function()
    local sys = system()
    if not sys then return end
    if sys:Scan(cfg.range) == 0 then
      sys:Toast("No radio or TV in reach")
      return
    end
    local e = sys:Entry(0)
    if not e or not e.usable then
      sys:Toast(sys:Describe(0))
      return
    end
    if action == "power" then
      sys:Power(0, not e.isOn)
      sys:Toast(e.name .. (e.isOn and ": off" or ": on"))
      nextScan = 0
      return
    elseif action == "next" then sys:Step(0, 1)
    elseif action == "prev" then sys:Step(0, -1)
    elseif action == "up" then sys:SetLevel(0, math.min(100, e.level + 10))
    elseif action == "down" then sys:SetLevel(0, math.max(0, e.level - 10))
    elseif action == "mute" then sys:SetLevel(0, muteTarget(e))
    end
    sys:Toast(sys:Describe(0))
    nextScan = 0
  end)
  if not ok then log("remote " .. action .. ": " .. tostring(err)) end
end

registerHotkey("cmr_power", "Remote: power on / off", function() remote("power") end)
registerHotkey("cmr_next", "Remote: next station / channel", function() remote("next") end)
registerHotkey("cmr_prev", "Remote: previous station / channel", function() remote("prev") end)
registerHotkey("cmr_up", "Remote: volume up", function() remote("up") end)
registerHotkey("cmr_down", "Remote: volume down", function() remote("down") end)
registerHotkey("cmr_mute", "Remote: mute / unmute", function() remote("mute") end)

registerForEvent("onInit", function()
  loadSettings()
  log("loaded " .. VERSION)
end)

registerForEvent("onOverlayOpen", function()
  overlay = true
  nextScan = 0
end)

registerForEvent("onOverlayClose", function()
  overlay = false
  list = {}
end)

registerForEvent("onDraw", function()
  if not overlay then return end
  ImGui.SetNextWindowSize(420, 0, ImGuiCond.FirstUseEver)
  if ImGui.Begin("Cyberslop Media Remote") then
    draw()
  end
  ImGui.End()
end)
