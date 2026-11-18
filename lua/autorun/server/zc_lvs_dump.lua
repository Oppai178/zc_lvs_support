-- [Z-CITY] LVS SUPPORT
-- Author: Oppai
--
-- Session console log for post-session debugging.
-- A ring buffer of our own console lines, dumped to data/zc_lvs/.
--
-- USAGE: after a play session say "иди читай" — the analyst reads
-- data/zc_lvs/session_N.txt.
--   zc_lvs_dump       — write the session log now
--   zc_lvs_tail 40    — show last 40 lines in console
--   zc_lvs_clear      — wipe the buffer (start of a session)
--
-- NOTE (fix): the previous version had RAW NEWLINES inside "..." string
-- literals (8 of them). Lua rejects that with "unfinished string", so the
-- whole file never loaded and no log was ever written. Every literal
-- below uses \n escapes.

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

-- Capture console output (listen host: client + server share the process).
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

local function canUse(ply)
	if not SERVER then return false end
	if not IsValid(ply) then return true end
	if ply:IsListenServerHost() then return true end
	if isfunction(ply.IsSuperAdmin) and ply:IsSuperAdmin() then return true end
	return false
end

concommand.Add("zc_lvs_dump", function(ply)
	if not canUse(ply) then return end
	file.CreateDir("zc_lvs")
	local path = "zc_lvs/session.txt"
	file.Write(path, table.concat(buf, "\n"))
	local size = file.Size(path, "DATA")
	print(("[zc_lvs] session log written: %s (%d lines, %d bytes) — data/zc_lvs/session.txt")
		:format(path, bufN, size or 0))
end)

concommand.Add("zc_lvs_tail", function(ply, _, args)
	if not canUse(ply) then return end
	local n = math.Clamp(tonumber(args and args[1]) or 40, 1, 500)
	for i = math.max(1, bufN - n + 1), bufN do
		print(buf[i])
	end
end)

concommand.Add("zc_lvs_clear", function(ply)
	if not canUse(ply) then return end
	buf = {}
	bufN = 0
	print("[zc_lvs] session buffer cleared")
end)

-- Automatic dumps: on shutdown / listen-host disconnect, plus rotating
-- numbered files. The buffer also clears on map change so one file = one
-- play session.
local function writeSession(reason)
	if not SERVER then return end
	if bufN == 0 then return end
	file.CreateDir("zc_lvs")
	local i = 1
	while file.Exists("zc_lvs/session_" .. i .. ".txt", "DATA") do
		i = i + 1
	end
	local path = "zc_lvs/session_" .. i .. ".txt"
	local header = "-- session " .. os.date("%Y-%m-%d %H:%M") .. " (" .. reason .. ")\n"
	file.Write(path, header .. table.concat(buf, "\n"))
	print(("[zc_lvs] auto-dumped session to %s (%d lines)"):format(path, bufN))
	return i
end

hook.Add("ShutDown", "zc_lvs_auto_dump", function()
	writeSession("shutdown")
end)

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

-- Event-triggered snapshots: ShutDown is not reliable in single-player,
-- so write the buffer at the moment of the events we care about.
--   zc_lvs/live_death.txt   — every player death (the "разорвало" hunt)
--   zc_lvs/live_crash.txt   — our crash-damage spike
local function snapshot(name, tag)
	if not SERVER or bufN == 0 then return end
	file.CreateDir("zc_lvs")
	local head = "== " .. os.date("%Y-%m-%d %H:%M:%S") .. " " .. tag .. " ==\n"
	local body = table.concat(buf, "\n", math.max(1, bufN - 300))
	file.Append("zc_lvs/live_" .. name .. ".txt", head .. body .. "\n\n")
end

hook.Add("PlayerDeath", "zc_lvs_snap_death", function(victim)
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

-- Live mirror every 30s: even without any death/crash/shutdown the last
-- 30 seconds are always on disk.
timer.Create("zc_lvs_live_mirror", 30, 0, function()
	if not SERVER or bufN == 0 then return end
	file.CreateDir("zc_lvs")
	file.Write("zc_lvs/live_mirror.txt", table.concat(buf, "\n"))
end)

hook.Add("Initialize", "zc_lvs_dump_hello", function()
	if SERVER then
		print("[zc_lvs] session logger active: auto-dumps on shutdown to data/zc_lvs/session_N.txt (manual: zc_lvs_dump/tail/clear)")
	end
end)
