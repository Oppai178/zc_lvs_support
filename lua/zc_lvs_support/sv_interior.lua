-- [Z-CITY] LVS SUPPORT
-- Author: Oppai
-- Keep loose ragdolls (and small props) inside LVS interiors so they
-- do not fall out through door holes. Seat passengers are skipped.

ZC_LVS = ZC_LVS or {}

CreateConVar("zc_lvs_keep_interior", "1", FCVAR_ARCHIVE, "Keep loose ragdolls inside LVS vehicles", 0, 1)
CreateConVar("zc_lvs_keep_props", "1", FCVAR_ARCHIVE, "Keep small props/items inside LVS vehicles", 0, 1)
CreateConVar("zc_lvs_keep_props_mass", "45", FCVAR_ARCHIVE, "Max mass to keep inside LVS interiors", 1, 200)

local INSET = 6
local TRACE_LEN = 72
local TRACE_DIRS = {
	Vector(1, 0, 0),
	Vector(-1, 0, 0),
	Vector(0, 1, 0),
	Vector(0, -1, 0),
	Vector(0, 0, 1),
}

local function getLVSVehicles()
	if LVS and isfunction(LVS.GetVehicles) then
		return LVS:GetVehicles() or {}
	end

	local list = {}
	for _, ent in ipairs(ents.GetAll()) do
		if IsValid(ent) and ent.LVS then
			list[#list + 1] = ent
		end
	end
	return list
end

local function isSeatPassengerRagdoll(rag)
	if not IsValid(rag) then return false end
	if rag.welds then return true end

	local parent = rag:GetParent()
	if IsValid(parent) and parent.LVS then
		return true
	end

	local ply = rag.GetNWEntity and rag:GetNWEntity("ply")
	if IsValid(ply) and ply.InVehicle and ply:InVehicle() and ply.FakeRagdoll == rag then
		return true
	end

	return false
end

local function ragOwner(ent)
	if hg and hg.RagdollOwner then
		local ply = hg.RagdollOwner(ent)
		if IsValid(ply) then return ply end
	end
	if ent.GetNWEntity then
		local ply = ent:GetNWEntity("ply")
		if IsValid(ply) then return ply end
	end
	return NULL
end

local function isHeld(ent)
	if not IsValid(ent) then return false end
	if ent:IsPlayerHolding() then return true end

	local ply = ragOwner(ent)
	if IsValid(ply) and ply.zmanipstart then
		return true
	end

	return false
end

local function belongsToVehicle(hit, veh)
	if not IsValid(hit) or not IsValid(veh) then return false end
	if hit == veh then return true end
	if hit:GetParent() == veh then return true end
	if hit.LVSBaseEnt == veh then return true end
	return false
end

local function inVehicleOBB(veh, pos, pad)
	if not IsValid(veh) or not pos then return false end
	pad = pad or 0
	local lp = veh:WorldToLocal(pos)
	local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
	return lp.x > mins.x + pad and lp.x < maxs.x - pad
		and lp.y > mins.y + pad and lp.y < maxs.y - pad
		and lp.z > mins.z + 2 and lp.z < maxs.z - 2
end

-- Hollow vans fail 3/5 world-axis traces (open rear, glass). Ragdolls
-- only need OBB. Props still need traces so we do not weld the lawn.
-- Roof / walking on the hull is not cargo (that slowed people and
-- showed "лежит в кузове" after falling off a plane).
local function isInsideInterior(veh, pos, filter, loose)
	if not ZC_LVS.CanKeepCargo(veh) then return false end
	if not inVehicleOBB(veh, pos, loose and 0 or INSET) then return false end
	local lp = veh:WorldToLocal(pos)
	local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
	local h = maxs.z - mins.z
	if h > 8 and lp.z > mins.z + h * 0.62 then
		return false
	end
	-- Cargo is BEHIND the driver. Hood / cabin are in front of them.
	local driver = isfunction(veh.GetDriverSeat) and veh:GetDriverSeat() or NULL
	if IsValid(driver) then
		if (pos - driver:GetPos()):Dot(veh:GetForward()) > -24 then
			return false
		end
	else
		if (pos - veh:WorldSpaceCenter()):Dot(veh:GetForward()) > 0 then
			return false
		end
	end
	if loose then return true end

	local hits = 0
	for i = 1, #TRACE_DIRS do
		local tr = util.TraceLine({
			start = pos,
			endpos = pos + TRACE_DIRS[i] * TRACE_LEN,
			filter = filter,
			mask = MASK_SOLID,
		})
		if tr.Hit and belongsToVehicle(tr.Entity, veh) then
			hits = hits + 1
		end
	end

	return hits >= 3
end

local kept = {}

local function detach(rag)
	if not IsValid(rag) then
		kept[rag] = nil
		return
	end
	if IsValid(rag.zc_lvs_keep_weld) then
		rag.zc_lvs_keep_weld:Remove()
	end
	if IsValid(rag.zc_lvs_keep_nocollide) then
		rag.zc_lvs_keep_nocollide:Remove()
	end
	rag.zc_lvs_keep_weld = nil
	rag.zc_lvs_keep_nocollide = nil
	rag.zc_lvs_keep_veh = nil
	if rag.SetNWEntity then
		rag:SetNWEntity("zc_lvs_keep_veh", NULL)
	end
	kept[rag] = nil
end

local function worldToLocalVec(veh, vec)
	return veh:WorldToLocal(veh:GetPos() + vec) - veh:WorldToLocal(veh:GetPos())
end

local function localToWorldVec(veh, vec)
	return veh:LocalToWorld(vec) - veh:GetPos()
end

-- Which OBB faces have an open LVS door. Floor/roof never count as exits.
local function openEscapeAxes(veh)
	local open = {
		xmin = false,
		xmax = false,
		ymin = false,
		ymax = false,
	}
	if not ZC_LVS.VehicleHasDoors(veh) then
		-- No door ents: open cars/bikes can fall off the sides.
		-- Tanks / aircraft without door handlers are still sealed.
		if ZC_LVS.IsClosedVehicle(veh) or ZC_LVS.IsAircraft(veh) then
			return open
		end
		open.xmin = true
		open.xmax = true
		open.ymin = true
		open.ymax = true
		return open
	end
	if not isfunction(veh.GetDoorHandlers) then return open end
	local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
	local depth = maxs.x - mins.x
	local width = maxs.y - mins.y
	for _, door in ipairs(veh:GetDoorHandlers()) do
		if not IsValid(door) or not door.IsOpen or not door:IsOpen() then continue end
		local lp = veh:WorldToLocal(door:GetPos())
		if lp.x < mins.x + math.min(56, depth * 0.28) then
			open.xmin = true
		elseif lp.x > maxs.x - math.min(56, depth * 0.28) then
			open.xmax = true
		elseif lp.y < 0 and math.abs(lp.y) > width * 0.18 then
			open.ymin = true
		elseif lp.y > 0 and math.abs(lp.y) > width * 0.18 then
			open.ymax = true
		end
	end
	return open
end

local function attach(rag, veh)
	if not IsValid(rag) or not IsValid(veh) then return end
	if rag.zc_lvs_keep_veh == veh then
		kept[rag] = veh
		if rag.SetNWEntity then
			rag:SetNWEntity("zc_lvs_keep_veh", veh)
		end
		return
	end

	detach(rag)

	-- Ragdolls: no weld. A weld froze them standing in the van.
	-- Cage + gravity makes them actually lie. Props still get a weld.
	if rag:GetClass() ~= "prop_ragdoll" then
		local weld = constraint.Weld(rag, veh, 0, 0, 0, false, false)
		if not IsValid(weld) then return end
		rag.zc_lvs_keep_weld = weld
		weld:CallOnRemove("zc_lvs_keep", function()
			if IsValid(rag) then
				rag.zc_lvs_keep_weld = nil
				rag.zc_lvs_keep_veh = nil
				if rag.SetNWEntity then
					rag:SetNWEntity("zc_lvs_keep_veh", NULL)
				end
			end
			kept[rag] = nil
		end)
	end

	local nocollide = constraint.NoCollide(rag, veh, 0, 0)
	if IsValid(nocollide) then
		rag.zc_lvs_keep_nocollide = nocollide
	end

	rag.zc_lvs_keep_veh = veh
	if rag.SetNWEntity then
		rag:SetNWEntity("zc_lvs_keep_veh", veh)
	end
	kept[rag] = veh
end

function ZC_LVS.GetKeptVehicle(ent)
	if not IsValid(ent) then return NULL end
	if IsValid(ent.zc_lvs_keep_veh) then return ent.zc_lvs_keep_veh end
	if ent.GetNWEntity then
		local veh = ent:GetNWEntity("zc_lvs_keep_veh")
		if IsValid(veh) then return veh end
	end
	return NULL
end

function ZC_LVS.UnloadKept(ent, veh)
	if not IsValid(ent) then return false end
	veh = IsValid(veh) and veh or ZC_LVS.GetKeptVehicle(ent)
	if not IsValid(veh) then return false end
	if isSeatPassengerRagdoll(ent) then return false end

	detach(ent)

	local out
	if isfunction(veh.GetDoorHandlers) then
		for _, door in ipairs(veh:GetDoorHandlers()) do
			if not IsValid(door) then continue end
			if not door.IsOpen or not door:IsOpen() then continue end
			out = door:GetPos() + door:GetForward() * 42 + Vector(0, 0, 8)
			break
		end
	end
	if not out then
		local mins = veh:OBBMins()
		out = veh:LocalToWorld(Vector(mins.x - 48, 0, mins.z + 18))
	end

	local dir = out - ent:WorldSpaceCenter()
	if dir:LengthSqr() < 4 then
		dir = -veh:GetForward()
	else
		dir:Normalize()
	end

	local push = veh:GetVelocity() * 0.35 + dir * 170 + Vector(0, 0, 55)
	local count = ent:GetPhysicsObjectCount()
	if count > 1 then
		for i = 0, count - 1 do
			local phys = ent:GetPhysicsObjectNum(i)
			if IsValid(phys) then
				phys:EnableMotion(true)
				phys:Wake()
				phys:SetVelocity(push)
			end
		end
	else
		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableMotion(true)
			phys:Wake()
			phys:SetPos(out)
			phys:SetVelocity(push)
		else
			ent:SetPos(out)
		end
	end

	return true
end

local function cargoFloorZ(veh)
	local now = CurTime()
	if veh._zc_lvs_floor_t == now and veh._zc_lvs_floorz then
		return veh._zc_lvs_floorz
	end
	local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
	local h = maxs.z - mins.z
	-- Wheels eat the bottom of the OBB. Visual cargo bed is above them.
	-- A roof hit from a high trace was the "hover in the air" floor.
	-- A miss through a hollow van was the "in the ground" floor.
	local z = mins.z + math.Clamp(h * 0.32, 18, 38)
	local zMin = mins.z + 12
	local zMax = mins.z + h * 0.45
	local zStart = mins.z + h * 0.42

	local function down(x, y)
		return util.TraceLine({
			start = veh:LocalToWorld(Vector(x, y, zStart)),
			endpos = veh:LocalToWorld(Vector(x, y, mins.z)),
			filter = function(hit)
				if not IsValid(hit) then return false end
				if hit:IsPlayer() or hit:GetClass() == "prop_ragdoll" then return false end
				if hit:GetClass() == "prop_vehicle_prisoner_pod" then return false end
				return hit == veh or hit:GetParent() == veh or hit.LVS == true
			end,
			mask = MASK_SOLID,
		})
	end

	for _, y in ipairs({0, -14, 14}) do
		for _, xFrac in ipairs({0.18, 0.32}) do
			local tr = down(mins.x + (maxs.x - mins.x) * xFrac, y)
			if tr.Hit and not tr.StartSolid then
				local hz = veh:WorldToLocal(tr.HitPos).z
				if hz > zMin and hz < zMax then
					z = math.max(z, hz + 4)
				end
			end
		end
	end

	veh._zc_lvs_floorz = z
	veh._zc_lvs_floor_t = now
	return z
end

local function clampInside(rag, veh)
	local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
	local floorZ = cargoFloorZ(veh)
	local ceilZ = maxs.z - 8
	local x0, x1 = mins.x + 4, maxs.x - 4
	local y0, y1 = mins.y + 4, maxs.y - 4
	local open = openEscapeAxes(veh)
	local vehVel = veh:GetVelocity()

	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		if not IsValid(phys) then continue end

		local lp = veh:WorldToLocal(phys:GetPos())
		local velL = worldToLocalVec(veh, phys:GetVelocity() - vehVel)
		local moved = false

		if lp.x < x0 then
			if open.xmin then
				-- rear door open: can slide out
			else
				lp.x = x0
				if velL.x < 0 then velL.x = 0 end
				moved = true
			end
		elseif lp.x > x1 then
			if open.xmax then
			else
				lp.x = x1
				if velL.x > 0 then velL.x = 0 end
				moved = true
			end
		end

		if lp.y < y0 then
			if open.ymin then
			else
				lp.y = y0
				if velL.y < 0 then velL.y = 0 end
				moved = true
			end
		elseif lp.y > y1 then
			if open.ymax then
			else
				lp.y = y1
				if velL.y > 0 then velL.y = 0 end
				moved = true
			end
		end

		if lp.z < floorZ then
			lp.z = floorZ
			if velL.z < 0 then velL.z = 0 end
			moved = true
		elseif lp.z > ceilZ then
			lp.z = ceilZ
			if velL.z > 0 then velL.z = 0 end
			moved = true
		end

		if moved then
			phys:SetPos(veh:LocalToWorld(lp))
		end

		phys:SetVelocity(vehVel + localToWorldVec(veh, velL))
	end
end

local SKIP_PROP = {
	prop_vehicle_prisoner_pod = true,
	lvs_wheeldrive_wheel = true,
	lvs_fighterplane_wheel = true,
	lvs_helicopter_rotor = true,
	lvs_helicopter_engine = true,
}

local function isKeepableProp(ent)
	if not IsValid(ent) then return false end
	if ent.LVS or ent.IsGlideVehicle then return false end
	if ent:IsPlayer() or ent:IsNPC() or ent:IsVehicle() then return false end
	if ent:GetClass() == "prop_ragdoll" then return false end
	local class = ent:GetClass() or ""
	if SKIP_PROP[class] then return false end
	-- Any LVS component (wheels, rotors, armor) from any pack.
	if string.StartWith(class, "lvs_") then return false end

	local parent = ent:GetParent()
	if IsValid(parent) and (parent.LVS or parent:IsVehicle()) and not ent.zc_lvs_keep_weld then
		return false
	end

	local phys = ent:GetPhysicsObject()
	if not IsValid(phys) or not phys:IsMotionEnabled() then return false end

	local maxMass = GetConVar("zc_lvs_keep_props_mass"):GetFloat()
	if phys:GetMass() > maxMass then return false end

	return true
end

local function considerEnt(ent, vehicles)
	if not IsValid(ent) then return end
	if isSeatPassengerRagdoll(ent) then return end

	-- Dragging: still cage closed faces; open door is the way out.
	if isHeld(ent) then
		if IsValid(ent.zc_lvs_keep_veh) then
			kept[ent] = ent.zc_lvs_keep_veh
		end
		return
	end

	local pos = ent:WorldSpaceCenter()
	local filter = { ent }
	local ply = ragOwner(ent)
	if IsValid(ply) then
		filter[#filter + 1] = ply
	end

	local loose = ent:GetClass() == "prop_ragdoll"
	local insideVeh
	if IsValid(ent.zc_lvs_keep_veh) and ZC_LVS.CanKeepCargo(ent.zc_lvs_keep_veh) and inVehicleOBB(ent.zc_lvs_keep_veh, pos, -32) then
		insideVeh = ent.zc_lvs_keep_veh
	else
		for i = 1, #vehicles do
			local veh = vehicles[i]
			if not ZC_LVS.CanKeepCargo(veh) then continue end
			if isInsideInterior(veh, pos, filter, loose) then
				insideVeh = veh
				break
			end
		end
	end

	if not IsValid(insideVeh) then
		detach(ent)
		return
	end

	attach(ent, insideVeh)
end

local function eachKeepable(fn)
	for _, rag in ipairs(ents.FindByClass("prop_ragdoll")) do
		fn(rag)
	end
	if GetConVar("zc_lvs_keep_props"):GetBool() then
		for _, ent in ipairs(ents.FindByClass("prop_physics")) do
			if isKeepableProp(ent) then
				fn(ent)
			end
		end
		for _, ent in ipairs(ents.FindByClass("prop_physics_multiplayer")) do
			if isKeepableProp(ent) then
				fn(ent)
			end
		end
	end
end

timer.Create("zc_lvs_keep_interior_assign", 0.05, 0, function()
	if not ZC_LVS.Enabled() then return end
	if not GetConVar("zc_lvs_keep_interior"):GetBool() then return end

	local vehicles = getLVSVehicles()
	if #vehicles == 0 then return end

	eachKeepable(function(ent)
		considerEnt(ent, vehicles)
	end)
end)

hook.Add("Think", "zc_lvs_keep_interior", function()
	if not ZC_LVS.Enabled() then return end
	if not GetConVar("zc_lvs_keep_interior"):GetBool() then return end

	for ent, veh in pairs(kept) do
		if not IsValid(ent) or not IsValid(veh) or isHeld(ent) then
			detach(ent)
		else
			clampInside(ent, veh)
		end
	end
end)

hook.Add("PhysgunPickup", "zc_lvs_keep_interior", function(ply, ent)
	-- Keep the cage. Closed doors still block; open door lets them out.
	if IsValid(ent) and IsValid(ent.zc_lvs_keep_veh) then
		kept[ent] = ent.zc_lvs_keep_veh
	end
end)

hook.Add("EntityRemoved", "zc_lvs_keep_interior", function(ent)
	if not ent.LVS then return end
	eachKeepable(function(other)
		if other.zc_lvs_keep_veh == ent then
			detach(other)
		end
	end)
end)

local function anyDoorOpen(veh)
	if not ZC_LVS.VehicleHasDoors(veh) then return true end
	if not isfunction(veh.GetDoorHandlers) then return true end
	for _, door in ipairs(veh:GetDoorHandlers()) do
		if IsValid(door) and door.IsOpen and door:IsOpen() then
			return true
		end
	end
	return false
end

-- E on a body/item at an open door pulls it out of the cargo.
hook.Add("PlayerUse", "zc_lvs_unload_kept", function(ply, ent)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ply) or not IsValid(ent) then return end
	if ply:InVehicle() or IsValid(ply.zc_lvs_cargo) then return end

	local veh = ZC_LVS.GetKeptVehicle(ent)
	if not IsValid(veh) then return end
	if ply.FakeRagdoll == ent then return end
	if ply:GetPos():DistToSqr(ent:WorldSpaceCenter()) > 150 * 150 then return end

	local atDoor = ZC_LVS.IsInOpenDoorway(veh, ply:GetPos()) or ZC_LVS.IsAtRear(ply, veh)
	if not atDoor then return end

	if not anyDoorOpen(veh) then
		if ply.Notify then
			ply:Notify("Open the door.", 3)
		end
		return false
	end

	if ZC_LVS.UnloadKept(ent, veh) then
		if ply.Notify then
			ply:Notify("Unloaded.", 2)
		end
		return false
	end
end)
