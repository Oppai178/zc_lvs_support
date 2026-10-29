-- [Z-CITY] LVS SUPPORT
-- Session console log for post-session debugging (Oppai 09.10):
-- GMod can log the console with con_logfile, but that floods the disk
-- with everything. Instead: a ring buffer of our own debug lines plus
-- raw server console via con_log, dumped on command.
--
-- USAGE (Oppai): after a play session say "иди читай" — the analyst
-- reads zc_lvs_session.txt from the data folder.
--   zc_lvs_dump       — write the session log now
--   zc_lvs_tail 40    — show last 40 lines in console
--   zc_lvs_clear      — wipe the buffer (start of a session)
-- The file lands in garrysmod/data/zc_lvs_session.txt on the SERVER
-- (listen host = your machine, single player = your machine too).

ZC_LVS = ZC_LVS or {}

local MAX_LINES = 5000
local buf = {}
local bufN = 0

local function push(line)
	bufN = bufN + 1
	if bufN > MAX_LINES then
		table.remove(buf, 1)
		bufN = MAX_LINES
	end
	buf[bufN] = line
end

-- Capture our own debug prints (client + server on a listen host).
local oldPrint = print
if SERVER then
	_G.print = function(...)
		local n = select("#", ...)
		if n > 0 then
			local parts = {}
			for i = 1, n do
				parts[#parts + 1] = tostring(select(i, ...))
			end
			push(os.date("%H:%M:%S") .. " " .. table.concat(parts, "\t"))
		end
		return oldPrint(...)
	end
end


concommand.Add("zc_lvs_dump", function(ply)
	if IsValid(ply) and not ply:IsListenServerHost() and not ply:IsSuperAdmin() then return end
	if not SERVER then return end
	file.CreateDir("zc_lvs")
	local path = "zc_lvs/session.txt"
	file.Write(path, table.concat(buf, "\n"))
	local size = file.Size(path, "DATA")
	print(("[zc_lvs] session log written: %s (%d lines, %d bytes) — data/zc_lvs/session.txt")
		:format(path, bufN, size or 0))
end)

concommand.Add("zc_lvs_tail", function(ply, _, args)
	if IsValid(ply) and not ply:IsListenServerHost() and not ply:IsSuperAdmin() then return end
	if not SERVER then return end
	local n = math.Clamp(tonumber(args[1]) or 40, 1, 500)
	for i = math.max(1, bufN - n + 1), bufN do
		print(buf[i])
	end
end)

concommand.Add("zc_lvs_clear", function(ply)
	if IsValid(ply) and not ply:IsListenServerHost() and not ply:IsSuperAdmin() then return end
	if not SERVER then return end
	buf = {}
	bufN = 0
	print("[zc_lvs] session buffer cleared")
end)

-- AUTOMATIC (Oppai 09.10 "не хочу каждый раз писать команды"):
-- write the log when the server shuts down (you close GMod / disconnect
-- from your listen server) and rotate it per session: session_1.txt,
-- session_2.txt ... newest is always the largest number. Buffer also
-- auto-clears on map change so one file = one play session.
local sessionIndex = 0
local function writeSession(reason)
	if not SERVER then return end
	if bufN == 0 then return end
	file.CreateDir("zc_lvs")
	-- find the next free index
	local i = 1
	while file.Exists("zc_lvs/session_" .. i .. ".txt", "DATA") do
		i = i + 1
	end
	local path = "zc_lvs/session_" .. i .. ".txt"
	file.Write(path, "-- session " .. os.date("%Y-%m-%d %H:%M") .. " (" .. reason .. ")
" .. table.concat(buf, "
"))
	print(("[zc_lvs] auto-dumped session to %s (%d lines)"):format(path, bufN))
	return i
end

hook.Add("ShutDown", "zc_lvs_auto_dump", function()
	writeSession("shutdown")
end)

-- Listen-host disconnect: the game keeps running, but the play session
-- is over — dump then too.
hook.Add("PlayerDisconnected", "zc_lvs_auto_dump_dc", function(ply)
	if IsValid(ply) and ply:IsListenServerHost() then
		timer.Simple(1, function()
			writeSession("listen host left")
		end)
	end
end)

hook.Add("PostCleanupMap", "zc_lvs_session_reset", function()
	buf = {}
	bufN = 0
end)

-- EVENT-TRIGGERED SNAPSHOTS (Oppai 09.10): ShutDown is NOT reliable in
-- single-player (engine may skip it on window close) — the first real
-- session lost its log that way. Write the buffer at the MOMENT of the
-- events we care about, overwriting one live file per event type:
--   zc_lvs/live_death.txt   — every player death (the "разорвало" hunt)
--   zc_lvs/live_crash.txt   — our crash-damage spike
--   zc_lvs/live_error.txt   — any lua error line captured
-- These persist immediately; even a hard crash keeps them.
local function snapshot(name, tag)
	if not SERVER or bufN == 0 then return end
	file.CreateDir("zc_lvs")
	file.Append("zc_lvs/live_" .. name .. ".txt",
		"== " .. os.date("%Y-%m-%d %H:%M:%S") .. " " .. tag .. " ==
"
		.. table.concat(buf, "
", math.max(1, bufN - 300)) .. "

")
end

hook.Add("PlayerDeath", "zc_lvs_snap_death", function(victim, infl, atk)
	timer.Simple(0.1, function()
		snapshot("death", "player died: " .. (IsValid(victim) and victim:Nick() or "?"))
	end)
end)

hook.Add("EntityTakeDamage", "zc_lvs_snap_crash", function(ent, dmginfo)
	if not IsValid(ent) then return end
	local d = dmginfo:GetDamage()
	if d < 25 then return end
	local isFakeOrPly = ent:IsPlayer() or ent:GetClass() == "prop_ragdoll"
	if not isFakeOrPly then return end
	timer.Simple(0.05, function()
		snapshot("crash", "damage " .. math.floor(d) .. " type 0x" .. string.format("%x", dmginfo:GetDamageType()))
	end)
end)

-- Rotate the numbered session files but ALSO always refresh a live.txt
-- mirror every 30s: even without any death/crash/shutdown, the last 30
-- seconds are always on disk.
timer.Create("zc_lvs_live_mirror", 30, 0, function()
	if not SERVER or bufN == 0 then return end
	file.CreateDir("zc_lvs")
	file.Write("zc_lvs/live_mirror.txt", table.concat(buf, "
"))
end)

hook.Add("Initialize", "zc_lvs_dump_hello", function()
	if SERVER then
		print("[zc_lvs] session logger active: auto-dumps on shutdown to data/zc_lvs/session_N.txt (manual: zc_lvs_dump/tail/clear)")
	end
end)
