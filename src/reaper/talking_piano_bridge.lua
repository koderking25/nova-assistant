-- Talking Piano bridge for REAPER.
-- Runs quietly in the background and carries out commands that the Talking Piano tool
-- writes to a small file, then writes back a sentence to be spoken. It only acts when
-- asked, and everything it changes can be undone with REAPER's normal undo.

local dir = reaper.GetResourcePath() .. "/Scripts/TalkingPiano/"
reaper.RecursiveCreateDirectory(dir, 0)
local cmdPath, replyPath = dir .. "cmd.txt", dir .. "reply.txt"

local function split(s)
  local t = {}
  for part in (s .. "\t"):gmatch("(.-)\t") do t[#t + 1] = part end
  return t
end

local function db(v)
  if v < 0.0000001 then return "silent" end
  local d = 20 * math.log(v, 10)
  if math.abs(d) < 0.05 then return "0 dB" end
  return string.format("%s %.0f dB", d > 0 and "plus" or "minus", math.abs(d))
end

local function track(i) return reaper.GetTrack(0, math.floor(tonumber(i) or 0) - 1) end
-- Track 0 or "master" is the master track.
local function anytrack(i)
  if i == "master" or i == "0" then return reaper.GetMasterTrack(0) end
  return track(i)
end
local function tname(tr) local _, n = reaper.GetTrackName(tr); return n end
local function fxname(tr, i)
  local _, n = reaper.TrackFX_GetFXName(tr, i, "")
  return (n:gsub("^%w+: ", ""):gsub(" %(.-%)$", ""))
end

local function describe(tr)
  local parts = { string.format("Track %d", math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))), tname(tr) }
  if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") > 0 then parts[#parts + 1] = "armed" end
  if reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") > 0 then parts[#parts + 1] = "muted" end
  if reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") > 0 then parts[#parts + 1] = "soloed" end
  if reaper.IsTrackSelected(tr) then parts[#parts + 1] = "selected" end
  return table.concat(parts, ", ")
end

local function position()
  local playing = reaper.GetPlayState() & 1 == 1
  local pos = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local bars = reaper.format_timestr_pos(pos, "", 2)
  local bar, beat = bars:match("^(%-?%d+)%.(%d+)")
  return string.format("Bar %s, beat %s", bar or "?", beat or "?")
end

local function undoable(label, fn)
  reaper.Undo_BeginBlock()
  local r = fn()
  reaper.Undo_EndBlock("Talking Piano: " .. label, -1)
  reaper.UpdateArrange()
  return r
end

local function matches(name, words)
  local low = name:lower()
  for _, w in ipairs(words) do if not low:find(w, 1, true) then return false end end
  return true
end

local function words(q)
  local t = {}
  for w in q:lower():gmatch("%S+") do t[#t + 1] = w end
  return t
end

local C = {}

C.ping = function() return "ok " .. reaper.GetAppVersion() end

C.play = function()
  reaper.Main_OnCommand(40044, 0)
  return (reaper.GetPlayState() & 1 == 1) and "Playing" or "Stopped"
end
C.stop = function() reaper.Main_OnCommand(1016, 0); return "Stopped. " .. position() end
C.record = function()
  local armed = 0
  for i = 0, reaper.CountTracks(0) - 1 do
    if reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_RECARM") > 0 then armed = armed + 1 end
  end
  if reaper.GetPlayState() & 4 == 4 then reaper.Main_OnCommand(1016, 0); return "Recording stopped" end
  if armed == 0 then return "No track is armed. Arm a track first, in the tracks list." end
  reaper.Main_OnCommand(1013, 0)
  return string.format("Recording on %d track%s", armed, armed == 1 and "" or "s")
end
C.start = function() reaper.Main_OnCommand(40042, 0); return "At the start" end
C.position = function() return position() end
C.metronome = function()
  reaper.Main_OnCommand(40364, 0)
  return "Metronome " .. (reaper.GetToggleCommandState(40364) == 1 and "on" or "off")
end
C["repeat"] = function()
  reaper.Main_OnCommand(1068, 0)
  return "Repeat " .. (reaper.GetSetRepeat(-1) == 1 and "on" or "off")
end
C.undo = function()
  local what = reaper.Undo_CanUndo2(0)
  if not what then return "Nothing to undo" end
  reaper.Main_OnCommand(40029, 0)
  return "Undid: " .. what:gsub("^Talking Piano: ", "")
end
C.redo = function()
  local what = reaper.Undo_CanRedo2(0)
  if not what then return "Nothing to redo" end
  reaper.Main_OnCommand(40030, 0)
  return "Redid: " .. what:gsub("^Talking Piano: ", "")
end
C.save = function()
  local _, path = reaper.EnumProjects(-1)
  if path == "" then return "This project has never been saved. Save it once from REAPER with Command S, to give it a name and a place." end
  reaper.Main_OnCommand(40026, 0)
  return "Saved"
end
C.tempo = function(a)
  local bpm = reaper.Master_GetTempo()
  if a[3] == "set" then bpm = tonumber(a[4]) or bpm elseif a[3] then bpm = bpm + (tonumber(a[3]) or 0) end
  bpm = math.max(20, math.min(400, bpm))
  if a[3] then reaper.SetCurrentBPM(0, bpm, true) end
  return string.format("Tempo %.0f", bpm)
end
C.info = function()
  local n = reaper.CountTracks(0)
  local _, path = reaper.EnumProjects(-1)
  local name = path:match("([^/]+)%.[Rr][Pp][Pp]$") or "an unsaved project"
  return string.format("%s. %d track%s, tempo %.0f, %.0f seconds long.", name, n, n == 1 and "" or "s", reaper.Master_GetTempo(), reaper.GetProjectLength(0))
end

C.tracks = function()
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do out[#out + 1] = describe(reaper.GetTrack(0, i)) end
  return table.concat(out, "\n")
end
C.track_select = function(a)
  local tr = track(a[3]); if not tr then return "No such track" end
  reaper.SetOnlyTrackSelected(tr)
  return describe(tr)
end
local function toggle(key, on, off)
  return function(a)
    local tr = track(a[3]); if not tr then return "No such track" end
    return undoable(on, function()
      local v = reaper.GetMediaTrackInfo_Value(tr, key) > 0 and 0 or 1
      reaper.SetMediaTrackInfo_Value(tr, key, v)
      return tname(tr) .. " " .. (v == 1 and on or off)
    end)
  end
end
C.track_arm = toggle("I_RECARM", "armed", "not armed")
C.track_mute = toggle("B_MUTE", "muted", "unmuted")
C.track_solo = toggle("I_SOLO", "soloed", "not soloed")
C.track_vol = function(a)
  local tr = track(a[3]); if not tr then return "No such track" end
  return undoable("volume", function()
    local v = reaper.GetMediaTrackInfo_Value(tr, "D_VOL") * 10 ^ ((tonumber(a[4]) or 0) / 20)
    v = math.max(0.001, math.min(4, v))
    reaper.SetMediaTrackInfo_Value(tr, "D_VOL", v)
    return tname(tr) .. ", " .. db(v)
  end)
end
C.track_pan = function(a)
  local tr = track(a[3]); if not tr then return "No such track" end
  return undoable("pan", function()
    local p = math.max(-1, math.min(1, reaper.GetMediaTrackInfo_Value(tr, "D_PAN") + (tonumber(a[4]) or 0)))
    reaper.SetMediaTrackInfo_Value(tr, "D_PAN", p)
    if math.abs(p) < 0.005 then return tname(tr) .. ", centre" end
    return string.format("%s, %.0f percent %s", tname(tr), math.abs(p) * 100, p < 0 and "left" or "right")
  end)
end
C.track_rename = function(a)
  local tr = track(a[3]); if not tr then return "No such track" end
  return undoable("rename track", function()
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", a[4] or "", true)
    return "Renamed to " .. (a[4] or "")
  end)
end
C.track_delete = function(a)
  local tr = track(a[3]); if not tr then return "No such track" end
  return undoable("delete track", function()
    local n = tname(tr)
    reaper.DeleteTrack(tr)
    return "Deleted " .. n .. ". Undo brings it back."
  end)
end
C.track_new = function(a)
  return undoable("new track", function()
    local kind, name, fx = a[3], a[4] or "", a[5] or ""
    local idx = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(idx, true)
    local tr = reaper.GetTrack(0, idx)
    local said = ""
    if fx ~= "" then
      local f = reaper.TrackFX_AddByName(tr, fx, false, -1)
      said = f >= 0 and (", with " .. fxname(tr, f)) or ", but I could not load " .. fx
    end
    if kind == "instrument" then
      -- Listen to every MIDI input on every channel, and let it be heard while playing.
      reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 4096 | (63 << 5))
      reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
    end
    if name ~= "" then reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true) end
    -- Arm only the new track, so recording goes where expected.
    for i = 0, reaper.CountTracks(0) - 1 do reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_RECARM", 0) end
    reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
    reaper.SetOnlyTrackSelected(tr)
    reaper.TrackList_AdjustWindows(false)
    return string.format("New %s track, number %d%s%s. It is armed and selected.", kind == "instrument" and "instrument" or "audio", idx + 1, name ~= "" and (", " .. name) or "", said)
  end)
end

C.fx_list = function(a)
  local tr = anytrack(a[3]); if not tr then return "" end
  local out = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    out[#out + 1] = fxname(tr, i) .. (reaper.TrackFX_GetEnabled(tr, i) and "" or ", bypassed")
  end
  return table.concat(out, "\n")
end
C.fx_add = function(a)
  local tr = anytrack(a[3]); if not tr then return "No such track" end
  return undoable("add effect", function()
    local f = reaper.TrackFX_AddByName(tr, a[4] or "", false, -1)
    if f < 0 then return "I could not find " .. (a[4] or "that") end
    return "Added " .. fxname(tr, f) .. " to " .. tname(tr)
  end)
end
C.fx_remove = function(a)
  local tr = anytrack(a[3]); if not tr then return "No such track" end
  local i = math.floor(tonumber(a[4]) or 0) - 1
  if i < 0 or i >= reaper.TrackFX_GetCount(tr) then return "No such effect" end
  return undoable("remove effect", function()
    local n = fxname(tr, i)
    reaper.TrackFX_Delete(tr, i)
    return "Removed " .. n
  end)
end
C.fx_bypass = function(a)
  local tr = anytrack(a[3]); if not tr then return "No such track" end
  local i = math.floor(tonumber(a[4]) or 0) - 1
  if i < 0 or i >= reaper.TrackFX_GetCount(tr) then return "No such effect" end
  return undoable("bypass effect", function()
    local on = not reaper.TrackFX_GetEnabled(tr, i)
    reaper.TrackFX_SetEnabled(tr, i, on)
    return fxname(tr, i) .. (on and " on" or " bypassed")
  end)
end
-- Installed plug-ins whose names contain every word of the query. "instrument" limits to instruments.
C.fx_search = function(a)
  local w, only, out, i = words(a[3] or ""), a[4] == "instrument", {}, 0
  while #out < 40 do
    local ok, name = reaper.EnumInstalledFX(i)
    if not ok then break end
    local isInst = name:match("^%w+i: ") ~= nil
    if (not only or isInst) and matches(name, w) then out[#out + 1] = name end
    i = i + 1
  end
  return table.concat(out, "\n")
end

C.marker_add = function()
  local pos = (reaper.GetPlayState() & 1 == 1) and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local n = reaper.AddProjectMarker(0, false, pos, 0, "", -1)
  return string.format("Marker %d at %s", n, position():lower())
end
C.marker_next = function() reaper.Main_OnCommand(40173, 0); return position() end
C.marker_prev = function() reaper.Main_OnCommand(40172, 0); return position() end

-- Every action REAPER has, by words in its name.
C.action_search = function(a)
  local w, out, i = words(a[3] or ""), {}, 0
  local section = reaper.SectionFromUniqueID(0)
  while #out < 40 do
    local id, name = reaper.kbd_enumerateActions(section, i)
    if not id or id == 0 then break end
    if name and matches(name, w) then out[#out + 1] = id .. "|" .. name end
    i = i + 1
  end
  return table.concat(out, "\n")
end
C.action = function(a)
  local id = math.floor(tonumber(a[3]) or 0)
  if id == 0 then return "No such action" end
  reaper.Main_OnCommand(id, 0)
  local state = reaper.GetToggleCommandState(id)
  return "Done" .. (state == 1 and ", now on" or (state == 0 and ", now off" or ""))
end


-- ---------------------------------------------------------------------------------------
-- Commands for the DAW assistant. These report facts in a fixed format so that the tool
-- can check, after every change, that REAPER really is in the state it asked for.


local function dbnum(v) if v < 0.0000001 then return -150 end return 20 * math.log(v, 10) end

local function line(tr, idx)
  local fx, on = {}, {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    fx[#fx + 1] = fxname(tr, i):gsub("[|;]", " ")
    on[#on + 1] = reaper.TrackFX_GetEnabled(tr, i) and "1" or "0"
  end
  local sends = {}
  for i = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
    local dest = reaper.GetTrackSendInfo_Value(tr, 0, i, "P_DESTTRACK")
    local vol = reaper.GetTrackSendInfo_Value(tr, 0, i, "D_VOL")
    sends[#sends + 1] = string.format("%s@%.1f", (tname(dest):gsub("[|;@]", " ")), dbnum(vol))
  end
  local items = reaper.CountTrackMediaItems(tr)
  return table.concat({ idx, (tname(tr):gsub("|", " ")), string.format("%.1f", dbnum(reaper.GetMediaTrackInfo_Value(tr, "D_VOL"))),
    string.format("%.0f", reaper.GetMediaTrackInfo_Value(tr, "D_PAN") * 100),
    reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") > 0 and 1 or 0, reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") > 0 and 1 or 0,
    reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") > 0 and 1 or 0, (idx ~= 0 and reaper.IsTrackSelected(tr)) and 1 or 0,
    table.concat(fx, ";"), table.concat(on, ";"), table.concat(sends, ";"), items,
    reaper.GetMediaTrackInfo_Value(tr, "B_MAINSEND") > 0 and 1 or 0 }, "|")
end

-- The whole project in one answer: the master first, then every track.
C.snapshot = function()
  local out = { line(reaper.GetMasterTrack(0), 0) }
  for i = 0, reaper.CountTracks(0) - 1 do out[#out + 1] = line(reaper.GetTrack(0, i), i + 1) end
  local state = reaper.GetPlayState()
  out[#out + 1] = string.format("P|%s|%s|%.1f|%.1f", (state & 4 == 4) and "recording" or ((state & 1 == 1) and "playing" or "stopped"), position(), reaper.Master_GetTempo(), reaper.GetProjectLength(0))
  return table.concat(out, "\n")
end

C.track_set = function(a)
  local tr = anytrack(a[3]); if not tr then return "No such track" end
  local key = ({ mute = "B_MUTE", solo = "I_SOLO", arm = "I_RECARM" })[a[4] or ""]
  if not key then return "unknown setting" end
  return undoable(a[4] .. " " .. tname(tr), function() reaper.SetMediaTrackInfo_Value(tr, key, tonumber(a[5]) or 0); return "ok" end)
end
C.track_vol_set = function(a)
  local tr = anytrack(a[3]); if not tr then return "No such track" end
  local dbv = math.max(-90, math.min(12, tonumber(a[4]) or 0))
  return undoable("volume of " .. tname(tr), function() reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 10 ^ (dbv / 20)); return "ok" end)
end
C.track_pan_set = function(a)
  local tr = anytrack(a[3]); if not tr then return "No such track" end
  return undoable("pan of " .. tname(tr), function() reaper.SetMediaTrackInfo_Value(tr, "D_PAN", math.max(-1, math.min(1, (tonumber(a[4]) or 0) / 100))); return "ok" end)
end
C.select = function(a)
  local tr = track(a[3]); if not tr then return "No such track" end
  reaper.SetOnlyTrackSelected(tr)
  reaper.SetMixerScroll(tr)
  reaper.Main_OnCommand(40913, 0)   -- scroll the track into view
  return "ok"
end
C.track_duplicate = function(a)
  local tr = track(a[3]); if not tr then return "No such track" end
  return undoable("duplicate " .. tname(tr), function()
    reaper.SetOnlyTrackSelected(tr)
    reaper.Main_OnCommand(40062, 0)
    local copy = reaper.GetTrack(0, math.floor(tonumber(a[3])))
    if copy and a[4] and a[4] ~= "" then reaper.GetSetMediaTrackInfo_String(copy, "P_NAME", a[4], true) end
    return "ok"
  end)
end
C.track_move = function(a)
  local tr = track(a[3]); if not tr then return "No such track" end
  local before = math.floor(tonumber(a[4]) or 0)   -- the track ends up before this position (0-based)
  return undoable("move " .. tname(tr), function()
    reaper.SetOnlyTrackSelected(tr)
    return reaper.ReorderSelectedTracks(before, 0) and "ok" or "could not move"
  end)
end
C.send_create = function(a)
  local src, dst = track(a[3]), track(a[4]); if not src or not dst then return "No such track" end
  return undoable("send from " .. tname(src) .. " to " .. tname(dst), function()
    local i = reaper.CreateTrackSend(src, dst)
    if i < 0 then return "could not create the send" end
    reaper.SetTrackSendInfo_Value(src, 0, i, "D_VOL", 10 ^ ((tonumber(a[5]) or -12) / 20))
    return "ok"
  end)
end
C.send_level = function(a)
  local src = track(a[3]); if not src then return "No such track" end
  local i = math.floor(tonumber(a[4]) or 1) - 1
  if i < 0 or i >= reaper.GetTrackNumSends(src, 0) then return "No such send" end
  return undoable("send level", function() reaper.SetTrackSendInfo_Value(src, 0, i, "D_VOL", 10 ^ ((tonumber(a[5]) or -12) / 20)); return "ok" end)
end
C.all_off = function(a)
  local key = ({ mute = "B_MUTE", solo = "I_SOLO", arm = "I_RECARM" })[a[3] or ""]
  if not key then return "unknown setting" end
  return undoable("all " .. a[3] .. " off", function()
    for i = 0, reaper.CountTracks(0) - 1 do reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), key, 0) end
    return "ok"
  end)
end

-- Every parameter of one plug-in: index, name, value as the plug-in shows it, and position from 0 to 1.
C.fx_params = function(a)
  local tr = anytrack(a[3]); if not tr then return "" end
  local f = math.floor(tonumber(a[4]) or 0) - 1
  if f < 0 or f >= reaper.TrackFX_GetCount(tr) then return "" end
  local out = {}
  for p = 0, math.min(reaper.TrackFX_GetNumParams(tr, f), 80) - 1 do
    local _, name = reaper.TrackFX_GetParamName(tr, f, p, "")
    local _, shown = reaper.TrackFX_GetFormattedParamValue(tr, f, p, "")
    out[#out + 1] = string.format("%d|%s|%s|%.4f", p + 1, (name:gsub("|", " ")), (shown:gsub("|", " ")), reaper.TrackFX_GetParamNormalized(tr, f, p))
  end
  return table.concat(out, "\n")
end
C.fx_param_set = function(a)
  local tr = anytrack(a[3]); if not tr then return "No such track" end
  local f, p = math.floor(tonumber(a[4]) or 0) - 1, math.floor(tonumber(a[5]) or 0) - 1
  if f < 0 or f >= reaper.TrackFX_GetCount(tr) or p < 0 or p >= reaper.TrackFX_GetNumParams(tr, f) then return "No such parameter" end
  return undoable("change " .. fxname(tr, f), function()
    reaper.TrackFX_SetParamNormalized(tr, f, p, math.max(0, math.min(1, tonumber(a[6]) or 0)))
    return "ok"
  end)
end
-- Moves a parameter until the plug-in itself shows the wanted number, by halving the gap.
C.fx_param_to = function(a)
  local tr = anytrack(a[3]); if not tr then return "No such track" end
  local f, p, want = math.floor(tonumber(a[4]) or 0) - 1, math.floor(tonumber(a[5]) or 0) - 1, tonumber(a[6])
  if not want or f < 0 or f >= reaper.TrackFX_GetCount(tr) or p < 0 or p >= reaper.TrackFX_GetNumParams(tr, f) then return "No such parameter" end
  local function shown(v)
    local ok, text = reaper.TrackFX_FormatParamValueNormalized(tr, f, p, v, "")
    if not ok or not text then return nil end
    if text:lower():find("inf") then return text:find("%-") and -150 or 1000000 end
    return tonumber((text:match("%-?%d+%.?%d*")))
  end
  local lo, hi = shown(0), shown(1)
  if not lo or not hi or lo == hi then return "This plug-in does not show that setting as a number I can aim at" end
  local rising = hi > lo
  if (rising and (want < lo or want > hi)) or (not rising and (want > lo or want < hi)) then
    return string.format("out of range: it goes from %s to %s", lo, hi)
  end
  local a0, b0 = 0.0, 1.0
  for _ = 1, 30 do
    local mid = (a0 + b0) / 2
    local v = shown(mid)
    if not v then break end
    if (v < want) == rising then a0 = mid else b0 = mid end
  end
  return undoable("change " .. fxname(tr, f), function() reaper.TrackFX_SetParamNormalized(tr, f, p, (a0 + b0) / 2); return "ok" end)
end
-- Presets: the current one and how many there are; or choose by name, "next" or "previous".
C.fx_preset = function(a)
  local tr = anytrack(a[3]); if not tr then return "No such track" end
  local f = math.floor(tonumber(a[4]) or 0) - 1
  if f < 0 or f >= reaper.TrackFX_GetCount(tr) then return "No such effect" end
  local want = a[5] or ""
  if want ~= "" then
    reaper.Undo_BeginBlock()
    if want == "next" then reaper.TrackFX_NavigatePresets(tr, f, 1)
    elseif want == "previous" then reaper.TrackFX_NavigatePresets(tr, f, -1)
    else reaper.TrackFX_SetPreset(tr, f, want) end
    reaper.Undo_EndBlock("Talking Piano: preset on " .. fxname(tr, f), -1)
  end
  local _, name = reaper.TrackFX_GetPreset(tr, f, "")
  local _, count = reaper.TrackFX_GetPresetIndex(tr, f)
  return (name or "") .. "|" .. tostring(count or 0)
end
-- The level a track is putting out right now, in decibels. Only meaningful while playing.
C.peak = function(a)
  local tr = anytrack(a[3] or "master"); if not tr then return "No such track" end
  local l, r = reaper.Track_GetPeakInfo(tr, 0), reaper.Track_GetPeakInfo(tr, 1)
  return string.format("%.1f", dbnum(math.max(l, r)))
end

local function loop()
  local f = io.open(cmdPath, "r")
  if f then
    local s = f:read("a")
    f:close()
    os.remove(cmdPath)
    local a = split((s:gsub("[\r\n]+$", "")))
    local fn = C[a[2] or ""]
    local ok, res = pcall(function() if fn then return fn(a) end return "unknown command" end)
    local out = io.open(replyPath .. ".tmp", "w")
    if out then
      out:write((a[1] or "") .. "\t" .. (ok and tostring(res) or ("error: " .. tostring(res))))
      out:close()
      os.rename(replyPath .. ".tmp", replyPath)
    end
  end
  reaper.defer(loop)
end

loop()
