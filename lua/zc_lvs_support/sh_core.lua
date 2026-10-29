-- [Z-CITY] LVS SUPPORT
-- Author: Oppai

ZC_LVS = ZC_LVS or {}
ZC_LVS.Author = "Oppai"

CreateConVar("zc_lvs_enabled", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Enable Z-City LVS compatibility", 0, 1)
CreateConVar("zc_lvs_fake", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Ragdoll (fake) players inside LVS vehicles", 0, 1)
CreateConVar("zc_lvs_air_fake", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Ragdoll (fake) in LVS helicopters/planes", 0, 1)
CreateConVar("zc_lvs_air_lvcam", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Use native LVS camera for helicopters/planes (opt-out; default ZC eyes). Renamed from zc_lvs_air_camera 08.10: the old archived value=1 stuck on live servers", 0, 1)
CreateConVar("zc_lvs_crash_damage", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Transfer LVS crash damage into the organism", 0, 1)
CreateConVar("zc_lvs_explode_damage", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Transfer LVS explosion damage into the organism", 0, 1)
CreateConVar("zc_lvs_crash_eject", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Legacy crash ejection (disabled; impacts damage occupants)", 0, 1)
CreateConVar("zc_lvs_pen", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Bullets pass glass/open doors into the cabin", 0, 1)
CreateConVar("zc_lvs_shrapnel", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Vehicle explosion throws a few metal fragments", 0, 1)
CreateConVar("zc_lvs_fuel_leak", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Rear/fuel hits can leak LVS fuel and catch fire", 0, 1)
CreateConVar("zc_lvs_air_fall", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Unconscious in the air can throw you out of a helicopter (OFF by default, Oppai 08.10: no ejections, damage/otrub from impacts only)", 0, 1)
CreateConVar("zc_lvs_debug", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Print ZC LVS seat and cargo diagnostics", 0, 1)
CreateConVar("zc_lvs_forceseat", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Allow putting other players into LVS seats via the radial menu (ArmA-style load)", 0, 1)

-- Per-frame tags are throttled to one line per half second: they flooded
-- the console so hard GMod truncated it (clip 05.10).
local THROTTLE_TAGS = {
	view = true,
	view_lvs = true,
	view_matrix = true,
	eye_diag = true,
}
local THROTTLE_SEC = 3
local _lastLog = {}

-- Realism rule (Oppai 06.10): Ctrl third person does not exist in play.
-- It stays available ONLY while zc_lvs_debug is on, for testing.
function ZC_LVS.DebugEnabled()
	local cv = GetConVar("zc_lvs_debug")
	return cv and cv:GetBool() or false
end

function ZC_LVS.DebugLog(tag, ...)
	local cv = GetConVar("zc_lvs_debug")
	if not cv or not cv:GetBool() then return end
	if THROTTLE_TAGS[tag] then
		local t = _lastLog[tag] or 0
		if CurTime() - t < THROTTLE_SEC then return end
		_lastLog[tag] = CurTime()
	end
	print("[zc_lvs][debug] " .. tostring(tag), ...)
end

local AIR_TYPES = {
	helicopter = true,
	plane = true,
	starfighter = true,
	repulsorlift = true,
	walker = true,
}

-- Only true aircraft. Do not include tank/gunner: those sit in cars too
-- and would steal Z-City look.
local LVS_CAMERA_TYPES = {
	helicopter = true,
	plane = true,
	starfighter = true,
	repulsorlift = true,
	walker = true,
}

local CAR_TYPES = {
	car = true,
	bike = true,
	boat = true,
	fakehover = true,
	LBaseTrailer = true,
}

function ZC_LVS.Enabled()
	return GetConVar("zc_lvs_enabled"):GetBool()
end

function ZC_LVS.IsLVS(ent)
	return IsValid(ent) and ent.LVS == true
end

function ZC_LVS.IsLVSSeat(ent)
	if not IsValid(ent) then return false end
	if ent.LVS then return true end

	if ent:GetClass() == "prop_vehicle_prisoner_pod" then
		local parent = ent:GetParent()
		if IsValid(parent) and parent.LVS then
			return true
		end
	end

	return false
end

function ZC_LVS.GetChassis(ent)
	if not IsValid(ent) then return NULL end
	if ent.LVS then return ent end

	local parent = ent:GetParent()
	if IsValid(parent) and parent.LVS then
		return parent
	end

	if isfunction(ent.lvsGetVehicle) then
		local veh = ent:lvsGetVehicle()
		if IsValid(veh) then return veh end
	end

	return NULL
end

function ZC_LVS.GetVehicle(ply)
	if not IsValid(ply) or not ply.InVehicle then return NULL end

	if ply:InVehicle() then
		local pod = ply:GetVehicle()
		-- LVS caches a failed lookup on the pod. Force a parent check.
		if IsValid(pod) then
			pod.LVSchecked = nil
		end
		local chassis = ZC_LVS.GetChassis(pod)
		if IsValid(chassis) then return chassis end
	end

	if ply.lvsGetVehicle then
		local veh = ply:lvsGetVehicle()
		if IsValid(veh) then return veh end
	end

	return NULL
end

function ZC_LVS.GetType(veh)
	if not IsValid(veh) then return "" end
	if not isfunction(veh.GetVehicleType) then return "" end
	return veh:GetVehicleType() or ""
end

function ZC_LVS.PodRole(ply, pod, veh)
	if not IsValid(pod) then return "unknown" end
	veh = veh or ZC_LVS.GetChassis(pod)
	if ZC_LVS.PodHasGunnerEnt(pod) or ZC_LVS.IsRoofSeat(pod, veh) or ZC_LVS.SeatWeaponType(pod) == "gunner" then return "gunner" end
	if IsValid(veh) and isfunction(veh.GetDriverSeat) and veh:GetDriverSeat() == pod then return "driver" end
	if IsValid(ply) and IsValid(veh) and ZC_LVS.IsDriver(ply, veh) then return "driver" end
	return "passenger"
end

-- Walk ENT.Base through scripted_ents. Packs do
--   ENT.Base = "lvs_my_uaz" в†’ "lvs_base_wheeldrive"
-- Immediate .Base is not enough.
function ZC_LVS.BaseChain(veh)
	if not IsValid(veh) then return {} end
	if veh._zc_lvs_bases then return veh._zc_lvs_bases end

	local list = {}
	local class = veh.GetClass and veh:GetClass()
	if isstring(class) and class ~= "" then
		list[#list + 1] = string.lower(class)
	end
	local b = veh.Base
	local seen = {}
	for _ = 1, 16 do
		if not isstring(b) or b == "" or seen[b] then break end
		seen[b] = true
		list[#list + 1] = string.lower(b)
		local st = scripted_ents.GetStored(b)
		if not st or not st.t then break end
		b = st.t.Base
	end
	veh._zc_lvs_bases = list
	return list
end

function ZC_LVS.Inherits(veh, names)
	if not IsValid(veh) or not istable(names) then return false end
	for _, name in ipairs(ZC_LVS.BaseChain(veh)) do
		if names[name] then return true end
	end
	return false
end

function ZC_LVS.ChainHas(veh, needle)
	if not IsValid(veh) or not isstring(needle) or needle == "" then return false end
	needle = string.lower(needle)
	for _, name in ipairs(ZC_LVS.BaseChain(veh)) do
		if name == needle or string.find(name, needle, 1, true) then
			return true
		end
	end
	return false
end

function ZC_LVS.GetFuelTank(veh)
	if not IsValid(veh) then return NULL end
	if isfunction(veh.GetFuelTank) then
		local tank = veh:GetFuelTank()
		if IsValid(tank) then return tank end
	end
	return NULL
end

-- Aircraft not sitting on the ground (skids / gear).
function ZC_LVS.IsAirborne(veh)
	if not IsValid(veh) or not ZC_LVS.IsAircraft(veh) then return false end

	local start = veh:WorldSpaceCenter()
	local tr = util.TraceHull({
		start = start,
		endpos = start - Vector(0, 0, 96),
		mins = Vector(-28, -28, -4),
		maxs = Vector(28, 28, 4),
		filter = function(hit)
			if not IsValid(hit) then return false end
			if hit == veh or hit.LVS then return false end
			if hit:GetParent() == veh then return false end
			return true
		end,
		mask = MASK_SOLID,
	})
	return not tr.Hit
end

function ZC_LVS.VehicleHasDoors(veh)
	if not IsValid(veh) or not isfunction(veh.GetDoorHandlers) then return false end
	local doors = veh:GetDoorHandlers()
	return istable(doors) and #doors > 0
end

function ZC_LVS.IsInOpenDoorway(veh, worldPos)
	if not IsValid(veh) or not worldPos or not isfunction(veh.GetDoorHandlers) then return false end
	for _, door in ipairs(veh:GetDoorHandlers()) do
		if not IsValid(door) then continue end
		if not door.IsOpen or not door:IsOpen() then continue end
		local lp = door:WorldToLocal(worldPos)
		local mins, maxs = door:GetMins(), door:GetMaxs()
		if not mins or not maxs then continue end
		local pad = 18
		if lp.x < mins.x - pad or lp.x > maxs.x + pad then continue end
		if lp.y < mins.y - pad or lp.y > maxs.y + pad then continue end
		if lp.z < mins.z - 10 or lp.z > maxs.z + 22 then continue end
		return true
	end
	return false
end

function ZC_LVS.IsAtRear(ply, veh)
	if not IsValid(ply) or not IsValid(veh) then return false end
	if not ZC_LVS.IsCar(veh) then return false end

	local lp = veh:WorldToLocal(ply:GetPos())
	local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
	if lp.x > mins.x + 36 then return false end
	if lp.y < mins.y - 28 or lp.y > maxs.y + 28 then return false end
	if lp.z < mins.z - 24 or lp.z > maxs.z + 48 then return false end

	local rear = veh:LocalToWorld(Vector(mins.x, 0, mins.z + 20))
	return ply:GetPos():DistToSqr(rear) < 110 * 110
end

local AIR_BASES = {
	lvs_base_helicopter = true,
	lvs_base_fighterplane = true,
	lvs_base_starfighter = true,
	lvs_base_repulsorlift = true,
}

local DRONE_TYPES = {
	drone = true,
}

-- FPV drones (LVS UAV packs: the pilot sits in the DRONE's driver seat --
-- sw_uav catapult Use() does EnterVehicle(UAV:GetDriverSeat()) -- while
-- the pack renders an operator model at the control station and its own
-- FPV screen). No fake, no ZC camera: the pack screen IS the vanilla
-- view. LVS keeps the airframe HP/damage.
function ZC_LVS.IsDrone(veh)
	if not IsValid(veh) then return false end
	if DRONE_TYPES[ZC_LVS.GetType(veh)] then return true end
	if veh.LVSUAV == true then return true end
	if ZC_LVS.ChainHas(veh, "drone") then return true end
	-- Packs that drive the camera from their own controller object.
	if isfunction(veh.GetCameraController) then return true end
	return false
end

local PLANE_BASES = {
	lvs_base_fighterplane = true,
	lvs_base_starfighter = true,
}

local CAR_BASES = {
	lvs_base_wheeldrive = true,
	lvs_base_wheeldrive_trailer = true,
	lvs_bike_wheeldrive = true,
	lvs_base_powerboat = true,
	lvs_base_fakehover = true,
}

local TANK_BASES = {
	lvs_tank_wheeldrive = true,
}

local TRAILER_BASES = {
	lvs_base_wheeldrive_trailer = true,
}

-- LVS stationary guns: towed emplacements (FlaK 38, Pak 40) and ground
-- stations (UAV control). The crew stands at the gun in the open air —
-- same rule as an open car, not a closed hull.
function ZC_LVS.IsStationaryGun(veh)
	if not IsValid(veh) then return false end
	if ZC_LVS.IsAircraft(veh) or ZC_LVS.IsPlane(veh) then return false end
	if ZC_LVS.GetType(veh) == "LBaseTrailer" then return true end
	if ZC_LVS.Inherits(veh, TRAILER_BASES) then return true end
	return ZC_LVS.ChainHas(veh, "wheeldrive_trailer")
end

function ZC_LVS.IsAircraft(veh)
	if not IsValid(veh) then return false end
	-- Drones are UAV pods, not crewed aircraft: no fake, no air rules.
	if ZC_LVS.IsDrone(veh) then return false end
	if AIR_TYPES[ZC_LVS.GetType(veh)] then return true end
	if ZC_LVS.Inherits(veh, AIR_BASES) then return true end
	-- Walker packs often Base = "lvs_walker_*" в†' hoverscript, type already "walker".
	if ZC_LVS.ChainHas(veh, "lvs_walker") then return true end
	return false
end

-- Fighter / starfighter. Not a helicopter: mouse is flight, gear hits
-- the runway at 400+ u/s, camera is plane attitude not EyeAngles.
function ZC_LVS.IsPlane(veh)
	if not IsValid(veh) then return false end
	if ZC_LVS.IsDrone(veh) then return false end
	local t = ZC_LVS.GetType(veh)
	if t == "plane" or t == "starfighter" then return true end
	if ZC_LVS.Inherits(veh, PLANE_BASES) then return true end
	-- Hidden-type fighters expose GetLandingGear. Wheeldrive must not:
	-- that stole ZC camera and blocked crash eject. Drones expose
	-- GetLandingGear too (catapult launch gear) — excluded above.
	if isfunction(veh.GetLandingGear)
		and not ZC_LVS.Inherits(veh, CAR_BASES)
		and not ZC_LVS.ChainHas(veh, "wheeldrive") then
		return true
	end
	return false
end

-- Intact fighter: stay in the seat. Destroyed airframe may dump you.
function ZC_LVS.PlaneKeepPilot(veh)
	if not IsValid(veh) or not ZC_LVS.IsPlane(veh) then return false end
	if isfunction(veh.IsDestroyed) and veh:IsDestroyed() then return false end
	return true
end

function ZC_LVS.PlaneGearDown(veh)
	if not IsValid(veh) or not ZC_LVS.IsPlane(veh) then return false end
	if isfunction(veh.GetLandingGear) then
		return (veh:GetLandingGear() or 0) > 0.15
	end
	return not ZC_LVS.IsAirborne(veh)
end

function ZC_LVS.IsCar(veh)
	if not IsValid(veh) then return false end
	if ZC_LVS.IsAircraft(veh) then return false end
	if ZC_LVS.IsDrone(veh) then return false end
	local t = ZC_LVS.GetType(veh)
	if t == "tank" or t == "gunner" then return false end
	if CAR_TYPES[t] then return true end
	if ZC_LVS.Inherits(veh, TANK_BASES) or ZC_LVS.ChainHas(veh, "lvs_tank") then
		return false
	end
	if ZC_LVS.Inherits(veh, CAR_BASES) then return true end
	-- Pack: ENT.Base = "lvs_my_car" в†’ вЂ¦ в†’ lvs_base_wheeldrive
	if ZC_LVS.ChainHas(veh, "wheeldrive") and not ZC_LVS.ChainHas(veh, "tank") then
		return true
	end
	-- Other packs (trucks, APCs) that never set type/base we know.
	if t ~= "gunner" and veh.LVS then
		return true
	end
	return false
end

function ZC_LVS.IsDriver(ply, veh)
	if not IsValid(ply) or not IsValid(veh) then return false end
	if isfunction(veh.GetDriver) and veh:GetDriver() == ply then
		return true
	end
	return false
end

function ZC_LVS.SeatWeaponType(pod)
	if not IsValid(pod) or not isfunction(pod.lvsGetWeapon) then return end

	local weapon = pod:lvsGetWeapon()
	if IsValid(weapon) and isfunction(weapon.GetVehicleType) then
		return weapon:GetVehicleType()
	end
end

function ZC_LVS.GetPodWeapon(pod, ply)
	if not IsValid(pod) then return NULL end

	if isfunction(pod.lvsGetWeapon) then
		local w = pod:lvsGetWeapon()
		if IsValid(w) then return w end
	end

	if IsValid(pod._lvsWeaponEnt) then
		return pod._lvsWeaponEnt
	end

	for _, child in ipairs(pod:GetChildren()) do
		if IsValid(child) and (child.LVS_GUNNER or child:GetClass() == "lvs_base_gunner") then
			return child
		end
	end

	-- Framework: passenger gunner is on the pod; driver handler is the vehicle.
	if IsValid(ply) and isfunction(ply.lvsGetWeaponHandler) then
		local w = ply:lvsGetWeaponHandler()
		if IsValid(w) then return w end
	end

	return NULL
end

-- Mounted gun on THIS pod (jeep MG, ring). Not the chassis handler the
-- driver always has вЂ” that made RMB steal the camera on bukhanka.
function ZC_LVS.PodHasGunnerEnt(pod)
	if not IsValid(pod) then return false end
	if pod.LVS_GUNNER then return true end
	if ZC_LVS.SeatWeaponType(pod) == "gunner" then return true end
	if isfunction(pod.lvsGetWeapon) then
		local w = pod:lvsGetWeapon()
		if IsValid(w) and w ~= pod:GetParent() then
			if w.LVS_GUNNER or w:GetClass() == "lvs_base_gunner" then
				return true
			end
		end
	end
	for _, child in ipairs(pod:GetChildren()) do
		if IsValid(child) and (child.LVS_GUNNER or child:GetClass() == "lvs_base_gunner") then
			return true
		end
	end
	return false
end

-- Armed passenger pod (UAZ MG, vanilla LVS gun, door gun).
-- Car / aircraft / tank DRIVER is never this (those use 1вЂ“0 vehicle weapons).
-- Driver of an open emplacement (type gunner, static MG) is a turret.
function ZC_LVS.IsTurretSeat(ply)
	if not IsValid(ply) or not ply.InVehicle or not ply:InVehicle() then return false end

	local veh = ZC_LVS.GetVehicle(ply)
	local pod = ply:GetVehicle()
	local isDriver = IsValid(veh) and (
		ZC_LVS.IsDriver(ply, veh)
		or (isfunction(veh.GetDriverSeat) and veh:GetDriverSeat() == pod)
	)
	if isDriver then
		if not IsValid(veh) then return false end
		if ZC_LVS.IsCar(veh) or ZC_LVS.IsAircraft(veh) or ZC_LVS.IsClosedVehicle(veh) then
			return false
		end
	end

	if not isDriver and ZC_LVS.IsRoofSeat(pod, veh) then
		return true
	end
	if ZC_LVS.PodHasGunnerEnt(pod) then
		return true
	end

	local w = ZC_LVS.GetPodWeapon(pod, ply)
	if not IsValid(w) then return false end
	if w.LVS_GUNNER or w:GetClass() == "lvs_base_gunner" then
		return true
	end
	if ZC_LVS.SeatWeaponType(pod) == "gunner" then
		return true
	end
	-- Passenger gunner even if the handler is the chassis (this BRDM).
	if not isDriver and isfunction(w.GetActiveWeapon) then
		return true
	end
	return false
end

-- Open van/UAZ/BRDM hull (not Sherman/LAV). Any seat on it uses ZC Fake.
function ZC_LVS.IsOpenCarHull(veh)
	if not IsValid(veh) or not ZC_LVS.IsCar(veh) then return false end
	if ZC_LVS.IsClosedVehicle(veh) then return false end
	if isfunction(veh.GetDriverSeat) and ZC_LVS.PodHidesPlayer(veh:GetDriverSeat()) then
		return false
	end
	return true
end

-- Any LVS open hull with a roof / hatch / gunner pod (BRDM, BTR, MG jeep,
-- USA pack, вЂ¦). Bukhanka has none вЂ” GetPodWeapon on the driver is the
-- chassis handler and made RMB yeet the camera.
function ZC_LVS.CarHasGunSeat(veh)
	if not ZC_LVS.IsOpenCarHull(veh) then return false end
	local function isGunPod(pod)
		if not IsValid(pod) then return false end
		if ZC_LVS.IsRoofSeat(pod, veh) then return true end
		if ZC_LVS.PodHasGunnerEnt(pod) then return true end
		if ZC_LVS.SeatWeaponType and ZC_LVS.SeatWeaponType(pod) == "gunner" then
			return true
		end
		return false
	end
	if isfunction(veh.GetDriverSeat) and isGunPod(veh:GetDriverSeat()) then
		return true
	end
	if isfunction(veh.GetPassengerSeats) then
		local seats = veh:GetPassengerSeats()
		if istable(seats) then
			for _, pod in pairs(seats) do
				if isGunPod(pod) then return true end
			end
		end
	end
	local kids = veh.GetChildren and veh:GetChildren()
	if istable(kids) then
		for i = 1, #kids do
			if ZC_LVS.IsLVSSeat(kids[i]) and isGunPod(kids[i]) then
				return true
			end
		end
	end
	return false
end

-- Hatch / MG: LVS sight. Open-car DRIVER never вЂ” a passenger MG made
-- CTRL/RMB steal the driver camera (clip 19.02 VW Buggy).
function ZC_LVS.CanLVSAim(ply)
	if not IsValid(ply) then return false end
	if ZC_LVS.IsTurretSeat(ply) then return true end
	local veh = ZC_LVS.GetVehicle(ply)
	local pod = ply:GetVehicle()
	if ZC_LVS.PodHasGunnerEnt(pod) then return true end
	if ZC_LVS.IsRoofSeat(pod, veh) then return true end
	return false
end

-- Stand-at-MG dummy broke camera and ejected. Jeep MG later.
function ZC_LVS.ShouldStandAtWeapon(ply)
	return ZC_LVS.IsTurretSeat(ply)
end

function ZC_LVS.IsMountedWeaponSeat(ply)
	return ZC_LVS.IsTurretSeat(ply) or ZC_LVS.CanLVSAim(ply)
end

-- "sit" | "stand" for any LVS seat. Hatch / cabin sit. Open jeep MG
-- can stand later (ShouldStandAtWeapon). Rifle in a sit pod = stand pose.
function ZC_LVS.SeatPose(ply, pod, veh)
	if ZC_LVS.ShouldStandAtWeapon(ply) then
		return "stand"
	end
	return "sit"
end

-- Hatch/gunner on the hull. Height vs chassis center вЂ” not OBB (antenna)
-- and not "open sky" (that matched jeep drivers: no fake, no damage).
function ZC_LVS.IsRoofSeat(pod, veh)
	if not IsValid(pod) or not IsValid(veh) then return false end
	if ZC_LVS.IsAircraft(veh) then return false end
	return pod:GetPos().z > veh:WorldSpaceCenter().z + 22
end

-- Roof hatch or gunner pod on any LVS hull (not aircraft).
-- Pass the pod on leave: ply:GetVehicle() is already empty then.
function ZC_LVS.IsHatchSeat(ply, pod, veh)
	pod = pod or (IsValid(ply) and ply.GetVehicle and ply:GetVehicle()) or NULL
	veh = veh or ZC_LVS.GetChassis(pod)
	if ZC_LVS.IsRoofSeat(pod, veh) then return true end
	if ZC_LVS.PodHasGunnerEnt(pod) then return true end
	if ZC_LVS.SeatWeaponType(pod) == "gunner" then return true end
	if ZC_LVS.IsTurretSeat(ply) then return true end
	return false
end

-- Shared garbage-position guard (NaN / out-of-world).
function ZC_LVS.IsCrazyPos(pos)
	if not isvector(pos) then return true end
	if pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z then return true end
	if math.abs(pos.x) > 16384 or math.abs(pos.y) > 16384 or math.abs(pos.z) > 16384 then
		return true
	end
	return false
end

function ZC_LVS.FakeSeatLocal(ply, pod, veh)
	if not IsValid(pod) or not IsValid(veh) then return end
	-- Packs with an attached gunner model (M113 turret) expose named
	-- attachments. Place the fake exactly where the pack's DrawGunner
	-- drew its mannequin: LocalToWorld(-5,0,-25, turret attachment),
	-- so the body and the turret weapon line up.
	if pod.HidePlayer == true then
		local id = veh.LookupAttachment and veh:LookupAttachment("turret")
		if id and id > 0 then
			local att = veh:GetAttachment(id)
			if att and isvector(att.Pos) and isangle(att.Ang) then
				local pos, _ = LocalToWorld(Vector(-5, 0, -25), angle_zero, att.Pos, att.Ang)
				if not ZC_LVS.IsCrazyPos(pos) then
					return veh:WorldToLocal(pos)
				end
			end
		end
	end
	local lp = veh:WorldToLocal(pod:GetPos())
	local center = veh:WorldToLocal(veh:WorldSpaceCenter())
	if ZC_LVS.IsRoofSeat(pod, veh) then
		lp.z = center.z + 18
	else
		lp.z = lp.z + 8
	end
	-- A mounted weapon handler can be offset from the actual person seat.
	-- Keep the fake at the pod origin, with a small hull-relative correction.
	if ZC_LVS.IsTurretSeat(ply) and not ZC_LVS.IsRoofSeat(pod, veh) then
		lp.z = lp.z + 10
	end
	return lp
end

-- Sitting-eye origin in the cabin. Roof pods drop to hull height so the
-- camera is not inside the hatch metal.
function ZC_LVS.CabinCamPos(pod, veh)
	if not IsValid(pod) then
		if IsValid(veh) then
			return veh:WorldSpaceCenter() + Vector(0, 0, 24)
		end
		return vector_origin
	end
	if not IsValid(veh) then
		return pod:GetPos() + Vector(0, 0, 36)
	end
	local lp = veh:WorldToLocal(pod:GetPos())
	local c = veh:WorldToLocal(veh:WorldSpaceCenter())
	if ZC_LVS.IsRoofSeat(pod, veh) then
		lp.z = c.z + 22
	else
		lp.z = lp.z + 32
	end
	return veh:LocalToWorld(lp)
end

-- Sitting eyes that ride the hull. Independent of ragdoll physics.
function ZC_LVS.CarEyePos(ply, pod, veh)
	veh = IsValid(veh) and veh or NULL
	if not IsValid(veh) and IsValid(pod) then
		veh = ZC_LVS.GetChassis(pod)
	end
	if IsValid(ply) and ply.GetNWBool and ply:GetNWBool("zc_lvs_has_car_eye") and IsValid(veh) then
		local lp = ply:GetNWVector("zc_lvs_car_eye")
		if isvector(lp) then
			return veh:LocalToWorld(lp)
		end
	end
	if IsValid(pod) and IsValid(veh) then
		return ZC_LVS.CabinCamPos(pod, veh)
	end
	if IsValid(pod) then
		return pod:GetPos() + Vector(0, 0, 36)
	end
	return vector_origin
end

-- Aim relative to the hull, not the prisoner_pod (-90 pitch = look at the seat).
function ZC_LVS.CarEyeAngles(ply, veh, pod)
	if not IsValid(ply) then return angle_zero end
	local up = vector_up
	if IsValid(veh) then
		up = veh:GetUp()
	elseif IsValid(pod) then
		up = pod:GetUp()
	end
	local ex = ply:GetAimVector():AngleEx(up)
	ex.r = 0
	-- ZC zeros EyeAngles on enter; prisoner_pod then looks into the seat.
	if ply.zc_lvs_cl_enter and ply.zc_lvs_cl_enter > CurTime() then
		ex.p = math.Clamp(ex.p, -18, 12)
	end
	return ex
end

function ZC_LVS.IsClosedVehicle(veh)
	if not IsValid(veh) then return false end
	if ZC_LVS.IsAircraft(veh) then return false end
	-- These SES utility/UAZ variants use a hidden LVS pod internally, but
	-- their Z-City seating is an open vehicle fake and must support eject.
	local class = string.lower(veh:GetClass() or "")
	if class == "ses_uaz452" or class == "ses_raf2203_radiochem" then
		return false
	end
	-- Towed / stationary guns: HidePlayer on the driver pod hides a STAND-
	-- IN body behind the gun, not a crew inside armor. Open-air crew.
	if ZC_LVS.IsStationaryGun(veh) then
		return false
	end
	if ZC_LVS.GetType(veh) == "tank" then return true end
	if ZC_LVS.Inherits(veh, TANK_BASES) or ZC_LVS.ChainHas(veh, "lvs_tank") then
		return true
	end
	-- Seats the pack hides = behind armor (LAV-25, Flak, UAV station).
	if isfunction(veh.GetDriverSeat) then
		local ds = veh:GetDriverSeat()
		if ZC_LVS.PodHidesPlayer(ds) then return true end
	end
	-- Tank view helpers: SW AVF turret PICKUPS (hilux_grom / dshk / grad /
	-- zu, вЂ¦) include lvs_tank_wheeldrive/modules/cl_tankview.lua for the
	-- roof gun, so isfunction(TankViewOverride) is true on their OPEN
	-- hulls (client realm only -- the include lives in cl_init.lua).
	-- A car with a visible driver is open no matter which modules it
	-- pulled in; only a non-car hull keeps the tank classification.
	if (isfunction(veh.CalcTankView) or isfunction(veh.TankViewOverride))
		and not ZC_LVS.IsCar(veh) then
		return true
	end
	return false
end

function ZC_LVS.IsExternalLVSSeat(ply)
	if not IsValid(ply) or not ply:InVehicle() then return false end
	local pod = ply:GetVehicle()
	local veh = ZC_LVS.GetVehicle(ply)
	if not IsValid(veh) or not IsValid(pod) then return false end
	return ZC_LVS.IsClosedVehicle(veh) or ZC_LVS.PodHidesPlayer(pod) or ZC_LVS.IsTurretSeat(ply)
end

-- LVS sets this on seats with no cabin: hide the player until exit / explode.
function ZC_LVS.PodHidesPlayer(pod)
	return IsValid(pod) and pod.HidePlayer == true
end

-- No cabin to sit in: tank, or LVS HidePlayer (LAV-25 even if wheeldrive).
function ZC_LVS.IsNoInterior(ply)
	if not IsValid(ply) or not ply.InVehicle or not ply:InVehicle() then return false end
	local veh = ZC_LVS.GetVehicle(ply)
	local pod = ply:GetVehicle()
	if ZC_LVS.IsClosedVehicle(veh) then return true end
	if ZC_LVS.PodHidesPlayer(pod) then return true end
	return false
end

-- Seat is inside armor: a short ray from sitting eyes hits our own hull.
-- Open cars hit windshield farther out; tanks/APCs hit the plate immediately.
function ZC_LVS.SeatEnclosed(pod, veh)
	if not IsValid(pod) or not IsValid(veh) then return false end
	if ZC_LVS.IsAircraft(veh) then return false end

	local start = pod:GetPos() + Vector(0, 0, 28)
	local dirs = {
		pod:GetForward(),
		(pod:GetForward() * 0.85 + pod:GetUp() * 0.2),
		(pod:GetForward() * 0.85 - pod:GetRight() * 0.2),
	}

	local insideHits = 0
	local closeHits = 0
	for i = 1, #dirs do
		local dir = dirs[i]
		if dir:LengthSqr() < 0.01 then continue end
		dir:Normalize()
		local tr = util.TraceLine({
			start = start,
			endpos = start + dir * 48,
			filter = function(hit)
				if not IsValid(hit) then return false end
				if hit == pod or hit:IsPlayer() then return false end
				local class = hit:GetClass()
				if class == "prop_ragdoll" or class == "prop_vehicle_prisoner_pod" then return false end
				return hit == veh or hit:GetParent() == veh or hit.LVS == true
			end,
			mask = MASK_SOLID,
		})
		if tr.StartSolid then
			insideHits = insideHits + 1
		elseif tr.Hit and start:DistToSqr(tr.HitPos) < 26 * 26 then
			closeHits = closeHits + 1
		end
	end
	-- Open cars: windshield is close, not StartSolid. APC cabin is StartSolid.
	if ZC_LVS.IsCar(veh) then
		return insideHits >= 2
	end
	return (insideHits + closeHits) >= 2
end

--[[
	Seat matrix (Oppai 06.10, the user's own table — THE single source of
	truth for cameras on ground vehicles; air is handled separately).

	Returns a table:
	  fake   — this seat gets a ragdoll fake (body + damage + camera)
	  eyes   — FP camera = the fake's eyes ("ZC cam" and "fake eyes" are
	           the same thing; there are only two cameras)
	  ctrl   — Ctrl third person works here (only on vanilla seats)

	G1 cars (no weapons)        → fake+eyes everywhere, no Ctrl.
	G2 closed hulls             → seats the pack hides (no hatch: M113
	       driver, the whole Abrams) → vanilla, Ctrl (fair or not).
	       Troop seats with a usable rear ramp ("задние места буханки":
	       look out, get shot, get dragged out) → fake+eyes.
	       M113 turret gunner: hatch — fake with eyes standing at the MG.
	G3 armed pickups (open cab) → driver/passengers fake+eyes; the gunner
	       seat (pack sight, HidePlayer) → vanilla + Ctrl.
	Air (all seats)             → fake+eyes, no Ctrl.

	Ctrl is gated on zc_lvs_debug (Oppai 06.10: realism — no third person
	in play; debug mode keeps it for testing).
]]
function ZC_LVS.SeatMatrix(ply, pod, veh)
	local out = { fake = false, eyes = false, ctrl = false }
	if not IsValid(ply) or not IsValid(pod) then return out end
	veh = veh or ZC_LVS.GetChassis(pod)
	if not IsValid(veh) then return out end

	-- FPV drone: no fake, no eyes. The pack FPV screen is the camera;
	-- only HP/damage stays (LVS airframe takes the hits).
	if ZC_LVS.IsDrone(veh) then
		return out
	end

	local isAir = ZC_LVS.IsAircraft(veh) or ZC_LVS.IsPlane(veh)

	if isAir then
		out.fake = true
		out.eyes = true
		return out
	end

	-- Ctrl only exists in debug mode (realism rule).
	local ctrlOK = ZC_LVS.DebugEnabled()

	-- Stationary gun (FlaK / Pak40 / ground station): the gunner's body
	-- is visible at the gun (fake + eyes), LVS sight on RMB. The pod
	-- HidePlayer hides a stand-in, not a cabin -- keep the ZC eyes.
	if ZC_LVS.IsStationaryGun(veh) then
		out.fake = true
		out.eyes = true
		return out
	end

	-- Gunner seat of an ARMED OPEN pickup / car (G3): the pack sight won.
	if ZC_LVS.PodHidesPlayer(pod) and ZC_LVS.IsCar(veh) then
		out.fake = true
		out.eyes = false
		out.ctrl = ctrlOK
		return out
	end

	-- Closed hull (G2).
	if ZC_LVS.IsClosedVehicle(veh) then
		local role = ZC_LVS.PodRole(ply, pod, veh)
		if ZC_LVS.PodHidesPlayer(pod) then
			-- Turret gunner with an open hatch (M113): body + eyes at the MG.
			if ZC_LVS.IsTurretSeat(ply) and role == "gunner" then
				out.fake = true
				out.eyes = true
				return out
			end
			-- No hatch: M113 driver, the whole Abrams. Vanilla only.
			out.ctrl = ctrlOK and role ~= "driver"
			return out
		end
		-- The DRIVER of a closed hull sits behind armor even if his pod
		-- does not set HidePlayer — vanilla periscopes, no fake (clip
		-- 06.10: camera ended up in the ceiling "how am I supposed to
		-- see anything here").
		if role == "driver" then
			out.ctrl = ctrlOK
			return out
		end
		-- Troop seat: rear ramp ("задние места буханки") — fake + eyes.
		out.fake = true
		out.eyes = true
		return out
	end

	-- G1 cars: fake + eyes everywhere.
	out.fake = true
	out.eyes = true
	return out
end

-- RMB / LVS ZOOM. BRDM default is ZC sit; this flips on the Sherman-style sight.
function ZC_LVS.IsAimingLVS(ply)
	if not IsValid(ply) then return false end
	if ply.lvsKeyDown and ply:lvsKeyDown("ZOOM") then
		return true
	end
	if ply.KeyDown and ply:KeyDown(IN_ATTACK2) then
		return true
	end
	return false
end

-- CanLVSAim is the expensive call (weapon handler chain, children scans).
-- Compute it once per frame per player; CameraMode already runs many
-- times per frame (TP pipeline, HUD, weapon hooks).
function ZC_LVS.CanLVSAimCached(ply)
	if not IsValid(ply) then return false end
	local now = CurTime()
	if ply.zc_lvs_aim_t == now and ply.zc_lvs_aim_v ~= nil then
		return ply.zc_lvs_aim_v
	end
	ply.zc_lvs_aim_v = ZC_LVS.CanLVSAim(ply)
	ply.zc_lvs_aim_t = now
	return ply.zc_lvs_aim_v
end

-- "zc" | "lvs_air" | "lvs_plane" | "lvs_gun" | "lvs_closed" | "none"
function ZC_LVS.CameraMode(ply)
	if not ZC_LVS.Enabled() or not IsValid(ply) then return "none" end
	if not ply.InVehicle or not ply:InVehicle() then return "none" end

	local now = CurTime()
	local veh = ZC_LVS.GetVehicle(ply)
	if not IsValid(veh) then
		local pod = ply:GetVehicle()
		veh = IsValid(pod) and pod:GetParent() or NULL
	end
	if not IsValid(veh) then return "none" end

	-- Drone FPV: the pack's screen is the camera. Fully vanilla, no fake.
	-- (Checked before the cache: cheap, and never flips per-frame.)
	if ZC_LVS.IsDrone(veh) then
		return "none"
	end

	-- Hatch/gun RMB must be able to flip to LVS sight this frame: the
	-- expensive CanLVSAim runs once per frame (cache), the mode itself
	-- re-derives whenever aiming could have flipped it.
	local hatch = ZC_LVS.CanLVSAimCached(ply)
	local aiming = ZC_LVS.IsAimingLVS(ply)
	if not hatch and not aiming and ply.zc_lvs_cam_mode and ply.zc_lvs_cam_t == now then
		return ply.zc_lvs_cam_mode
	end

	local mode = "zc"
	local podRole = ZC_LVS.PodRole(ply, ply:GetVehicle(), veh)
	-- AIR = ZC camera from the fake's eyes (rule, Oppai 08.10: "фейк
	-- везде, в авиации нет ничего закрытого"). zc_lvs_air_camera flips the
	-- rare packs back to the native LVS camera (opt-out, default 0).
	if ZC_LVS.IsPlane(veh) then
		if GetConVar("zc_lvs_air_lvcam"):GetBool() then
			mode = "lvs_plane"
		end
	elseif ZC_LVS.IsAircraft(veh) or LVS_CAMERA_TYPES[ZC_LVS.GetType(veh)] then
		if GetConVar("zc_lvs_air_lvcam"):GetBool() then
			mode = "lvs_air"
		end
	elseif ZC_LVS.IsClosedVehicle(veh) or ZC_LVS.PodHidesPlayer(ply:GetVehicle()) then
		-- Closed combat vehicles: the matrix decides (Oppai 06.10).
		-- Seats with eyes (troop ramp, hatch gunner) = the ZC camera —
		-- the same body/hands/weapon view the cars have. Seats the pack
		-- hides (driver behind armor, the whole Abrams) = native LVS.
		local matrix = ZC_LVS.SeatMatrix(ply, ply:GetVehicle(), veh)
		if matrix.eyes then
			mode = "zc"
		else
			mode = aiming and "lvs_gun" or "lvs_closed"
		end
	elseif podRole == "gunner" then
		mode = aiming and "lvs_gun" or "zc"
	elseif podRole == "driver" and ZC_LVS.IsOpenCarHull(veh) then
		mode = "zc"
	elseif ZC_LVS.SeatEnclosed(ply:GetVehicle(), veh)
		and (not ZC_LVS.IsCar(veh) or ZC_LVS.CarHasGunSeat(veh)) then
		-- APC basket is StartSolid. Bukhanka windshield is not, and has no gun seat.
		mode = "lvs_closed"
	elseif hatch then
		-- Person in the seat (ref BRDM clip). RMB = LVS sight.
		-- No unique interior/hands per vehicle.
		if aiming then
			mode = "lvs_gun"
		else
			mode = "zc"
		end
	elseif ZC_LVS.IsCar(veh) then
		mode = "zc"
	end

	ply.zc_lvs_cam_mode = mode
	ply.zc_lvs_cam_t = now
	if mode ~= ply.zc_lvs_cam_last then
		ply.zc_lvs_cam_last = mode
		ZC_LVS.DebugLog("view_mode", "mode=" .. mode)
	end
	return mode
end

function ZC_LVS.ShouldUseLVSCamera(ply)
	local mode = ZC_LVS.CameraMode(ply)
	return mode == "lvs_air" or mode == "lvs_plane" or mode == "lvs_gun" or mode == "lvs_closed"
end

-- Never replace LVS view/mouse. Fake is body + organism only.
-- Open-MG SeatCamPos followed the ragdoll into the jeep bed.
function ZC_LVS.ShouldUseOurCamera(ply)
	if not IsValid(ply) or not ply:InVehicle() then return false end
	local veh = ZC_LVS.GetVehicle(ply)
	local rag = ply.FakeRagdoll
	if not IsValid(rag) and ply.GetNWEntity then rag = ply:GetNWEntity("FakeRagdoll") end
	return IsValid(veh) and ZC_LVS.IsOpenCarHull(veh)
		and IsValid(rag) and ZC_LVS.CameraMode(ply) == "zc"
end

function ZC_LVS.ShouldUseZCityCamera(ply)
	return ZC_LVS.CameraMode(ply) == "zc"
end

-- Hatch / gun / air / tank: LVS weapons + RMB sight. No ZC Z/C selector.
function ZC_LVS.ShouldBlockZCWeapons(ply)
	if not IsValid(ply) then return false end
	local mode = ZC_LVS.CameraMode(ply)
	if mode == "lvs_gun" or mode == "lvs_closed" or mode == "lvs_air" or mode == "lvs_plane" then
		return true
	end
	if ZC_LVS.IsTurretSeat(ply) then
		return true
	end
	local veh = ZC_LVS.GetVehicle(ply)
	return ZC_LVS.IsRoofSeat(ply:GetVehicle(), veh)
end

-- Weld CallOnRemove and similar call ply:ExitVehicle() directly (bypasses
-- CanExitVehicle). That is "van drives, you stay on the grass".
function ZC_LVS.AllowExit(ply, hold)
	if not IsValid(ply) then return end
	ply.zc_lvs_allow_exit = CurTime() + (tonumber(hold) or 0.6)
end

function ZC_LVS.MayExitVehicle(ply)
	if not IsValid(ply) then return true end
	if ply.switchingseat then return true end
	if ply.zc_lvs_switch_until and ply.zc_lvs_switch_until > CurTime() then return true end
	if ply.zc_lvs_allow_exit and ply.zc_lvs_allow_exit > CurTime() then return true end
	if ply.lvsKeyDown and ply:lvsKeyDown("EXIT") then return true end
	if ply.KeyDown and ply:KeyDown(IN_USE) then return true end
	return false
end

function ZC_LVS.ShouldFake(ply)
	if not ZC_LVS.Enabled() then return false end
	if not GetConVar("zc_lvs_fake"):GetBool() then return false end
	if not hg or not hg.Fake then return false end

	local veh = ZC_LVS.GetVehicle(ply)
	local pod = IsValid(ply) and ply:GetVehicle() or NULL
	-- FPV drone: no body at the control stick, the pack draws its own
	-- operator model. Nothing to fake or damage.
	if IsValid(veh) and ZC_LVS.IsDrone(veh) then
		return false
	end
	if IsValid(veh) and ZC_LVS.IsAircraft(veh) then
		if not GetConVar("zc_lvs_air_fake"):GetBool() then
			return false
		end
	end

	-- Damage contract: a fake on every occupied LVS seat. Camera is
	-- separate. Do not call hg.NoFakeInCar (we set that so ZC skips
	-- EnterVehicleRag on closed/air; we still fake).
	return true
end

function ZC_LVS.IsCrashEjected(ply)
	if not IsValid(ply) then return false end
	local rag = ply.FakeRagdoll
	return ply.zc_lvs_eject_state == "ragdoll_free" or (IsValid(rag) and rag.zc_lvs_crash_ejected == true)
end

function ZC_LVS.IsUnconscious(ply)
	if not IsValid(ply) then return false end

	local org = ply.organism
	if not org and IsValid(ply.FakeRagdoll) then
		org = ply.FakeRagdoll.organism
	end

	return org and org.otrub and true or false
end

local HANDS = {
	weapon_hands_sh = true,
	weapon_hands = true,
}

local ONE_HAND_HOLD = {
	pistol = true,
	revolver = true,
	grenade = true,
	slam = true,
	normal = true,
	knife = true,
	melee = true,
	magic = true,
	camera = true,
}

function ZC_LVS.HasEmptyHands(ply)
	if not IsValid(ply) then return true end
	local wep = ply:GetActiveWeapon()
	if not IsValid(wep) then return true end
	return HANDS[wep:GetClass()] == true
end

function ZC_LVS.IsTwoHandedWeapon(ply)
	if not IsValid(ply) or ZC_LVS.HasEmptyHands(ply) then return false end
	local wep = ply:GetActiveWeapon()
	if not IsValid(wep) then return false end
	if isfunction(wep.IsPistolHoldType) then
		return not wep:IsPistolHoldType()
	end
	return not ONE_HAND_HOLD[wep:GetHoldType() or ""]
end

function ZC_LVS.IdleVehicle(veh)
	if not IsValid(veh) then return end

	-- Do not SetBrake / SetNWHandBrake: they stick after wake (~7 km/h crawl).
	if veh.SetThrottle then
		veh:SetThrottle(0)
	end
	if veh.SetSteer then
		local cur = veh.GetSteer and veh:GetSteer()
		if isvector(cur) then
			veh:SetSteer(Vector(0, 0, 0))
		else
			veh:SetSteer(0)
		end
	end
	if veh.SetThrust then
		veh:SetThrust(0)
	end
	if veh.SetNWThrust then
		veh:SetNWThrust(0)
	end
end

function ZC_LVS.ReleaseIdleVehicle(veh)
	if not IsValid(veh) then return end
	if veh.SetBrake then
		veh:SetBrake(0)
	end
	if veh.SetNWHandBrake then
		veh:SetNWHandBrake(false)
	end
end

-- Vans/jeeps/trucks. Disabled: "Р»РµР¶РёС‚ РІ РєСѓР·РѕРІРµ" trapped ragdolls so you
-- could not FakeUp after a door-exit crash (clip 21.33). Remake later.
function ZC_LVS.CanKeepCargo(veh)
	if not IsValid(veh) or not veh.LVS then return false end
	if ZC_LVS.IsAircraft(veh) or ZC_LVS.IsPlane(veh) then return false end
	if ZC_LVS.IsClosedVehicle(veh) then return false end
	return ZC_LVS.IsCar(veh)
end

function ZC_LVS.GetCargoVehicle(ply)
	if not IsValid(ply) then return NULL end
	if IsValid(ply.zc_lvs_cargo) then return ply.zc_lvs_cargo end
	if ply.GetNWEntity then
		local veh = ply:GetNWEntity("zc_lvs_cargo")
		if IsValid(veh) then return veh end
	end
	return NULL
end

function ZC_LVS.IterOccupants(veh, fn)
	if not IsValid(veh) or not isfunction(fn) then return end
	local seen = {}
	local visit = function(ply)
		if not IsValid(ply) or not ply:IsPlayer() or seen[ply] then return end
		seen[ply] = true
		fn(ply)
	end
	if isfunction(veh.GetEveryone) then
		local ok, everyone = pcall(veh.GetEveryone, veh)
		if ok and istable(everyone) then
			for i = 1, #everyone do
				visit(everyone[i])
			end
		end
	end
	for _, ply in player.Iterator() do
		local seated = ply:InVehicle() and ZC_LVS.GetVehicle(ply) == veh
		if seated or ply.zc_lvs_cargo == veh or (ply.GetNWEntity and ply:GetNWEntity("zc_lvs_cargo") == veh) then
			visit(ply)
		end
	end
end

function ZC_LVS.HoldingAlt(ply)
	if not IsValid(ply) then return false end
	if ply.zc_lvs_alt then return true end
	if ply:KeyDown(IN_WALK) then return true end
	if CLIENT then
		return input.IsKeyDown(KEY_LALT) or input.IsKeyDown(KEY_RALT)
	end
	return false
end

local ALT_HOLD = {
	[KEY_LALT] = true,
	[KEY_RALT] = true,
}

hook.Add("PlayerButtonDown", "zc_lvs_alt_hold", function(ply, button)
	if ALT_HOLD[button] then
		ply.zc_lvs_alt = true
	end
end)

hook.Add("PlayerButtonUp", "zc_lvs_alt_hold", function(ply, button)
	if ALT_HOLD[button] then
		ply.zc_lvs_alt = nil
	end
end)

ZC_LVS.WEAPON_KEYS = {
	[KEY_1] = 1,
	[KEY_2] = 2,
	[KEY_3] = 3,
	[KEY_4] = 4,
	[KEY_5] = 5,
	[KEY_6] = 6,
	[KEY_7] = 7,
	[KEY_8] = 8,
	[KEY_9] = 9,
	[KEY_0] = 10,
}

-- Prisoner pods are "chairs" for ZC. LVS cars are real vehicles.
if hg and hg.isdriveablevehicle and not ZC_LVS._wrappedDriveable then
	ZC_LVS._wrappedDriveable = true
	local oldDriveable = hg.isdriveablevehicle
	function hg.isdriveablevehicle(veh)
		if ZC_LVS.Enabled() and ZC_LVS.IsLVSSeat(veh) then
			local chassis = ZC_LVS.GetChassis(veh)
			if IsValid(chassis) then
				return not ZC_LVS.IsAircraft(chassis)
			end
		end
		return oldDriveable(veh)
	end
end

-- ZC's official "do not auto-Fake in this vehicle". Returning true here
-- stops EnterVehicleRag / Ragdoll_Create parent+weld on LVS pods.
-- We Fake ourselves from PlayerEnteredVehicle.
ZC_LVS._origNoFakeInCar = ZC_LVS._origNoFakeInCar or (hg and hg.NoFakeInCar)
if hg and ZC_LVS._origNoFakeInCar then
	function hg.NoFakeInCar(veh)
		if ZC_LVS.Enabled() then
			-- Open cars: ZC EnterVehicleRag / Fake like Glide. Do not steal it.
			if ZC_LVS.IsLVSSeat(veh) then
				local chassis = ZC_LVS.GetChassis(veh)
				-- Hatch uses the same ZC Fake as the driver (clip 17.11).
				if ZC_LVS.IsOpenCarHull(chassis) then
					return false
				end
				return true
			end
			if IsValid(veh) and veh.LVS then
				if ZC_LVS.IsOpenCarHull(veh) then
					return false
				end
				return true
			end
			local chassis = ZC_LVS.GetChassis(veh)
			if IsValid(chassis) and not (ZC_LVS.IsCar(chassis) and not ZC_LVS.IsClosedVehicle(chassis)) then
				return true
			end
		end
		return ZC_LVS._origNoFakeInCar(veh)
	end
end

-- Aircraft / tank / turret keep LVS camera; open cars keep ZC camera;
-- drones: fully vanilla, block BOTH cameras (the pack screen is the view).
if hg and hg.NoCameraInCar and not ZC_LVS._wrappedNoCam then
	ZC_LVS._wrappedNoCam = true
	local oldNoCam = hg.NoCameraInCar
	function hg.NoCameraInCar(veh)
		if ZC_LVS.Enabled() then
			local chassis = ZC_LVS.GetChassis(veh)
			if not IsValid(chassis) and IsValid(veh) and veh.LVS then
				chassis = veh
			end
			if IsValid(chassis) then
				if ZC_LVS.IsDrone(chassis) then
					return true
				end
				if CLIENT then
					local ply = LocalPlayer()
					if IsValid(ply) and ply:InVehicle() and ply:GetVehicle() == veh then
						local mode = ZC_LVS.CameraMode(ply)
						if mode == "lvs_air" or mode == "lvs_plane" or mode == "lvs_gun" or mode == "lvs_closed" then
							return true
						end
						-- Open cars: never steal ZC camera (Glide).
					end
				elseif ZC_LVS.IsClosedVehicle(chassis) or (LVS_CAMERA_TYPES[ZC_LVS.GetType(chassis)] and GetConVar("zc_lvs_air_lvcam"):GetBool()) then
					return true
				end
			end
		end
		return oldNoCam(veh)
	end
end

-- Occupant fakes are not LVS parts, so the HUD eye-trace hits the lap and
-- the aim circle drops to the bottom of the screen.
function ZC_LVS.AppendOccupantFilter(veh, list)
	if not IsValid(veh) or not istable(list) then
		return list or {veh}
	end

	local function add(ent)
		if IsValid(ent) then
			list[#list + 1] = ent
		end
	end

	if isfunction(veh.GetEveryone) then
		local ok, everyone = pcall(veh.GetEveryone, veh)
		if ok and istable(everyone) then
			for i = 1, #everyone do
				local ply = everyone[i]
				if not IsValid(ply) then continue end
				add(ply)
				add(ply.FakeRagdoll)
				if ply.GetNWEntity then
					add(ply:GetNWEntity("FakeRagdoll"))
				end
			end
		end
	end

	return list
end

function ZC_LVS.WrapAircraftHUD(ent)
	if not IsValid(ent) or not ent.LVS or ent._zc_lvs_hud then return end
	local air = ZC_LVS.IsAircraft(ent)
	local closed = ZC_LVS.IsClosedVehicle(ent)
	local gunner = ent.LVS_GUNNER or ent:GetClass() == "lvs_base_gunner"
	if not air and not closed and not gunner and not isfunction(ent.GetCrosshairFilterEnts) then
		return
	end
	ent._zc_lvs_hud = true

	if isfunction(ent.GetCrosshairFilterEnts) then
		local oldFilter = ent.GetCrosshairFilterEnts
		function ent:GetCrosshairFilterEnts(...)
			local list = oldFilter(self, ...)
			if not istable(list) then
				list = {self}
			else
				list = table.Copy(list)
			end
			return ZC_LVS.AppendOccupantFilter(self, list)
		end
	end

	if air and isfunction(ent.GetEyeTrace) then
		local oldTrace = ent.GetEyeTrace
		function ent:GetEyeTrace(trace_forward)
			local driver = self.GetDriver and self:GetDriver() or NULL
			local startpos

			if CLIENT and IsValid(driver) and driver == LocalPlayer() and isfunction(ZC_LVS.SeatCamPos) then
				local pod = driver:GetVehicle()
				if IsValid(pod) then
					startpos = ZC_LVS.SeatCamPos(driver, pod)
				end
			end

			if not startpos then
				local pod = self.GetDriverSeat and self:GetDriverSeat() or NULL
				if IsValid(pod) then
					startpos = pod:GetPos() + Vector(0, 0, 32)
				else
					return oldTrace(self, trace_forward)
				end
			end

			local aim
			if trace_forward then
				aim = self:GetForward()
			elseif IsValid(driver) and driver.lvsKeyDown and driver:lvsKeyDown("FREELOOK") then
				-- Alt-look: HUD stays on last mouse-aim / nose, not on the camera.
				local stored = driver.zc_lvs_storedAim
				aim = stored and stored:Forward() or self:GetForward()
			elseif IsValid(driver) then
				aim = driver:EyeAngles():Forward()
				driver.zc_lvs_storedAim = driver:EyeAngles()
			else
				aim = self:GetForward()
			end

			local tr = util.TraceLine({
				start = startpos,
				endpos = startpos + aim * 50000,
				filter = self:GetCrosshairFilterEnts(),
			})

			-- Cockpit / ragdoll still ate the ray: keep the circle on the look dir.
			if tr.StartSolid or (tr.Hit and startpos:DistToSqr(tr.HitPos) < 6400) then
				tr.HitPos = startpos + aim * 8000
				tr.Hit = false
			end

			return tr
		end
	end
end

local function wrapExistingAircraft()
	if not LVS or not isfunction(LVS.GetVehicles) then return end
	local list = LVS:GetVehicles()
	if not istable(list) then return end
	for i = 1, #list do
		ZC_LVS.WrapAircraftHUD(list[i])
	end
end

hook.Add("OnEntityCreated", "zc_lvs_wrap_air_hud", function(ent)
	if not IsValid(ent) then return end
	if not ent.LVS then
		local class = ent:GetClass() or ""
		if not string.StartWith(class, "lvs_") then return end
	end
	timer.Simple(0, function()
		if IsValid(ent) then
			ZC_LVS.WrapAircraftHUD(ent)
		end
	end)
end)

hook.Add("InitPostEntity", "zc_lvs_wrap_air_hud", function()
	timer.Simple(1, wrapExistingAircraft)
end)

timer.Simple(0, wrapExistingAircraft)

-- ZC talks to extra vehicles via GlideGetVehicle (TPIK, steering, music).
-- Present LVS chassis there the same way Glide is presented.
do
	local meta = FindMetaTable("Player")
	if meta then
		local oldGet = meta.GlideGetVehicle
		function meta:GlideGetVehicle()
			if oldGet then
				local v = oldGet(self)
				if IsValid(v) then return v end
			end
			if ZC_LVS.Enabled() and self.InVehicle and self:InVehicle() then
				local c = ZC_LVS.GetVehicle(self)
				if IsValid(c) then return c end
			end
			return NULL
		end
		if not meta.GlideGetSeatIndex then
			function meta:GlideGetSeatIndex()
				if ZC_LVS.Enabled() and self.InVehicle and self:InVehicle() and ZC_LVS.IsDriver(self, ZC_LVS.GetVehicle(self)) then
					return 1
				end
				return 0
			end
		end
	end
end

