--[[
	[Z-CITY] LVS SUPPORT
	Author: Oppai
	Compatibility layer: LVS vehicles use Z-City fake/organism/TPIK.
	Does not replace Glide. Does not patch Z-City files.
]]

ZC_LVS = ZC_LVS or {}
ZC_LVS.Version = "4.1.0"

if SERVER then
	AddCSLuaFile("zc_lvs_support/sh_core.lua")
	AddCSLuaFile("zc_lvs_support/sh_binds.lua")
	AddCSLuaFile("zc_lvs_support/cl_camera.lua")
	AddCSLuaFile("zc_lvs_support/cl_tpik.lua")
	AddCSLuaFile("zc_lvs_support/cl_binds.lua")
	AddCSLuaFile("zc_lvs_support/cl_cargo.lua")
	AddCSLuaFile("zc_lvs_support/cl_forceseat.lua")
end

local filesShared = {
	"zc_lvs_support/sh_core.lua",
	"zc_lvs_support/sh_binds.lua",
}

local filesServer = {
	"zc_lvs_support/sv_seats.lua",
	"zc_lvs_support/sv_organism.lua",
	"zc_lvs_support/sv_he.lua",
	"zc_lvs_support/sv_interior.lua",
	"zc_lvs_support/sv_cargo.lua",
	"zc_lvs_support/sv_forceseat.lua",
}

local filesClient = {
	"zc_lvs_support/cl_camera.lua",
	"zc_lvs_support/cl_tpik.lua",
	"zc_lvs_support/cl_binds.lua",
	"zc_lvs_support/cl_cargo.lua",
	"zc_lvs_support/cl_forceseat.lua",
}

local function includeList(list)
	for i = 1, #list do
		local path = list[i]
		local ok, err = pcall(include, path)
		if not ok then
			ErrorNoHalt(string.format("[Z-CITY LVS SUPPORT] failed to include %s: %s\n", path, tostring(err)))
			return false, path, err
		end
	end
	return true
end

function ZC_LVS.Load()
	-- A version string avoids old boolean state skipping files after a refresh.
	if ZC_LVS._loaded == ZC_LVS.Version then return true end
	if ZC_LVS._loading then return false end

	local missing = {}
	if not LVS then missing[#missing + 1] = "LVS" end
	if not hg then missing[#missing + 1] = "hg" end
	if #missing > 0 then
		local reason = table.concat(missing, ", ")
		if ZC_LVS._lastLoadState ~= reason then
			print("[Z-CITY LVS SUPPORT] waiting for: " .. reason)
			ZC_LVS._lastLoadState = reason
		end
		return false
	end

	ZC_LVS._loading = true
	ZC_LVS._wrappedSetPos = nil
	ZC_LVS._wrappedRemoveDead = nil

	local ok, path, err = includeList(filesShared)

	if ok and SERVER then
		ok, path, err = includeList(filesServer)
	end

	if ok and CLIENT then
		ok, path, err = includeList(filesClient)
	end
	ZC_LVS._loading = nil

	if not ok then
		ZC_LVS._lastLoadState = "include:" .. tostring(path)
		return false
	end

	ZC_LVS._loaded = ZC_LVS.Version
	ZC_LVS._lastLoadState = "loaded"
	print("[Z-CITY LVS SUPPORT] loaded v" .. ZC_LVS.Version .. " by Oppai")
	return true
end

-- One-shot state snapshot of a player's LVS seat. Works even while the
-- compatibility layer is still waiting for LVS/hg, so a broken load is
-- diagnosable too. SERVER prints everyone; CLIENT prints the local player.
local function seatSnapshot(ply)
	local lines = {}
	local function add(fmt, ...)
		lines[#lines + 1] = string.format("  %s", string.format(fmt, ...))
	end

	add("version=%s loaded=%s", tostring(ZC_LVS.Version), tostring(ZC_LVS._loaded))

	if not IsValid(ply) then
		lines[#lines + 1] = "  (invalid player)"
		return lines
	end
	if not ply.InVehicle or not ply:InVehicle() then
		add("%s: not in a vehicle", tostring(ply))
		return lines
	end

	local pod = ply:GetVehicle()
	local veh = ZC_LVS.GetVehicle and ZC_LVS.GetVehicle(ply) or NULL
	add("%s pod=%s veh=%s", tostring(ply), pod:GetClass(), IsValid(veh) and veh:GetClass() or "none")

	if not ZC_LVS.GetChassis then
		lines[#lines + 1] = "  (core not loaded: waiting for LVS/hg)"
		return lines
	end

	local chassis = ZC_LVS.GetChassis(pod)
	add("chassis=%s type=%s", IsValid(chassis) and chassis:GetClass() or "none", ZC_LVS.GetType(veh))

	local function flag(name, fn)
		local ok, res = pcall(fn)
		add("%-22s %s", name, ok and tostring(res) or ("error: " .. tostring(res)))
	end

	flag("CameraMode", function() return ZC_LVS.CameraMode(ply) end)
	flag("PodRole", function() return ZC_LVS.PodRole(ply, pod, veh) end)
	flag("IsTurretSeat", function() return ZC_LVS.IsTurretSeat(ply) end)
	flag("IsRoofSeat", function() return ZC_LVS.IsRoofSeat(pod, veh) end)
	flag("IsHatchSeat", function() return ZC_LVS.IsHatchSeat(ply, pod, veh) end)
	flag("IsOpenCarHull", function() return ZC_LVS.IsOpenCarHull(veh) end)
	flag("IsClosedVehicle", function() return ZC_LVS.IsClosedVehicle(veh) end)
	flag("IsCar / IsAircraft", function()
		return tostring(ZC_LVS.IsCar(veh)) .. " / " .. tostring(ZC_LVS.IsAircraft(veh))
	end)
	flag("SeatPose", function() return ZC_LVS.SeatPose(ply, pod, veh) end)
	flag("ShouldStandAtWeapon", function() return ZC_LVS.ShouldStandAtWeapon(ply) end)
	flag("CanLVSAim (RMB sight)", function() return ZC_LVS.CanLVSAim(ply) end)
	flag("IsAimingLVS", function() return ZC_LVS.IsAimingLVS(ply) end)
	flag("PodHidesPlayer", function() return ZC_LVS.PodHidesPlayer(pod) end)
	flag("SeatWeaponType", function() return ZC_LVS.SeatWeaponType(pod) end)

	local third = "n/a"
	if pod.GetThirdPersonMode then
		local ok, res = pcall(pod.GetThirdPersonMode, pod)
		if ok then third = tostring(res) end
	end
	add("%-22s %s", "pod ThirdPersonMode", third)

	local weapon = "none"
	if isfunction(pod.lvsGetWeapon) then
		local ok, w = pcall(pod.lvsGetWeapon, pod)
		if ok and IsValid(w) then
			weapon = w:GetClass()
		end
	end
	add("%-22s %s", "pod lvsGetWeapon", weapon)

	local rag = "none"
	if ply.GetNWEntity then
		local r = ply:GetNWEntity("FakeRagdoll")
		if IsValid(r) then rag = r:GetClass() end
	end
	if IsValid(ply.FakeRagdoll) then rag = ply.FakeRagdoll:GetClass() end
	add("%-22s %s", "fake ragdoll", rag)

	local camPos = "n/a"
	if ZC_LVS.SeatCamPos and CLIENT then
		local ok, p = pcall(ZC_LVS.SeatCamPos, ply, pod)
		if ok and isvector(p) then camPos = string.format("(%.0f %.0f %.0f)", p.x, p.y, p.z) end
	end
	add("%-22s %s", "SeatCamPos (client)", camPos)

	return lines
end

concommand.Add("zc_lvs_debug_seats", function(ply, cmd, args)
	if SERVER and IsValid(ply) and not ply:IsAdmin() then return end

	local targets
	if SERVER then
		if #args > 0 then
			local name = string.lower(table.concat(args, " "))
			targets = {}
			for _, p in ipairs(player.GetAll()) do
				if string.find(string.lower(p:Nick()), name, 1, true) then
					targets[#targets + 1] = p
					break
				end
			end
			if #targets == 0 then
				if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[zc_lvs] player not found: " .. name) end
				return
			end
		else
			targets = player.GetAll()
		end
	else
		targets = { LocalPlayer() }
	end

	for i = 1, #targets do
		local t = targets[i]
		if not IsValid(t) then continue end
		local lines = seatSnapshot(t)
		local header = string.format("[zc_lvs] seat snapshot: %s", t:Nick())
		table.insert(lines, 1, header)
		for j = 1, #lines do
			local line = lines[j]
			print(line)
			if SERVER and IsValid(ply) then
				ply:PrintMessage(HUD_PRINTCONSOLE, line)
			end
		end
	end
end)

concommand.Add("zc_lvs_status", function(ply)
	if IsValid(ply) and SERVER and not ply:IsAdmin() then return end
	print(string.format(
		"[Z-CITY LVS SUPPORT] version=%s loaded=%s loading=%s LVS=%s hg=%s",
		tostring(ZC_LVS.Version),
		tostring(ZC_LVS._loaded),
		tostring(ZC_LVS._loading),
		tostring(LVS ~= nil),
		tostring(hg ~= nil)
	))
end)

timer.Create("zc_lvs_support_load_retry", 1, 0, function()
	if ZC_LVS._loaded ~= ZC_LVS.Version then
		ZC_LVS.Load()
	else
		timer.Remove("zc_lvs_support_load_retry")
	end
end)

hook.Add("HomigradRun", "zc_lvs_support", function()
	timer.Simple(0, ZC_LVS.Load)
end)

hook.Add("LVS:Initialize", "zc_lvs_support", function()
	timer.Simple(0, ZC_LVS.Load)
end)

hook.Add("InitPostEntity", "zc_lvs_support", function()
	timer.Simple(1, ZC_LVS.Load)
end)

timer.Simple(0, ZC_LVS.Load)




