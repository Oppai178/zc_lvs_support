-- [Z-CITY] LVS SUPPORT
-- Author: Oppai
-- Climb into the cargo of an LVS car without a seat (rear of the van).

ZC_LVS = ZC_LVS or {}

local function notify(ply, text)
	if IsValid(ply) and ply.Notify then
		ply:Notify(text, 4)
	end
end

local function rearOpenOrNoDoors(veh)
	if not isfunction(veh.GetDoorHandlers) then return true end
	local doors = veh:GetDoorHandlers()
	if not istable(doors) or #doors == 0 then return true end

	local mins = veh:OBBMins()
	local sawRear = false
	for i = 1, #doors do
		local door = doors[i]
		if not IsValid(door) then continue end
		local lp = veh:WorldToLocal(door:GetPos())
		if lp.x < mins.x + 48 then
			sawRear = true
			if door.IsOpen and door:IsOpen() then
				return true
			end
		end
	end
	if sawRear then return false end
	return true
end

local function isAtCargo(ply, veh)
	return ZC_LVS.IsAtRear(ply, veh)
end

-- Vans / trucks with a rear door, not tanks sitting on the roof.
local function allowCargo(veh)
	if not IsValid(veh) or not ZC_LVS.IsCar(veh) then return false end
	if ZC_LVS.IsClosedVehicle(veh) then return false end
	if ZC_LVS.IsAircraft(veh) then return false end
	if isfunction(veh.CalcTankView) or isfunction(veh.TankViewOverride) then
		return false
	end

	local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
	local h = maxs.z - mins.z
	if h > 78 then return true end

	if isfunction(veh.GetDoorHandlers) then
		local doors = veh:GetDoorHandlers()
		if istable(doors) then
			for i = 1, #doors do
				local door = doors[i]
				if not IsValid(door) then continue end
				local lp = veh:WorldToLocal(door:GetPos())
				if lp.x < mins.x + 56 then
					return true
				end
			end
		end
	end
	return false
end

-- Rear cargo bed. Vans are hollow-ish; sedans are a solid hull, so we
-- nocollide and place by OBB rather than hoping the trace finds a trunk.
local function cargoBed(veh)
	local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
	local h = maxs.z - mins.z
	local depth = maxs.x - mins.x
	local van = h > 78
	local len = math.Clamp(depth * (van and 0.42 or 0.30), 38, 76)

	local function downTrace(lx, ly)
		return util.TraceLine({
			start = veh:LocalToWorld(Vector(lx, ly, maxs.z - 6)),
			endpos = veh:LocalToWorld(Vector(lx, ly, mins.z - 2)),
			filter = function(hit)
				if not IsValid(hit) then return false end
				if hit:IsPlayer() or hit:GetClass() == "prop_ragdoll" then return false end
				if hit:GetClass() == "prop_vehicle_prisoner_pod" then return false end
				return true
			end,
			mask = MASK_SOLID,
		})
	end

	local zs = {}
	local sampleX = mins.x + len * 0.4
	for _, y in ipairs({0, -10, 10}) do
		local tr = downTrace(sampleX, y)
		if tr.Hit and not tr.StartSolid then
			zs[#zs + 1] = veh:WorldToLocal(tr.HitPos).z
		end
	end

	local floorZ
	if #zs > 0 then
		table.sort(zs)
		floorZ = zs[math.ceil(#zs / 2)] + 3
	elseif van then
		floorZ = mins.z + 10
	else
		floorZ = mins.z + math.Clamp(h * 0.36, 16, 32)
	end

	return {
		x0 = mins.x + 10,
		x1 = mins.x + len,
		y0 = mins.y + 8,
		y1 = maxs.y - 8,
		z = floorZ,
	}
end

-- Sit on the cargo floor. Do not pitch the ragdoll 90В° (that put people
-- on the roof / inside their own camera).
local function ragInCargo(rag, veh)
	local bed = cargoBed(veh)
	local maxs = veh:OBBMaxs()
	if maxs.z - bed.z < 22 then return false end
	local lp = veh:WorldToLocal(rag:WorldSpaceCenter())
	return lp.x >= bed.x0 - 18 and lp.x <= bed.x1 + 18
		and lp.y >= bed.y0 - 24 and lp.y <= bed.y1 + 24
		and lp.z >= bed.z - 28 and lp.z <= maxs.z + 24
end

local function pinRagdollToVeh(rag, veh)
	rag:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	rag:SetParent(NULL)

	local nocollide = constraint.NoCollide(rag, veh, 0, 0)
	local weld = constraint.Weld(rag, veh, 0, 0, 0, true, false)
	rag.welds = rag.welds or {}
	if IsValid(weld) then
		table.insert(rag.welds, weld)
	end
	if IsValid(nocollide) then
		table.insert(rag.welds, nocollide)
	end
end

local function unpinRagdoll(rag)
	if not IsValid(rag) then return end
	rag:SetParent(NULL)
	if rag.welds then
		rag.removingwelds = true
		for _, w in pairs(rag.welds) do
			if IsValid(w) then w:Remove() end
		end
		rag.welds = nil
		rag.removingwelds = nil
	end
	rag:SetCollisionGroup(COLLISION_GROUP_NONE)
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		if IsValid(phys) then
			phys:EnableCollisions(true)
			phys:EnableMotion(true)
			phys:Wake()
		end
	end
end

function ZC_LVS.ExitCargo(ply, thrown)
	if not IsValid(ply) then return end
	local veh = ply.zc_lvs_cargo
	ZC_LVS.DebugLog("cargo_exit_begin", "ply=" .. ply:EntIndex(), "veh=" .. (IsValid(veh) and veh:GetClass() or "invalid"), "thrown=" .. tostring(thrown), "fake=" .. tostring(IsValid(ply.FakeRagdoll)), "inveh=" .. tostring(ply:InVehicle()))
	ply.zc_lvs_cargo = nil
	ply.zc_lvs_cargo_cd = CurTime() + 0.45
	if ply.SetNWEntity then
		ply:SetNWEntity("zc_lvs_cargo", NULL)
	end

	local rag = ply.FakeRagdoll
	unpinRagdoll(rag)

	if IsValid(veh) and ply:Alive() and IsValid(rag) then
		local mins = veh:OBBMins()
		rag:SetPos(veh:LocalToWorld(Vector(mins.x - 42, 0, mins.z + 10)))
	end
	ZC_LVS.DebugLog("cargo_exit_done", "fake=" .. tostring(IsValid(ply.FakeRagdoll)), "inveh=" .. tostring(ply:InVehicle()), "ragpos=" .. (IsValid(rag) and tostring(rag:GetPos()) or "nil"))
end

-- Legacy entry point retained for addons that call it. Cargo no longer
-- creates a fake or moves a player into the vehicle.
function ZC_LVS.EnterCargo(ply, veh)
	return false
end

--[[
function ZC_LVS.EnterCargo(ply, veh)
	ZC_LVS.DebugLog("cargo_enter_attempt", "ply=" .. (IsValid(ply) and ply:EntIndex() or "invalid"), "veh=" .. (IsValid(veh) and veh:GetClass() or "invalid"), "inveh=" .. tostring(IsValid(ply) and ply:InVehicle() or false), "fake=" .. tostring(IsValid(ply) and IsValid(ply.FakeRagdoll) or false))
	if not IsValid(ply) or not IsValid(veh) then return false end
	if not ply:Alive() or ply:InVehicle() then return false end
	if IsValid(ply.zc_lvs_cargo) then return false end
	if IsValid(ply.FakeRagdoll) then return false end
	if not hg or not hg.Fake then return false end
	if not allowCargo(veh) then return false end

	local bed = cargoBed(veh)
	local maxs = veh:OBBMaxs()
	if maxs.z - bed.z < 22 then return false end

	if veh:GetVelocity():Length() > 280 then
		notify(ply, "Too fast.")
		return false
	end

	local spawn = veh:LocalToWorld(Vector((bed.x0 + bed.x1) * 0.5, 0, bed.z + 8))
	ply:SetPos(spawn)
	ply:SetEyeAngles(Angle(20, veh:GetAngles().y, 0))

	ply.zc_lvs_cargo = veh
	ply.zc_lvs_cargo_cd = CurTime() + 0.5
	if ply.SetNWEntity then
		ply:SetNWEntity("zc_lvs_cargo", veh)
	end

	ply.switchingseat = true
	hg.Fake(ply, nil, nil, true)
	ply.switchingseat = nil
	ply:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)

	timer.Simple(0.08, function()
		if not IsValid(ply) or not IsValid(veh) then return end
		local rag = ply.FakeRagdoll
		if not IsValid(rag) then
			ZC_LVS.DebugLog("cargo_enter_no_fake", "ply=" .. ply:EntIndex(), "veh=" .. veh:GetClass())
			ply.zc_lvs_cargo = nil
			ply.zc_lvs_cargo_cd = CurTime() + 0.45
			if ply.SetNWEntity then
				ply:SetNWEntity("zc_lvs_cargo", NULL)
			end
			local mins = veh:OBBMins()
			ply:SetPos(veh:LocalToWorld(Vector(mins.x - 42, 0, mins.z + 10)))
			return
		end

		if layRagdollInCargo(rag, veh) == false then
			ZC_LVS.DebugLog("cargo_enter_bad_bed", "ply=" .. ply:EntIndex(), "veh=" .. veh:GetClass(), "mins=" .. tostring(veh:OBBMins()), "maxs=" .. tostring(veh:OBBMaxs()))
			ZC_LVS.ExitCargo(ply)
			return
		end
		ZC_LVS.DebugLog("cargo_enter_laid", "ply=" .. ply:EntIndex(), "veh=" .. veh:GetClass(), "ragpos=" .. tostring(rag:GetPos()))
		pinRagdollToVeh(rag, veh)
		ply.zc_lvs_cargo = veh
		if ply.SetNWEntity then
			ply:SetNWEntity("zc_lvs_cargo", veh)
		end
	end)

	return true
end
]]

-- No more "sit in cargo with E". That blocked closing the trunk.
-- Bodies stay via sv_interior keep ("Р»РµР¶РёС‚ РІ РєСѓР·РѕРІРµ").

-- Enter the rear cargo area with the normal use key. LVS chassis entities are
-- not vehicles, so this resolves the chassis directly from the trace.
-- Cargo is handled by sv_interior. It keeps loose fakes inside the OBB and
-- releases them through an open door. Do not weld a living fake here.

hook.Add("Think", "zc_lvs_cargo_lock", function()
	-- Intentionally empty. sv_interior is the single cargo boundary system.
end)

hook.Add("Should Fake Up", "zc_lvs_cargo", function(ply)
	-- Never block FakeUp because of a stale cargo marker.
	if IsValid(ply) and ply.zc_lvs_cargo and not IsValid(ply.zc_lvs_cargo) then
		ply.zc_lvs_cargo = nil
		ply:SetNWEntity("zc_lvs_cargo", NULL)
	end
end)

hook.Add("EntityRemoved", "zc_lvs_cargo", function(ent)
	if not ent.LVS then return end
	for _, ply in player.Iterator() do
		if ply.zc_lvs_cargo == ent then
			ZC_LVS.ExitCargo(ply, true)
		end
	end
end)

