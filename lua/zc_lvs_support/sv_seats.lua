-- [Z-CITY] LVS SUPPORT
-- Author: Oppai

ZC_LVS = ZC_LVS or {}

-- Parent/weld only. OBB/dist matched leftover corpses inside a tank and
-- blocked the next sit (Sherman one-shot).
-- Open-car dummy: parented to the hull after freeze, or still bound via follow.
local function ragStillInVehicle(rag, veh, pod)
	if not IsValid(rag) then return false end
	if rag.zc_lvs_car_fake and rag.zc_lvs_follow == veh then
		return true
	end
	local par = rag:GetParent()
	if IsValid(par) and (par == veh or par == pod) then
		return true
	end
	if rag.welds then return true end
	return false
end

-- ZC welds CallOnRemove РІвЂ вЂ™ ExitVehicle. Keep removingwelds true past this
-- call: constraint Remove can fire the callback a tick later.
-- hold=true: stay blocked while seated.
-- keepParent=true: air/tank РІР‚вЂќ weld off so the hull does not torque, parent stays.
local function dropSeatWelds(rag, hold, keepParent)
	if not IsValid(rag) then return end
	rag.removingwelds = true
	-- Pelvis anchor offset dies with the seat: nothing holds the body
	-- to the hull after this.
	rag.zc_lvs_anchor_local = nil
	if rag.welds then
		for _, weld in pairs(rag.welds) do
			if IsValid(weld) then
				weld:Remove()
			end
		end
		rag.welds = nil
	end
	if not keepParent then
		rag:SetParent(NULL)
	end
	if hold then
		return
	end
	timer.Simple(0.25, function()
		if IsValid(rag) then
			rag.removingwelds = nil
		end
	end)
end

-- Motion off, collisions off, no parent, no weld.
-- Collisions-on was shoving the player out of helis/trucks/planes.
-- Parent-to-pod physics-deleted gunner vehicles.
-- ZC copies ~player mass onto every ragdoll bone. Welded to LVS that is
-- a tonne on the chassis: cars crawl, helis tip over.
-- ZC welds pelvis + thighs + calves to the chassis (Glide). Those bones
-- must keep motion or the weld does not ride (clip 18.11: dummy on grass).
local WELD_BONES = {
	["ValveBiped.Bip01_Pelvis"] = true,
	["ValveBiped.Bip01_L_Thigh"] = true,
	["ValveBiped.Bip01_R_Thigh"] = true,
	["ValveBiped.Bip01_R_Calf"] = true,
	["ValveBiped.Bip01_L_Calf"] = true,
}

-- Car fake body (restored 07.10): the months-tested car version — freeze
-- every bone except the welded pelvis/legs, gravity off, mass 0.15. The
-- "live body" experiment (motion on, gravity off) made the fake float,
-- fly around and slam into the hull on exit (otrub). The arms you SEE in
-- cars are the ZC camera viewmodel, not ragdoll bones — the camera matrix
-- (mode=zc) draws them; the body only needs to sit and take damage.
-- M113 passengers ride this exact path now (Oppai: "take the working car
-- code and put it on the M113 passengers").
local function lightenCarFake(rag)
	if not IsValid(rag) then return end
	rag.zc_lvs_light = true
	rag.removingwelds = true
	rag:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		if not IsValid(phys) then continue end
		phys:EnableCollisions(false)
		phys:EnableGravity(false)
		phys:EnableDrag(false)
		phys:SetMass(0.15)
		local bone = rag:TranslatePhysBoneToBone(i)
		local name = bone and bone >= 0 and rag:GetBoneName(bone)
		if not (name and WELD_BONES[name]) then
			phys:EnableMotion(false)
		end
	end
end

local function lightenSeatFake(rag)
	if not IsValid(rag) then return end
	rag.zc_lvs_light = true
	rag.removingwelds = true
	rag:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	-- Same tested car rule: frozen bones, gravity off (the live-body
	-- experiment floated and slammed the body — see lightenCarFake).
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		if not IsValid(phys) then continue end
		phys:EnableCollisions(false)
		phys:EnableGravity(false)
		phys:EnableDrag(false)
		phys:EnableMotion(false)
		phys:SetMass(0.15)
		phys:SetVelocity(vector_origin)
		phys:SetAngleVelocity(vector_origin)
	end
end

-- Otrub / corpse: real player weight so they fall and can be dragged out.
local function restoreSeatFakeWeight(rag)
	if not IsValid(rag) then return end
	rag.zc_lvs_light = nil
	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		if not IsValid(phys) then continue end
		phys:EnableGravity(true)
		phys:EnableDrag(true)
		phys:EnableMotion(true)
		phys:EnableCollisions(true)
		phys:SetMass(12)
		phys:Wake()
	end
end

local function occupantIsDown(ply)
	if not IsValid(ply) then return true end
	if not ply:Alive() then return true end
	return ZC_LVS.IsUnconscious(ply)
end

-- In a seat = InVehicle on an LVS pod and this ragdoll is their fake.
local function occupantFromRagdoll(rag)
	if not IsValid(rag) then return NULL end
	local ply
	if hg and hg.RagdollOwner then
		ply = hg.RagdollOwner(rag)
	end
	if not IsValid(ply) and rag.GetNWEntity then
		ply = rag:GetNWEntity("ply")
	end
	if not IsValid(ply) then return NULL end
	if ply.FakeRagdoll ~= rag then return NULL end
	if not ply:InVehicle() then return NULL end
	if not ZC_LVS.IsLVSSeat(ply:GetVehicle()) then return NULL end
	return ply
end

local function ragIsPulled(rag)
	if not IsValid(rag) then return false end
	if rag:IsPlayerHolding() then return true end
	for _, p in player.Iterator() do
		if not IsValid(p) then continue end
		if p.ShadowCarryEnt == rag then return true end
		if p.GetNetVar and (p:GetNetVar("carryent") == rag or p:GetNetVar("carryent2") == rag) then
			return true
		end
	end
	return false
end

-- Grab / Use the dummy: leave the seat, then restore real mass.
local function pullOutOccupant(ply)
	if not IsValid(ply) or not ply:InVehicle() then return end
	if not ZC_LVS.IsLVSSeat(ply:GetVehicle()) then return end
	local rag = ply.FakeRagdoll
	if IsValid(rag) then
		rag.zc_lvs_crash_ejected = true
		dropSeatWelds(rag)
		rag:SetParent(NULL)
	end
	ply.switchingseat = true
	ZC_LVS.AllowExit(ply)
	ply:ExitVehicle()
	local dumped = rag
	timer.Simple(0, function()
		if IsValid(ply) then
			ply.switchingseat = nil
		end
		if IsValid(dumped) then
			restoreSeatFakeWeight(dumped)
		end
	end)
end

-- Physics calls (EnableCollisions etc.) from inside a physics callback
-- throw "Changing collision rules within a callback is likely to cause
-- crashes!" and corrupt the ragdoll — its bones then fly to garbage
-- origins (z=-12245 camera, torn legs on exit). Every ghost/move of a
-- LIVE ragdoll must run deferred (timer.Simple 0), never in Think's
-- post-simulation stack. Ghost/move of a LIVE ragdoll must run deferred.
local function ghostRagdoll(rag, shootable)
	if not IsValid(rag) then return end
	timer.Simple(0, function()
		if not IsValid(rag) then return end
		rag:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			if not IsValid(phys) then continue end
			phys:EnableCollisions(false)
			phys:EnableGravity(false)
			phys:EnableMotion(false)
			phys:EnableDrag(false)
			phys:SetMass(1)
			phys:SetVelocity(vector_origin)
			phys:SetAngleVelocity(vector_origin)
		end
	end)
end

local function isCrazyPos(pos)
	if not isvector(pos) then return true end
	if pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z then return true end
	if math.abs(pos.x) > 16384 or math.abs(pos.y) > 16384 or math.abs(pos.z) > 16384 then return true end
	return false
end

-- Never EnableMotion: one tick of gravity yeets the dummy to z=-23809
-- (engine "Crazy origin" then Removes the ragdoll and the LVS hull).
-- Deferred: same physics-callback rule as ghostRagdoll.
local function moveRagdoll(rag, delta)
	if not IsValid(rag) or not isvector(delta) then return end
	local len = delta:Length()
	if len < 1 then return end
	if len > 512 then
		delta = delta:GetNormalized() * 512
	end
	local d = delta
	timer.Simple(0, function()
		if not IsValid(rag) or not isvector(d) then return end
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			if not IsValid(phys) then continue end
			phys:EnableMotion(false)
			phys:EnableGravity(false)
			local np = phys:GetPos() + d
			if isCrazyPos(np) then continue end
			phys:SetPos(np)
			phys:SetVelocity(vector_origin)
			phys:SetAngleVelocity(vector_origin)
		end
	end)
end

local function ragPelvis(rag)
	if not IsValid(rag) then return vector_origin end
	local b = rag:LookupBone("ValveBiped.Bip01_Pelvis")
	if b then
		local p = rag:GetBonePosition(b)
		if p then return p end
	end
	return rag:WorldSpaceCenter()
end

-- Reforger gunner (Oppai 08.10): where the pack draws its turret
-- mannequin — LocalToWorld(-5,0,-25, turret attachment) for the PELVIS.
-- Returns {pos, ang, localPos} or nil (no turret attachment on hull).
local function turretGunnerSpot(veh)
	if not IsValid(veh) or not veh.LookupAttachment then return nil end
	local id = veh:LookupAttachment("turret")
	if not id or id <= 0 then return nil end
	local att = veh:GetAttachment(id)
	if not istable(att) or not isvector(att.Pos) or not isangle(att.Ang) then return nil end
	if isCrazyPos(att.Pos) then return nil end
	-- Pelvis target: the pack's mannequin formula. Player eyes look
	-- along the turret's forward.
	local pos, _ = LocalToWorld(Vector(-5, 0, -25), angle_zero, att.Pos, att.Ang)
	local localPos, _ = WorldToLocal(pos, angle_zero, veh:GetPos(), veh:GetAngles())
	local ang = att.Ang
	ang = Angle(ang.p, ang.y, 0)
	return { pos = pos, ang = ang, localPos = localPos }
end

-- 2.3.0 car sit, with every bone frozen. Parent AFTER the world pose
-- is copied. Never phys:SetPos while parented (GMod 2026 bomb).
-- Never weld (CallOnRemove ExitVehicle). Think only re-parents / restores
-- entity-local offset РІР‚вЂќ no per-tick bone SetPos (that was BindSeatFake).
local function bindCarFake(rag, veh)
	if not IsValid(rag) or not IsValid(veh) then return end
	lightenCarFake(rag)
	if IsValid(rag:GetParent()) then
		rag:SetParent(NULL)
	end
	local entLocal = veh:WorldToLocal(rag:GetPos())
	local entAng = veh:WorldToLocalAngles(rag:GetAngles())
	if isCrazyPos(veh:LocalToWorld(entLocal)) then return end
	rag:SetParent(veh)
	rag:SetLocalPos(entLocal)
	rag:SetLocalAngles(entAng)
	rag.zc_lvs_follow_local = { ent = entLocal, entang = entAng }
	rag.zc_lvs_follow = veh
	rag.zc_lvs_car_fake = true
	rag.zc_lvs_seat_parent = veh
	-- Hitbox rides the hull even if ragdoll bones stay in the world.
	local pelvis = ragPelvis(rag)
	if isvector(pelvis) and not isCrazyPos(pelvis) then
		rag.zc_lvs_hit_local = veh:WorldToLocal(pelvis)
	else
		rag.zc_lvs_hit_local = entLocal
	end
	if rag.SetNWBool then
		rag:SetNWBool("zc_lvs_car_fake", true)
	end
	do
		local owner = rag.GetNWEntity and rag:GetNWEntity("ply") or NULL
		if not IsValid(owner) then
			for _, p in player.Iterator() do
				if p.FakeRagdoll == rag then
					owner = p
					break
				end
			end
		end
		if IsValid(owner) and isvector(rag.zc_lvs_hit_local) then
			owner:SetNWBool("zc_lvs_has_car_eye", true)
			owner:SetNWVector("zc_lvs_car_eye", rag.zc_lvs_hit_local + Vector(0, 0, 28))
		end
	end
	rag:SetNoDraw(false)
	if rag.DrawShadow then
		rag:DrawShadow(true)
	end
	if rag.SetRenderMode then
		rag:SetRenderMode(RENDERMODE_NORMAL)
	end
end

local function keepCarFake(rag, veh)
	if not IsValid(rag) or not IsValid(veh) then return end
	if rag:GetParent() ~= veh then
		rag:SetParent(veh)
	end
	local loc = rag.zc_lvs_follow_local
	if not loc or not isvector(loc.ent) then return end
	local lp = rag:GetLocalPos()
	if not isvector(lp) or lp:DistToSqr(loc.ent) > 36 * 36 then
		rag:SetLocalPos(loc.ent)
		rag:SetLocalAngles(loc.entang or angle_zero)
	end
end

local function cabinSitPos(veh, pod)
	if not IsValid(veh) then
		return IsValid(pod) and pod:GetPos() or vector_origin
	end
	local src = IsValid(pod) and pod:GetPos() or veh:WorldSpaceCenter()
	local lp = veh:WorldToLocal(src)
	local c = veh:WorldToLocal(veh:WorldSpaceCenter())
	lp.z = c.z - 6
	return veh:LocalToWorld(lp)
end

-- One-time. Do not follow every tick.
local function sinkHatchIntoCabin(rag, pod, veh)
	if not IsValid(rag) or not IsValid(veh) then return end
	local dest = cabinSitPos(veh, pod)
	local pelvis = ragPelvis(rag)
	if isCrazyPos(pelvis) or isCrazyPos(dest) then return end
	local par = rag:GetParent()
	if IsValid(par) then
		rag:SetParent(NULL)
	end
	moveRagdoll(rag, dest - ragPelvis(rag))
	if IsValid(par) then
		rag:SetParent(par)
	elseif IsValid(veh) then
		rag:SetParent(veh)
	end
end

local function ReleaseSeatFake(rag)
	if not IsValid(rag) then return end
	rag.zc_lvs_follow = nil
	rag.zc_lvs_follow_local = nil
	rag.zc_lvs_seatfake = nil
	rag.zc_lvs_car_fake = nil
	rag.zc_lvs_closed_fake = nil
	rag.zc_lvs_gun_to_local = nil
	rag.zc_lvs_gun_from_local = nil
	rag.zc_lvs_gunlerp = nil
	rag.zc_lvs_gun_start_pos = nil
	rag.zc_lvs_gun_detached = nil
	rag.zc_lvs_down_freed = nil
	if rag.SetNWBool then
		rag:SetNWBool("zc_lvs_car_fake", false)
	end
	rag:SetParent(NULL)
	timer.Simple(0.25, function()
		if IsValid(rag) then
			rag.removingwelds = nil
		end
	end)
end

-- Hatch pod sits on the roof. Hide the fake so others don't see a
-- body on the turret and bullets don't hit it. Organism still gets
-- crash/fire/pen from sv_organism.
local function hideClosedRagdoll(rag)
	if not IsValid(rag) then return end
	ghostRagdoll(rag)
	rag:SetNoDraw(true)
	rag:DrawShadow(false)
	rag:SetSolid(SOLID_NONE)
	rag:SetCollisionGroup(COLLISION_GROUP_WORLD)
	if rag.SetRenderMode then
		rag:SetRenderMode(RENDERMODE_NONE)
	end
	rag.zc_lvs_closed_hide = true
end

local function showClosedRagdoll(rag)
	if not IsValid(rag) or not rag.zc_lvs_closed_hide then return end
	rag.zc_lvs_closed_hide = nil
	rag:SetNoDraw(false)
	rag:DrawShadow(true)
	rag:SetSolid(SOLID_VPHYSICS)
	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	if rag.SetRenderMode then
		rag:SetRenderMode(RENDERMODE_NORMAL)
	end
end

function ZC_LVS.MarkSeatSwitch(ply)
	if not IsValid(ply) then return end
	ply.switchingseat = true
	ZC_LVS.AllowExit(ply, 1.2)
	ply.zc_lvs_switch_until = CurTime() + 1.2
	ply.lastswitched = CurTime() + 1.5
	timer.Create("zc_lvs_switchflag" .. ply:EntIndex(), 1.2, 1, function()
		if IsValid(ply) then
			ply.switchingseat = nil
		end
	end)
end

local function isSeatSwitch(ply)
	if not IsValid(ply) then return false end
	if ply.switchingseat then return true end
	if ply.zc_lvs_switch_until and ply.zc_lvs_switch_until > CurTime() then return true end
	if ply.lastswitched and ply.lastswitched > CurTime() then return true end
	return false
end

-- FakeUp cannot run while InVehicle (it returns, or ExitVehicle's the new seat).
-- Drop the old fake so hg.Fake can copy the NEW sit pose.
local function discardSeatRagdoll(ply)
	local rag = ply.FakeRagdoll
	if not IsValid(rag) then
		ply.FakeRagdoll = nil
		if ply.SetNWEntity then
			ply:SetNWEntity("FakeRagdoll", NULL)
		end
		return
	end
	rag.zc_lvs_follow = nil
	rag.zc_lvs_follow_local = nil
	rag.zc_lvs_seatfake = nil
	rag.zc_lvs_car_fake = nil
	rag.zc_lvs_gun_to_local = nil
	rag.zc_lvs_gun_from_local = nil
	rag.zc_lvs_gunlerp = nil
	rag.zc_lvs_gun_start_pos = nil
	rag.zc_lvs_gun_detached = nil
	rag.zc_lvs_closed_fake = nil
	rag.zc_lvs_down_freed = nil
	if rag.SetNWBool then
		rag:SetNWBool("zc_lvs_car_fake", false)
	end
	dropSeatWelds(rag)
	ply.FakeRagdoll = nil
	if ply.SetNWEntity then
		ply:SetNWEntity("FakeRagdoll", NULL)
	end
	rag.override = true
	rag:Remove()
end

local function clearPodLeftovers(pod)
	if not IsValid(pod) then return end
	local chassis = ZC_LVS.GetChassis(pod)
	for _, ply in player.Iterator() do
		if ply:InVehicle() then continue end
		if ZC_LVS.IsUnconscious(ply) then continue end
		local rag = ply.FakeRagdoll
		if not IsValid(rag) then continue end
		local par = rag:GetParent()
		if par == pod or par == chassis or rag.zc_lvs_closed_hide or rag.zc_lvs_seatfake then
			discardSeatRagdoll(ply)
		end
	end
end

-- After leave/delete: leftover FakeRagdoll + noclip. Player looks like
-- they walk but cannot Use a seat until they FakeUp for real.
local function restoreWalk(ply)
	if not IsValid(ply) or ply:InVehicle() then return end
	if ply:GetMoveType() == MOVETYPE_NOCLIP or ply:GetMoveType() == MOVETYPE_NONE then
		ply:SetMoveType(MOVETYPE_WALK)
	end
	ply:SetCollisionGroup(COLLISION_GROUP_PLAYER)
	ply:SetNoDraw(false)
	if ply.DrawShadow then
		ply:DrawShadow(true)
	end
end

local function standAfterVehicle(ply)
	if not IsValid(ply) or ply:InVehicle() then return false end
	if isSeatSwitch(ply) then return false end
	-- Crash eject: stay a ragdoll. FakeUp here is why "Р Р†РЎвЂ№Р В»Р ВµРЎвЂљ Р Р…Р Вµ РЎР‚Р В°Р В±Р С•РЎвЂљР В°Р ВµРЎвЂљ".
	if ply.zc_lvs_ejecting and ply.zc_lvs_ejecting > CurTime() then
		return false
	end
	local rag = ply.FakeRagdoll
	if not IsValid(rag) then
		restoreWalk(ply)
		return false
	end
	-- Real otrub: stay a ragdoll. Do not FakeUp a knocked-out player.
	if ZC_LVS.IsUnconscious(ply) then
		return false
	end
	rag.removingwelds = true
	if hg and isfunction(hg.FakeUp) then
		hg.FakeUp(ply, true, true)
	else
		discardSeatRagdoll(ply)
	end
	timer.Simple(0, function()
		if not IsValid(ply) or ply:InVehicle() then return end
		if IsValid(ply.FakeRagdoll) and not ZC_LVS.IsUnconscious(ply) then
			discardSeatRagdoll(ply)
		end
		if not IsValid(ply.FakeRagdoll) then
			restoreWalk(ply)
		end
	end)
	return true
end

-- Standing leftover fake from the last leave: dump it so we can sit again.
local function unstickSeatFake(ply)
	return standAfterVehicle(ply)
end

local function isOpenCarSeat(ply, pod)
	local veh = ZC_LVS.GetChassis(pod)
	if not IsValid(veh) or not ZC_LVS.IsCar(veh) then return false end
	if ZC_LVS.IsClosedVehicle(veh) then return false end
	if ZC_LVS.IsTurretSeat(ply) or ZC_LVS.IsRoofSeat(pod, veh) then return false end
	if ZC_LVS.PodHidesPlayer(pod) then return false end
	return true
end

-- Glide crutch: ZC Fake parents AND welds the dummy to the chassis.
-- Clip 18.11.17: parent without weld РІР‚вЂќ sit OK, camera stays on the grass.
-- CallOnRemove ExitVehicle is blocked by removingwelds + the belt.
local fakeOpenCarGuard = false

local function fakeOpenCar(ply, pod, veh)
	-- Car flag ONLY on real open-car seats (fix 08.10): this helper was
	-- reused for tank/gunner/air "zc" seats, and zc_lvs_car_fake=true there
	-- leaked into the car branches of Think (weld-keeping, otrub freeze)
	-- — the tank gunner dummy was treated as a car body. fakeHatchCar
	-- lifts the guard: a roof MG on an open car IS a car seat.
	if not (fakeOpenCarGuard or isOpenCarSeat(ply, pod)) then
		return false
	end
	local keepAng = ply:EyeAngles()
	if ply:GetMoveType() == MOVETYPE_NONE then
		ply:SetMoveType(MOVETYPE_WALK)
	end
	local emeta = FindMetaTable("Entity")
	local oldEntSetPos = emeta and emeta.SetPos
	local oldEntSetLocal = emeta and emeta.SetLocalOrigin
	if oldEntSetPos then
		emeta.SetPos = function(self, pos, ...)
			if self == ply then return end
			return oldEntSetPos(self, pos, ...)
		end
	end
	if oldEntSetLocal then
		emeta.SetLocalOrigin = function(self, pos, ...)
			if self == ply then return end
			return oldEntSetLocal(self, pos, ...)
		end
	end
	local ok, err = pcall(function()
		hg.Fake(ply, nil, nil, true)
	end)
	if oldEntSetPos then emeta.SetPos = oldEntSetPos end
	if oldEntSetLocal then emeta.SetLocalOrigin = oldEntSetLocal end
	if not ok then
		ErrorNoHalt("[zc_lvs] Fake car: ", err, "\n")
	end
	if IsValid(ply) then
		ply:SetEyeAngles(keepAng)
		ply:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	end
	local rag = ply.FakeRagdoll
	if not IsValid(rag) then
		return false
	end
	-- Keep ZC welds. Snap must not ExitVehicle.
	-- LIVE fake (Oppai 06.10): lightenCarFake froze every bone except
	-- pelvis/legs — hands/head dead, "a doll in a pod". The ZC controller
	-- drives arms through bone physics, so nothing may be frozen. The
	-- pelvis weld holds the seat; damage works as before.
	rag.removingwelds = true
	rag:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	rag.zc_lvs_seat_parent = veh
	rag.zc_lvs_car_fake = true
	-- CRUSH FIX (Oppai 09.10, "разорвало на части" proven by dmg_probe):
	-- COLLISION_GROUP_IN_VEHICLE does NOT stop fake↔own-hull contacts on
	-- GMod 2026 (the log showed 50-100 DMG_CRUSH from ses_uaz452/world on
	-- a conscious driver). Disable per-bone collisions entirely while
	-- seated — the weld holds the pose, bullets are traced (not collided),
	-- explosions are radius damage. Restored on exit (see
	-- restoreSeatFakeWeight / pullOut paths).
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		if IsValid(phys) then
			phys:EnableCollisions(false)
		end
	end
	local pelvis = ragPelvis(rag)
	if isvector(pelvis) and not isCrazyPos(pelvis) then
		rag.zc_lvs_hit_local = veh:WorldToLocal(pelvis)
	end
	-- Pelvis seat offset (07.10): the frozen car body + ZC welds hold the
	-- seat (restored car code); this offset is ONLY the rescue target for
	-- the crazy-origin guard in Think. No spring — it fought the welds.
	if isvector(pelvis) and not isCrazyPos(pelvis) and IsValid(veh) then
		local seatLocal = ZC_LVS.FakeSeatLocal(ply, pod, veh)
		if seatLocal then
			rag.zc_lvs_anchor_local = veh:WorldToLocal(pelvis)
		end
	end
	if rag.SetNWBool then
		rag:SetNWBool("zc_lvs_car_fake", true)
	end
	rag:SetNoDraw(false)
	if not rag._zc_lvs_bound_print then
		rag._zc_lvs_bound_print = true
		print("[zc_lvs] car fake ", IsValid(veh) and veh:GetClass() or "?")
	end
	return true
end

-- Hatch/gun on a car (BRDM): same Fake as the driver, then drop the dummy
-- into the hull once. Camera stays ZC until RMB (wrapCalcViewFake).
-- hg.Fake for non-car seats (zc camera, vanilla camera): same guards as
-- fakeOpenCar — hg.Fake calls Entity:SetPos/SetLocalOrigin on the seated
-- player and prisoner_pod treats that as local (Bad SetLocalOrigin z≈-22000,
-- dummy on the roof, see the persistent SetPos wrap below). Suppress it
-- for the player during the call, keep his look angle.
local function fakeZCSeatCall(ply)
	local keepAng = ply:EyeAngles()
	if ply:GetMoveType() == MOVETYPE_NONE then
		ply:SetMoveType(MOVETYPE_WALK)
	end
	local emeta = FindMetaTable("Entity")
	local oldEntSetPos = emeta and emeta.SetPos
	local oldEntSetLocal = emeta and emeta.SetLocalOrigin
	if oldEntSetPos then
		emeta.SetPos = function(self, pos, ...)
			if self == ply then return end
			return oldEntSetPos(self, pos, ...)
		end
	end
	if oldEntSetLocal then
		emeta.SetLocalOrigin = function(self, pos, ...)
			if self == ply then return end
			return oldEntSetLocal(self, pos, ...)
		end
	end
	local ok, err = pcall(function()
		hg.Fake(ply, nil, nil, true)
	end)
	if oldEntSetPos then emeta.SetPos = oldEntSetPos end
	if oldEntSetLocal then emeta.SetLocalOrigin = oldEntSetLocal end
	if IsValid(ply) then
		ply:SetEyeAngles(keepAng)
		ply:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	end
	return ok, err
end

-- Hatch car (BRDM roof MG): the open-car Fake (welds + live bones) then
-- sink the dummy into the hull once. Called only for IsCar+not closed.
local function fakeHatchCar(ply, pod, veh)
	fakeOpenCarGuard = true
	local ok = fakeOpenCar(ply, pod, veh)
	fakeOpenCarGuard = nil
	if not ok then
		return false
	end
	local rag = ply.FakeRagdoll
	if not IsValid(rag) then
		return false
	end
	local seatLocal = ZC_LVS.FakeSeatLocal(ply, pod, veh)
	if seatLocal then rag:SetPos(veh:LocalToWorld(seatLocal)) end
	sinkHatchIntoCabin(rag, pod, veh)
	lightenCarFake(rag)
	ply:SetNoDraw(true)
	return true
end

local function fakeInSeat(ply, pod)
	if not IsValid(ply) or not ply:Alive() then return false end
	if not ZC_LVS.ShouldFake(ply) then return false end
	-- Matrix (Oppai 06.10): seats without a fake exist — the whole
	-- Abrams has no hatch seat, the M113 driver sits behind armor. No
	-- ragdoll there: vanilla LVS view only, nothing to damage.
	local matrix = ZC_LVS.SeatMatrix(ply, pod)
	if not matrix.fake then
		ZC_LVS.DebugLog("seat_no_fake", "ply=" .. ply:EntIndex(),
			"veh=" .. (ZC_LVS.GetChassis(pod):GetClass() or "?"))
		if IsValid(ply.FakeRagdoll) then
			discardSeatRagdoll(ply)
		end
		return false
	end
	if IsValid(ply.FakeRagdoll) then
		local veh = ZC_LVS.GetVehicle(ply)
		if not IsValid(veh) then
			veh = ZC_LVS.GetChassis(pod)
		end
		if isSeatSwitch(ply) then
			-- Same chassis OBB: the old fake is "still in the vehicle" even
			-- after Alt+digit. Recopy into THIS pod instead of keeping the
			-- previous seat pose (that looked like the switch did nothing).
			ZC_LVS.MarkSeatSwitch(ply)
			ply.zc_lvs_pose_retried = true
			discardSeatRagdoll(ply)
		elseif ragStillInVehicle(ply.FakeRagdoll, veh, pod) then
			return true
		else
			-- Ghost ragdoll outside a large heli: recopy into this seat, do
			-- not ExitVehicle (that left the camera in the cabin last time).
			ZC_LVS.MarkSeatSwitch(ply)
			discardSeatRagdoll(ply)
		end
	end

	local veh = ZC_LVS.GetVehicle(ply)
	if not IsValid(veh) then
		veh = ZC_LVS.GetChassis(pod)
	end
	if not IsValid(veh) then return false end

	if ZC_LVS.IsCar(veh) and not ZC_LVS.IsClosedVehicle(veh) then
		local hatch = ZC_LVS.IsTurretSeat(ply) or ZC_LVS.IsRoofSeat(pod, veh)
		if hatch then
			return fakeHatchCar(ply, pod, veh)
		end
		return fakeOpenCar(ply, pod, veh)
	end

	-- ZC-owned fake (Oppai 08.10, final): for seats whose camera is "zc"
	-- do what the working path (gaz-66 / civilian cars) does — hg.Fake and
	-- almost nothing else. ZC copies the player's bones, welds the pelvis
	-- to the pod, sits the pose every tick and renders the arms. Never
	-- move the ragdoll AFTER the weld (that rips the bones and kills the
	-- arm rendering).
	--
	-- Reforger gunner (Oppai 08.10 "way 2", turret seats pod.HidePlayer):
	-- the body physically crawls from the pod to the turret. Placement is
	-- done by moving the PLAYER before hg.Fake (ZC copies his bones), and
	-- the crawl itself is an interpolated pelvis anchor in Think
	-- (zc_lvs_gunlerp). Player start angle follows the turret so the pack
	-- mannequin spot (LocalToWorld(-5,0,-25, turret att)) is where the
	-- pelvis lands.
	if ZC_LVS.CameraMode(ply) == "zc" then
		local gunnerSpot
		if pod.HidePlayer == true then
			gunnerSpot = turretGunnerSpot(veh)
		end
		if gunnerSpot then
			-- Move the PLAYER first: ZC welds from his bone matrix. The
			-- player origin is at his feet; the pelvis sits ~36 up.
			if not isCrazyPos(gunnerSpot.pos) then
				ply:SetPos(gunnerSpot.pos - Vector(0, 0, 36))
				ply:SetVelocity(vector_origin)
				ply:SetEyeAngles(gunnerSpot.ang)
				ply:GetBoneMatrix(0)
			end
		end
		local rag = ply.FakeRagdoll
		if IsValid(rag) then
			-- Switch or leftover: recopy into THIS seat (hg.Fake re-copies
			-- the player bones into a fresh dummy).
			ZC_LVS.MarkSeatSwitch(ply)
			discardSeatRagdoll(ply)
		end
		-- Same minimal-touch path as the open cars: hg.Fake copies the
		-- player bones, welds the pelvis to the pod, sits the pose every
		-- tick and renders the arms (ZC sv_control). No lighten, no freeze,
		-- no parent.
		local ok, err = fakeZCSeatCall(ply)
		if not ok then
			ErrorNoHalt("[zc_lvs] Fake zc seat: ", err, "\n")
		end
		rag = ply.FakeRagdoll
		if not IsValid(rag) then
			return false
		end
		rag.removingwelds = true
		rag:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
		rag.zc_lvs_closed_fake = true
		rag.zc_lvs_seat_parent = veh
		if gunnerSpot then
			-- Gunner pose (Oppai 08.10, simplified): NO crawl animation —
			-- the spring-crawl made the body float around the M113 ("не
			-- прикреплен к поду и летаю"). Instead: a frozen STANDING body
			-- at the turret spot. The player was already placed at
			-- gunnerSpot.pos before hg.Fake, so the ragdoll spawns standing
			-- there; welds are cut (the turret follow below moves the body
			-- on rotation; a pod weld would fight it) and every bone is
			-- frozen in the standing pose. TPIK arms render from bone
			-- matrices — freezing physics does NOT kill the arms.
			rag.zc_lvs_follow_att = "turret"
			rag.zc_lvs_gun_detached = true
			rag.removingwelds = true
			if rag.welds then
				for _, w in pairs(rag.welds) do
					if IsValid(w) then w:Remove() end
				end
				rag.welds = nil
			end
			for i = 0, rag:GetPhysicsObjectCount() - 1 do
				local phys = rag:GetPhysicsObjectNum(i)
				if IsValid(phys) then
					phys:EnableMotion(false)
					phys:EnableGravity(false)
					phys:EnableCollisions(false)
					phys:SetVelocity(vector_origin)
				end
			end
			rag.zc_lvs_gunlerp = 0
		end
		ply:SetNoDraw(true)
		return true
	end

	-- Vanilla-camera seats (lvs_closed/lvs_gun driver etc.): the fake is
	-- a damage body only; freeze it in place, out of the camera's way.
	if IsValid(ply.FakeRagdoll) then
		ZC_LVS.MarkSeatSwitch(ply)
		discardSeatRagdoll(ply)
	end
	local ok, err = fakeZCSeatCall(ply)
	if not ok then
		ErrorNoHalt("[zc_lvs] Fake closed seat: ", err, "\n")
	end
	local rag = ply.FakeRagdoll
	if not IsValid(rag) then
		return false
	end
	rag:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	rag.removingwelds = true
	rag.zc_lvs_seat_parent = veh
	local seatLocal = ZC_LVS.FakeSeatLocal(ply, pod, veh)
	if seatLocal then rag:SetPos(veh:LocalToWorld(seatLocal)) end
	lightenSeatFake(rag)
	if ZC_LVS.PodHidesPlayer(pod) then
		rag.zc_lvs_follow_att = "turret"
	end
	return true
end

-- Cars: keep ZC parent+weld (Glide). Air/tank: drop welds so the hull
-- does not torque, keep parent.
hook.Add("Ragdoll_Create", "zc_lvs_no_zc_vehicle_bind", function(ply, rag)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ply) or not IsValid(rag) then return end
	local pod = ply.GetVehicle and ply:GetVehicle()
	if isOpenCarSeat(ply, pod) then
		return
	end
	-- ZC-owned seats (cam "zc", 08.10): the ZC welds ARE the seat holder —
	-- cutting them dropped the passenger through the floor (clip 08.10).
	-- Aircraft too (08.10 "фейк везде"): heli/plane bodies ride the same
	-- ZC welds. Only vanilla-camera air seats still drop welds (torque).
	local veh = ZC_LVS.GetChassis(pod)
	if IsValid(veh) and ZC_LVS.CameraMode(ply) == "zc" then
		return
	end
	if not ZC_LVS.IsLVSSeat(pod) then
		local par = rag:GetParent()
		if not (IsValid(par) and par.LVS) then return end
	end
	rag.removingwelds = true
	if rag.welds then
		for _, weld in pairs(rag.welds) do
			if IsValid(weld) then weld:Remove() end
		end
		rag.welds = nil
	end
end)

-- Civilian cars: ZC EnterVehicleRag (Glide). Air/tank/hatch: vanilla LVS.
local function queueFake(ply, pod)
end

-- Run before ZC fake_enterveh: that returns false if veh.rags still has
-- the last sit's dummy (Sherman/heli one-shot enter).
hook.Add("CanPlayerEnterVehicle", "!!!!zc_lvs_enter_check", function(ply, veh)
	if not ZC_LVS.Enabled() then return end
	if not ZC_LVS.IsLVSSeat(veh) then return end
	if ZC_LVS.IsCrashEjected(ply) then return false end
	-- Force seat (radial menu): the forced move already passed server
	-- guards. Let it through every blocker below, then expire the flag.
	local forced = ply.zc_lvs_force_seat and ply.zc_lvs_force_seat > CurTime()
	if forced then
		ZC_LVS.DebugLog("enter_forced", "ply=" .. ply:EntIndex(), "veh=" .. veh:GetClass())
		return
	end
	ZC_LVS.DebugLog("enter_check", "ply=" .. ply:EntIndex(), "veh=" .. veh:GetClass(), "inveh=" .. tostring(ply:InVehicle()), "fake=" .. tostring(IsValid(ply.FakeRagdoll)), "cargo=" .. tostring(IsValid(ply.zc_lvs_cargo)))
	if IsValid(ply.zc_lvs_cargo) then
		ZC_LVS.DebugLog("enter_block_cargo", "ply=" .. ply:EntIndex())
		return false
	end
	-- A player with an active ZC fake is already ragdolled. Do not let the
	-- vehicle's Use/seat code consume E and re-seat the same player.
	if IsValid(ply.FakeRagdoll) then
		ZC_LVS.DebugLog("enter_block_fake", "ply=" .. ply:EntIndex())
		return false
	end
	unstickSeatFake(ply)
	clearPodLeftovers(veh)
	if hg and hg.RemoveDeadBodies then
		hg.RemoveDeadBodies(veh)
	end
	if isSeatSwitch(ply) then return end
	if ply.IsPlayerHolding and ply:IsPlayerHolding() then
		return false
	end
	standAfterVehicle(ply)
	-- Only a real otrub ragdoll blocks enter. Leftover vehicle dummy is dumped.
	if IsValid(ply.FakeRagdoll) and ZC_LVS.IsUnconscious(ply) then
		return false
	end
	if IsValid(ply.FakeRagdoll) then
		discardSeatRagdoll(ply)
		restoreWalk(ply)
	end

	-- A5 (08.10): board a MOVING aircraft. ZC fake_enterveh (below us in
	-- the hook chain) returns false while the chassis moves faster than
	-- 256 u/s — that is right for Glide cars, wrong for a heli that is
	-- taxiing / light on the skids. After our own guards passed, allow the
	-- enter for aircraft so the speed gate never eats it. Hard requirement:
	-- the player is on his feet and not already ragdolled (guards above).
	local chassis = ZC_LVS.GetChassis(veh)
	if IsValid(chassis) and (ZC_LVS.IsAircraft(chassis) or ZC_LVS.IsPlane(chassis)) then
		ZC_LVS.DebugLog("enter_air_moving", "ply=" .. ply:EntIndex(),
			"veh=" .. chassis:GetClass(),
			"speed=" .. string.format("%.0f", chassis:GetVelocity():Length()))
		return true
	end
end)

hook.Add("PlayerEnteredVehicle", "zc_lvs_entered", function(ply, pod, role)
	if not ZC_LVS.Enabled() then return end
	if not ZC_LVS.IsLVSSeat(pod) then return end
	if ZC_LVS.IsCrashEjected(ply) then
		ZC_LVS.AllowExit(ply, 1.5)
		timer.Simple(0, function() if IsValid(ply) and ply:InVehicle() then ply:ExitVehicle() end end)
		return
	end
	-- Force seat move finished: expire the bypass flag right away so a
	-- later E-press on the vehicle goes through the normal blockers.
	ply.zc_lvs_force_seat = nil
	if IsValid(ply.FakeRagdoll) then ply.FakeRagdoll.zc_lvs_no_climb = nil end
	ply:SetNWBool("zc_lvs_ejected", false)

	ply:SetAllowWeaponsInVehicle(true)
	ply:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	ply.zc_lvs_entered = CurTime() + 1.2
	do
		local veh = ZC_LVS.GetChassis(pod)
		if IsValid(veh) and ZC_LVS.IsCar(veh) and not ZC_LVS.IsClosedVehicle(veh) then
			ply:SetNWBool("zc_lvs_has_car_eye", true)
			ply:SetNWVector("zc_lvs_car_eye", veh:WorldToLocal(ZC_LVS.CabinCamPos(pod, veh)))
		end
	end
	-- Hull shove on enter (heli/truck/plane "РЎвЂљР С•Р В»Р С”Р В°Р ВµРЎвЂљ Р Р…Р В°Р В·Р В°Р Т‘").
	local chassis = ZC_LVS.GetChassis(pod)
	if IsValid(chassis) then
		constraint.NoCollide(ply, chassis, 0, 0)
		if IsValid(pod) and pod ~= chassis then
			constraint.NoCollide(ply, pod, 0, 0)
		end
	end
	if ZC_LVS.ShouldBlockZCWeapons(ply) then
		local hands = ply:GetWeapon("weapon_hands_sh")
		if not IsValid(hands) then
			hands = ply:GetWeapon("weapon_hands")
		end
		if IsValid(hands) then
			ply:SetActiveWeapon(hands)
		end
	end
	-- ZC zeros EyeAngles on enter. With fake we restore look after Fake.
	-- Without fake, LVS AlignView to pod-local (0,90,0). Do NOT copy
	-- world keepAng into the pod РІР‚вЂќ that is "gun shoots the wrong way".
	local mode = ZC_LVS.CameraMode(ply)
	if mode ~= "zc" then
		timer.Simple(0, function()
			if not IsValid(ply) or not ply:InVehicle() then return end
			if ZC_LVS.CameraMode(ply) == "zc" then return end
			if IsValid(ply.FakeRagdoll) then return end
			local veh = ZC_LVS.GetVehicle(ply)
			if IsValid(veh) and isfunction(veh.AlignView) then
				veh:AlignView(ply, mode ~= "lvs_air")
			end
		end)
	end

	queueFake(ply, pod)
	timer.Simple(0, function()
		if IsValid(ply) and ply:InVehicle() then
			queueFake(ply, pod)
		end
	end)
	-- Gunner/driver seats must always retain a damage fake, including seats
	-- whose camera is fully owned by LVS. Retry after LVS finishes seat setup.
	-- Fix 08.10: re-read the CURRENT pod in the timer. Alt+digit re-seats
	-- within 0.12s used to fake into the closure's OLD pod (duplicated pose
	-- from the previous seat).
	if not isOpenCarSeat(ply, pod) then
		timer.Simple(0.12, function()
			if not IsValid(ply) or not ply:InVehicle() then return end
			if not ZC_LVS.IsLVSSeat(ply:GetVehicle()) then return end
			if not IsValid(ply.FakeRagdoll) then
				local ok = fakeInSeat(ply, ply:GetVehicle())
				ZC_LVS.DebugLog("seat_fake_retry", "ply=" .. ply:EntIndex(), "ok=" .. tostring(ok), "veh=" .. (IsValid(ZC_LVS.GetVehicle(ply)) and ZC_LVS.GetVehicle(ply):GetClass() or "invalid"))
			end
		end)
	end
	-- Glide car: after ZC Fake, only block weld-snap ExitVehicle. Do not
	-- lighten/freeze РІР‚вЂќ that killed the dummy ride (clip 18.25).
	if isOpenCarSeat(ply, pod) then
		local function rideLog(tag)
			if not IsValid(ply) or not ply:InVehicle() then return end
			local rag = ply.FakeRagdoll
			local veh = ZC_LVS.GetVehicle(ply)
			if not IsValid(rag) then
				print("[zc_lvs] ", tag, " NO FAKE")
				return
			end
			rag.removingwelds = true
			rag.zc_lvs_car_fake = true
			local par = rag:GetParent()
			local nw = 0
			if rag.welds then
				for _, w in pairs(rag.welds) do
					if IsValid(w) then nw = nw + 1 end
				end
			end
			local dist = 0
			if IsValid(veh) then
				dist = math.floor(rag:GetPos():Distance(veh:GetPos()))
			end
			print("[zc_lvs] ", tag, IsValid(veh) and veh:GetClass() or "?",
				" parent=", IsValid(par) and par:GetClass() or "nil",
				" welds=", nw, " dist=", dist)
			-- Sit pose: freeze arms/spine. Do not freeze welded pelvis/legs
			-- (that killed the ride in 2.9.5). Clip 21.51: dummy rode, slumped.
			if tag == "sit" then
				lightenCarFake(rag)
			end
		end
		timer.Simple(0.8, function() rideLog("sit") end)
		timer.Simple(2.5, function() rideLog("drive") end)
	end
end)

hook.Add("LVS.OnPlayerRequestSeatSwitch", "zc_lvs_switch", function(ply, vehicle, oldPod, newPod)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ply) then return end
	local chassis = ZC_LVS.GetChassis(oldPod) or ZC_LVS.GetChassis(newPod)
	if IsValid(chassis) and ZC_LVS.IsOpenCarHull(chassis) then return false end
	ZC_LVS.MarkSeatSwitch(ply)
end)

-- Alt+digit: LVS will ExitVehicle. Mark BEFORE that so ZC FakeUp's
-- instead of yeeting. Never mark a plain 1РІР‚вЂњ0 (weapons) РІР‚вЂќ that used to
-- set lastswitched and block the next real switch.
hook.Add("PlayerButtonDown", "!!!!zc_lvs_mark_seat_switch", function(ply, button)
	if not ZC_LVS.Enabled() then return end
	if not ZC_LVS.WEAPON_KEYS[button] then return end
	if not IsValid(ply) or not ply:InVehicle() then return end
	if not ZC_LVS.IsLVSSeat(ply:GetVehicle()) then return end
	local chassis = ZC_LVS.GetChassis(ply:GetVehicle())
	if IsValid(chassis) and ZC_LVS.IsOpenCarHull(chassis) then return end
	if not ZC_LVS.HoldingAlt(ply) then return end
	ZC_LVS.MarkSeatSwitch(ply)
end)

hook.Add("CanExitVehicle", "zc_lvs_mark_seat_switch", function(veh, ply)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ply) then return end
	if ply.zc_lvs_switch_until and ply.zc_lvs_switch_until > CurTime() then
		ply.switchingseat = true
		-- LVS's own CanExitVehicle returns false while in an LVS vehicle.
		-- Allow the switcher's ExitVehicle through.
		return true
	end
end)

-- Run inside ZC's leave hook so switchingseat is set before FakeUp/yeet.
local function wrapLVSCanExit()
	local hooks = hook.GetTable().CanExitVehicle
	if not hooks or not hooks["!!!lvsCanExitVehicle"] then return end
	if ZC_LVS._wrappedLVSCanExit then return end

	local info = debug.getinfo(hooks["!!!lvsCanExitVehicle"], "S")
	local src = info and (info.short_src or "") or ""
	if string.find(src, "zc_lvs", 1, true) then
		ZC_LVS._wrappedLVSCanExit = true
		return
	end

	ZC_LVS._origLVSCanExit = hooks["!!!lvsCanExitVehicle"]
	ZC_LVS._wrappedLVSCanExit = true
	hook.Add("CanExitVehicle", "!!!lvsCanExitVehicle", function(vehicle, ply)
		if ZC_LVS.Enabled() and IsValid(ply) then
			if ply.switchingseat or (ply.zc_lvs_switch_until and ply.zc_lvs_switch_until > CurTime()) then
				return
			end
		end
		if ZC_LVS._origLVSCanExit then
			return ZC_LVS._origLVSCanExit(vehicle, ply)
		end
	end)
end

local function wrapZCEnter()
	local hooks = hook.GetTable().PlayerEnteredVehicle
	if not hooks or not hooks["allowweapons"] then return end
	if ZC_LVS._origZCEnter then return end
	local info = debug.getinfo(hooks["allowweapons"], "S")
	local src = info and (info.short_src or "") or ""
	if string.find(src, "zc_lvs", 1, true) then return end

	ZC_LVS._origZCEnter = hooks["allowweapons"]
	hook.Add("PlayerEnteredVehicle", "allowweapons", function(ply, veh, role)
		if ZC_LVS.Enabled() and ZC_LVS.IsLVSSeat(veh) then
			local keepAng = IsValid(ply) and ply:EyeAngles() or nil
			local ret = ZC_LVS._origZCEnter(ply, veh, role)
			-- Only stamp world look back when a fake will own the camera.
			-- No-fake tank: pod-local angles, LVS AlignView.
			if keepAng and ZC_LVS.ShouldUseLVSCamera(ply) and ZC_LVS.ShouldFake(ply) then
				ply:SetEyeAngles(keepAng)
			end
			return ret
		end
		return ZC_LVS._origZCEnter(ply, veh, role)
	end)
end

local function wrapZCLeave()
	wrapLVSCanExit()
	wrapZCEnter()
	local hooks = hook.GetTable().PlayerLeaveVehicle
	if not hooks or not hooks["allowweapons"] then return end
	local info = debug.getinfo(hooks["allowweapons"], "S")
	local src = info and (info.short_src or "") or ""
	if string.find(src, "zc_lvs", 1, true) then return end
	if ZC_LVS._origZCLeave then return end

	ZC_LVS._origZCLeave = hooks["allowweapons"]
	hook.Add("PlayerLeaveVehicle", "allowweapons", function(ply, veh)
		if ZC_LVS.Enabled() and ZC_LVS.IsLVSSeat(veh) then
			if ply.zc_lvs_switch_until and ply.zc_lvs_switch_until > CurTime() then
				ply.switchingseat = true
			end
			-- ZC FakeUp on leave is why crash eject stood you up.
			if ply.zc_lvs_ejecting and ply.zc_lvs_ejecting > CurTime() then
				ply:SetAllowWeaponsInVehicle(false)
				if timer.Exists("EnterVehicleRag" .. ply:EntIndex()) then
					timer.Remove("EnterVehicleRag" .. ply:EntIndex())
				end
				return
			end
		end
		return ZC_LVS._origZCLeave(ply, veh)
	end)
end

local function wrapZCLeaveRetry()
	wrapZCLeave()
	ZC_LVS._wrapLeaveTries = (ZC_LVS._wrapLeaveTries or 0) + 1
	if (ZC_LVS._origZCLeave and ZC_LVS._origZCEnter) or ZC_LVS._wrapLeaveTries > 20 then
		timer.Remove("zc_lvs_wrap_zcleave")
	end
end

hook.Add("InitPostEntity", "zc_lvs_wrap_zcleave", function()
	timer.Simple(0, wrapZCLeaveRetry)
	timer.Simple(1, wrapZCLeaveRetry)
	timer.Simple(3, wrapZCLeaveRetry)
end)

timer.Simple(0, wrapZCLeaveRetry)
timer.Create("zc_lvs_wrap_zcleave", 1, 0, wrapZCLeaveRetry)

-- Stay seated, but lose all LVS control while unconscious.
-- In the air there is a chance to fall out of the helicopter.
hook.Add("HG_OnOtrub", "zc_lvs_otrub", function(ply)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ply) then return end

	local veh = ZC_LVS.GetVehicle(ply)
	if not IsValid(veh) then return end
	if ZC_LVS.IsDriver(ply, veh) then
		ZC_LVS.IdleVehicle(veh)
	end

	if not GetConVar("zc_lvs_air_fall"):GetBool() then return end
	if not ZC_LVS.IsAircraft(veh) then return end
	-- Fighter canopy stays shut. Heli-fall does not apply to planes.
	if ZC_LVS.IsPlane(veh) then return end
	if ply.switchingseat then return end
	if not ZC_LVS.IsAirborne(veh) then return end

	-- Chance, not a guaranteed dump. Landed heli keeps you in the seat.
	if math.Rand(0, 1) > 0.72 then return end

	timer.Simple(0.18, function()
		if not IsValid(ply) or not ply:Alive() or not ply:InVehicle() then return end
		if ply.switchingseat then return end
		if not ZC_LVS.IsUnconscious(ply) then return end
		local cur = ZC_LVS.GetVehicle(ply)
		if not IsValid(cur) or not ZC_LVS.IsAircraft(cur) then return end
		if not ZC_LVS.IsAirborne(cur) then return end
		ZC_LVS.HeliFallOut(ply, cur)
	end)
end)

-- A5 (08.10): heli otrub fall-out. ZC_LVS.EjectPlayer is intentionally a
-- no-op (crash ejection disabled — impacts go to sv_organism), but the heli
-- knockout specifically must dump the body (cvar zc_lvs_air_fall, default 1).
-- Sequence is the proven one from the disabled EjectPlayer body: welds off,
-- physics restored, launch with the heli's velocity so the ragdoll falls
-- WITH the machine, plain ExitVehicle, free-fall handled by ZC organism.
function ZC_LVS.HeliFallOut(ply, veh)
	if not IsValid(ply) or not ply:Alive() or not ply:InVehicle() then return end
	if ply.switchingseat then return end

	local rag = ply.FakeRagdoll
	if not IsValid(rag) then
		-- No fake to dump: fall out as the plain player ragdoll via ZC.
		ZC_LVS.AllowExit(ply, 1.5)
		ply:ExitVehicle()
		return
	end

	local vel = IsValid(veh) and veh:GetVelocity() or vector_origin
	local launch = vel * 0.55 + Vector(0, 0, 120)
	if launch:Length() < 120 then
		launch = launch:Length() < 1 and Vector(0, 0, 180) or launch:GetNormalized() * 180
	end

	ply.zc_lvs_ejecting = CurTime() + 2
	ply.zc_lvs_eject_state = "ragdoll_free"
	ply.zc_lvs_cargo = nil
	ply:SetNWEntity("zc_lvs_cargo", NULL)
	rag.zc_lvs_crash_ejected = true
	rag.zc_lvs_car_fake = nil
	rag.zc_lvs_follow = nil
	rag.zc_lvs_follow_local = nil
	rag.zc_lvs_closed_fake = nil
	if rag.SetNWBool then rag:SetNWBool("zc_lvs_car_fake", false) end

	-- Detach FIRST (welds/parent), then give the body back its physics.
	dropSeatWelds(rag)
	rag:SetParent(NULL)

	ZC_LVS.AllowExit(ply, 1.5)
	ply:ExitVehicle()

	-- Deferred physics restore (never inside the leave-stack: the
	-- collision-callback rule, clip 05.10) + the launch impulse.
	timer.Simple(0, function()
		if not IsValid(rag) then return end
		showClosedRagdoll(rag)
		restoreSeatFakeWeight(rag)
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			if IsValid(phys) then
				phys:EnableMotion(true)
				phys:Wake()
				phys:SetVelocity(launch + VectorRand() * 40)
			end
		end
	end)
	ZC_LVS.DebugLog("heli_fallout", "ply=" .. ply:EntIndex(),
		"veh=" .. (IsValid(veh) and veh:GetClass() or "?"),
		"launch=(" .. string.format("%.0f %.0f %.0f", launch.x, launch.y, launch.z) .. ")")
end

-- A5: a fallen-out pilot who SURVIVES the fall and wakes up must be able to
-- board again. zc_lvs_eject_state otherwise sticks until respawn and the
-- enter guard rejects every seat ("вылет не работает" after one fall).
hook.Add("HG_OnWakeOtrub", "zc_lvs_air_fall_wake", function(ply)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ply) then return end
	if ply:InVehicle() then return end
	ply.zc_lvs_eject_state = nil
	local rag = ply.FakeRagdoll
	if IsValid(rag) then
		rag.zc_lvs_crash_ejected = nil
	end
end)

hook.Add("StartCommand", "zc_lvs_otrub_drive", function(ply, cmd)
	if not ZC_LVS.Enabled() then return end
	if not ZC_LVS.IsUnconscious(ply) then return end

	cmd:ClearMovement()

	local veh = ZC_LVS.GetVehicle(ply)
	if IsValid(veh) and ZC_LVS.IsDriver(ply, veh) then
		ZC_LVS.IdleVehicle(veh)
	end
end)

hook.Add("Think", "zc_lvs_otrub_idle", function()
	if not ZC_LVS.Enabled() then return end
	for _, ply in player.Iterator() do
		local veh = ZC_LVS.GetVehicle(ply)
		if not IsValid(veh) or not ZC_LVS.IsDriver(ply, veh) then continue end
		if ZC_LVS.IsUnconscious(ply) then
			ZC_LVS.IdleVehicle(veh)
			veh.zc_lvs_idled = true
		elseif veh.zc_lvs_idled then
			veh.zc_lvs_idled = nil
			ZC_LVS.ReleaseIdleVehicle(veh)
		end
	end
end)

-- Keep mass/hide/hands. Do not SetPos-follow (Crazy origin / hull delete).
hook.Add("Think", "zc_lvs_closed_keep", function()
	if not ZC_LVS.Enabled() then return end
	for _, ply in player.Iterator() do
		if not ply:InVehicle() then continue end
		if ply.switchingseat then continue end
		if ply.zc_lvs_ejecting and ply.zc_lvs_ejecting > CurTime() then continue end
		local veh = ZC_LVS.GetVehicle(ply)
		local cam = ZC_LVS.CameraMode(ply)
		local rag = ply.FakeRagdoll
		if not IsValid(rag) then continue end

		-- Escaped-fake guard (clip 06.10): crazy or far outside — hard
		-- snap back, count it. With the frozen car body + ZC welds this
		-- should never fire; it is a safety net, not a holder.
		if IsValid(veh) and not ZC_LVS.IsAircraft(veh) then
			local pelvis = ragPelvis(rag)
			if isCrazyPos(pelvis) or (isvector(pelvis)
				and pelvis:DistToSqr(veh:WorldSpaceCenter()) > 500 * 500) then
				local seatLocal = ZC_LVS.FakeSeatLocal(ply, ply:GetVehicle(), veh)
				if seatLocal then
					local dest = veh:LocalToWorld(seatLocal)
					local off = ragPelvis(rag)
					if isvector(off) then
						moveRagdoll(rag, dest - off)
					else
						rag:SetPos(dest)
					end
					rag.zc_lvs_anchor_local = veh:WorldToLocal(dest)
					rag.zc_lvs_rescued = (rag.zc_lvs_rescued or 0) + 1
					ZC_LVS.DebugLog("seat_rescue", "ply=" .. ply:EntIndex(),
						"n=" .. tostring(rag.zc_lvs_rescued))
				end
			end
		end

		-- Civilian car AND any zc-camera closed seat (M113 passengers /
		-- gunner, 07.10): ZC owns the dummy completely — its sv_control
		-- shadowControl sits the pose every tick, its welds hold the pod.
		-- We must not lighten/freeze/re-parent it, or the pose dies
		-- ("doll in a pod").
		if isOpenCarSeat(ply, ply:GetVehicle()) or (cam == "zc" and rag.zc_lvs_closed_fake) then
			-- FIX 08.10 (отрубленного нельзя вытащить): the old branch
			-- continued BEFORE ragIsPulled/occupantIsDown, so a knocked-out
			-- or dead occupant stayed weightless forever — nobody could
			-- grab and drag them out of the wreck. Check the pull/down
			-- state FIRST; only a conscious occupant keeps the held pose.
			if ragIsPulled(rag) then
				pullOutOccupant(ply)
				continue
			end
			if occupantIsDown(ply) then
				-- Real weight + physics so the body can be dragged out or
				-- fall out through an open ramp/door on a crash. Drop the
				-- seat welds once (a welded 0.15-mass corpse cannot fall).
				-- No SetPos, no freeze — the body keeps its current pose.
				-- Physics restore is deferred (same rule as
				-- pullOutOccupant): otrub can fire from a damage stack.
				if not rag.zc_lvs_down_freed then
					rag.zc_lvs_down_freed = true
					dropSeatWelds(rag, true, true)
					rag:SetParent(NULL)
					local dump = rag
					timer.Simple(0, function()
						if IsValid(dump) then
							restoreSeatFakeWeight(dump)
						end
					end)
				end
				continue
			end
			if rag.zc_lvs_down_freed then
				rag.zc_lvs_down_freed = nil
			end
			-- Gunner turret follow (Oppai 08.10, frozen-body variant): the
			-- gunner fake is a FROZEN standing body. Every tick we also KILL
			-- bone velocities: ZC sv_control keeps writing speeds into frozen
			-- bones; they accumulate (5000+ u/s) and the moment anything wakes
			-- the body it detonates — "Crazy origin", engine Remove, ZC
			-- suicide (clip 08.10). moveRagdoll on turret rotation only.
			if rag.zc_lvs_follow_att and IsValid(veh) and veh.LookupAttachment then
				for i = 0, rag:GetPhysicsObjectCount() - 1 do
					local phys = rag:GetPhysicsObjectNum(i)
					if IsValid(phys) and phys:IsAsleep() == false then
						phys:SetVelocity(vector_origin)
						phys:SetAngleVelocity(vector_origin)
					end
				end
				local id = veh:LookupAttachment(rag.zc_lvs_follow_att)
				if id and id > 0 then
					local att = veh:GetAttachment(id)
					if att and isvector(att.Pos) and not isCrazyPos(att.Pos) and isangle(att.Ang) then
						local last = rag.zc_lvs_att_pos
						if not (isvector(last) and last:DistToSqr(att.Pos) < 4) then
							rag.zc_lvs_att_pos = att.Pos
							local dest, _ = LocalToWorld(Vector(-5, 0, -25), angle_zero, att.Pos, att.Ang)
							if not isCrazyPos(dest) then
								local pelvis = ragPelvis(rag)
								if isvector(pelvis) and not isCrazyPos(pelvis) then
									moveRagdoll(rag, dest - pelvis)
								else
									rag:SetPos(dest)
								end
							end
						end
					end
				end
			end
			rag.removingwelds = true
			continue
		end

		if ragIsPulled(rag) then
			pullOutOccupant(ply)
			continue
		end

		if occupantIsDown(ply) then
			if ZC_LVS.IsAircraft(veh) then
				lightenSeatFake(rag)
			elseif rag.zc_lvs_car_fake then
				-- Frozen in the seat until someone pulls. Motion-on while
				-- parented is the Crazy-origin path.
				if not rag.zc_lvs_light then
					lightenCarFake(rag)
				end
			elseif rag.zc_lvs_light then
				restoreSeatFakeWeight(rag)
			end
		else
			if isOpenCarSeat(ply, ply:GetVehicle()) then
				if not rag.zc_lvs_light then
					lightenCarFake(rag)
				end
			else
				lightenSeatFake(rag)
			end
		end
		-- Glide car: never re-parent to the pod (that left dummy on the grass).
		if isOpenCarSeat(ply, ply:GetVehicle()) or rag.zc_lvs_car_fake then
			rag.removingwelds = true
		else
			local seat = rag.zc_lvs_seat_parent
			if not IsValid(seat) then
				seat = ply:GetVehicle()
			end
			if IsValid(seat) and rag:GetParent() ~= seat then
				rag:SetParent(seat)
			end
		end

		if ZC_LVS.ShouldBlockZCWeapons(ply) then
			local wep = ply:GetActiveWeapon()
			if IsValid(wep) then
				local c = wep:GetClass()
				if c ~= "weapon_hands_sh" and c ~= "weapon_hands" then
					local hands = ply:GetWeapon("weapon_hands_sh")
					if not IsValid(hands) then
						hands = ply:GetWeapon("weapon_hands")
					end
					if IsValid(hands) then
						ply:SetActiveWeapon(hands)
					end
				end
			end
		end

		if ZC_LVS.IsClosedVehicle(veh) or (ZC_LVS.PodHidesPlayer(ply:GetVehicle()) and not ZC_LVS.IsCar(veh)) then
			-- The fake stays VISIBLE and LIVE (rule 06.10: damage body +
			-- ZC camera; ghosting froze it into a "doll in a pod"). Only
			-- un-ghost a formerly hidden one.
			if rag.zc_lvs_closed_hide then
				showClosedRagdoll(rag)
			end
			-- Follow the turret attachment: packs rotate the turret via
			-- pose parameters, so a one-time SetPos left the fake frozen
			-- mid-air (clip 04.10). Ride the attachment; moveRagdoll defers
			-- the physics itself (collision-callback crash, clip 05.10).
			-- Throttle: only re-move when the turret actually moved.
			if rag.zc_lvs_follow_att and IsValid(veh) and veh.LookupAttachment then
				local id = veh:LookupAttachment(rag.zc_lvs_follow_att)
				if id and id > 0 then
					local att = veh:GetAttachment(id)
					if att and isvector(att.Pos) and not isCrazyPos(att.Pos) and isangle(att.Ang) then
						local last = rag.zc_lvs_att_pos
						if not (isvector(last) and last:DistToSqr(att.Pos) < 4) then
							rag.zc_lvs_att_pos = att.Pos
							-- Same formula as the pack's DrawGunner:
							-- LocalToWorld(-5,0,-25, turret attachment).
							local dest, _ = LocalToWorld(Vector(-5, 0, -25), angle_zero, att.Pos, att.Ang)
							if not isCrazyPos(dest) then
								local pelvis = ragPelvis(rag)
								if not isCrazyPos(pelvis) then
									moveRagdoll(rag, dest - pelvis)
								else
									rag:SetPos(dest)
								end
							end
						end
					end
				end
			end
			ply:SetNoDraw(true)
		else
			if rag.zc_lvs_closed_hide then
				showClosedRagdoll(rag)
			end
			if rag.zc_lvs_closed_fake then
				rag.zc_lvs_closed_fake = nil
			end
			local hatch = ZC_LVS.IsTurretSeat(ply) or ZC_LVS.IsRoofSeat(ply:GetVehicle(), veh)
			if hatch or cam ~= "zc" or ZC_LVS.IsClosedVehicle(veh) then
				ply:SetNoDraw(true)
			elseif ply:GetNoDraw() then
				ply:SetNoDraw(false)
			end
		end
	end
end)

-- Pupils follow look. Do not shadow-control the skull: that twists the
-- local first-person camera into the face.
-- A5 (08.10): throttled to 10Hz — SetEyeTarget is a networked eye vector,
-- per-tick updates over all players were wasted bandwidth.
local zc_svHeadlookNext = 0
hook.Add("Think", "zc_lvs_air_headlook", function()
	if not ZC_LVS.Enabled() then return end
	if CurTime() < zc_svHeadlookNext then return end
	zc_svHeadlookNext = CurTime() + 0.1

	for _, ply in player.Iterator() do
		if not ZC_LVS.ShouldUseLVSCamera(ply) then continue end
		if ZC_LVS.IsUnconscious(ply) then continue end

		local rag = ply.FakeRagdoll
		if not IsValid(rag) then continue end

		local look = ply:EyeAngles()
		look.r = 0
		rag:SetEyeTarget(look:Forward() * 10000)
	end
end)

hook.Add("PlayerLeaveVehicle", "zc_lvs_leave", function(ply, pod)
	if not ZC_LVS.Enabled() then return end
	if not ZC_LVS.IsLVSSeat(pod) then return end

	if timer.Exists("EnterVehicleRag" .. ply:EntIndex()) then
		timer.Remove("EnterVehicleRag" .. ply:EntIndex())
	end
	if timer.Exists("zc_lvs_fake" .. ply:EntIndex()) then
		timer.Remove("zc_lvs_fake" .. ply:EntIndex())
	end
	ply.zc_lvs_pose_retried = nil
	ply:SetNWBool("zc_lvs_has_car_eye", false)
	ply:SetNoDraw(false)
	local rag = ply.FakeRagdoll
	local function scrubRags(ent)
		if not IsValid(ent) or not istable(ent.rags) then return end
		for i = #ent.rags, 1, -1 do
			local r = ent.rags[i]
			if not IsValid(r) or r == rag then
				table.remove(ent.rags, i)
			end
		end
	end
	scrubRags(pod)
	scrubRags(ZC_LVS.GetChassis(pod))
	if IsValid(rag) then
		ReleaseSeatFake(rag)
		rag.zc_lvs_follow_att = nil
		rag.zc_lvs_att_pos = nil
		if not ply.switchingseat then
			local ejecting = ply.zc_lvs_ejecting and ply.zc_lvs_ejecting > CurTime()
			if not ejecting then
				-- The turret-following fake was frozen mid-air next to the
				-- armor. Re-enabling collisions IN the leave hook made the
				-- hull eject it with blast force — legs amputated on every
				-- exit (clip 05.10). Restore physics DEFERRED and only after
				-- dropping the ghost state, so the ragdoll settles instead
				-- of exploding.
				-- Kill the anchor spring velocity FIRST (clip 07.10): the
				-- spring (delta*8) left the pelvis moving; turning collisions
				-- on with that speed slammed the body into the hull → damage
				-- → otrub on exit. Zero every bone before physics returns.
				rag.zc_lvs_anchor_local = nil
				for i = 0, rag:GetPhysicsObjectCount() - 1 do
					local phys = rag:GetPhysicsObjectNum(i)
					if IsValid(phys) then
						phys:SetVelocity(vector_origin)
						phys:SetAngleVelocity(vector_origin)
					end
				end
				timer.Simple(0, function()
					if not IsValid(rag) then return end
					showClosedRagdoll(rag)
					timer.Simple(0, function()
						if not IsValid(rag) then return end
						restoreSeatFakeWeight(rag)
					end)
				end)
				timer.Simple(0, function()
					if IsValid(ply) then
						standAfterVehicle(ply)
					end
				end)
			end
		end
	else
		restoreWalk(ply)
	end
	-- Do not clear switchingseat here: ZC FakeUp and the re-enter need it.
end)

function ZC_LVS.EjectPlayer(ply, veh, slam)
	-- Crash ejection is intentionally disabled. Vehicles keep the occupant;
	-- impact severity is handled by sv_organism damage transfer.
	return
	--[[
	if not IsValid(ply) or not ply:Alive() or not ply:InVehicle() then return end
	if ply.switchingseat then return end
	if not slam and ZC_LVS.PlaneKeepPilot(veh) then return end

	local rag = ply.FakeRagdoll
	if not IsValid(rag) then return end
	local vel = vector_origin
	if IsValid(veh) then
		vel = veh:GetVelocity()
	elseif IsValid(rag) then
		vel = rag:GetVelocity()
	end

	local car = ZC_LVS.IsCar(veh)
	local scale = car and 0.45 or 0.55
	local up = car and 120 or 220
	local kick = car and 40 or 60
	if car and vel:Length() > 420 then vel = vel:GetNormalized() * 420 end
	local launch = vel * scale + Vector(0, 0, up)
	if launch:Length() < 240 then
		launch = launch:Length() < 1 and Vector(0, 0, 240) or launch:GetNormalized() * 240
	end
	ply.zc_lvs_ejecting = CurTime() + 2
	ply.zc_lvs_eject_state = "ejecting"
	ply.zc_lvs_cargo = nil
	ply:SetNWEntity("zc_lvs_cargo", NULL)
	rag.zc_lvs_crash_ejected = true
	if IsValid(rag) then
		rag.zc_lvs_car_fake = nil
		rag.zc_lvs_follow = nil
		rag.zc_lvs_follow_local = nil
		if rag.SetNWBool then rag:SetNWBool("zc_lvs_car_fake", false) end
		dropSeatWelds(rag)
		rag.removingwelds = true
		rag:SetParent(NULL)
		restoreSeatFakeWeight(rag)
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			if IsValid(phys) then phys:SetVelocity(launch) end
		end
	end

	ZC_LVS.AllowExit(ply, 1.5)
	ply:ExitVehicle()
	ply.zc_lvs_eject_state = "ragdoll_free"
	ZC_LVS.DebugLog("eject_after_exit", "ply_inveh=" .. tostring(ply:InVehicle()) .. " fake=" .. tostring(IsValid(ply.FakeRagdoll)))
	if ply:InVehicle() then
		timer.Simple(0, function()
			if IsValid(ply) and ply:InVehicle() then
				ZC_LVS.AllowExit(ply, 1.5)
				ply:ExitVehicle()
				ZC_LVS.DebugLog("eject_retry", "ply_inveh=" .. tostring(ply:InVehicle()))
			end
		end)
	end

	timer.Simple(0, function()
		if not IsValid(rag) then return end
		rag:SetParent(NULL)
		restoreSeatFakeWeight(rag)
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			if IsValid(phys) then
				phys:EnableMotion(true)
				phys:Wake()
				phys:SetVelocity(launch + VectorRand() * kick)
			end
		end
	end)
	]]
end

-- Only if the fake is really gone from the cabin. A hand sticking out
-- of a small car OBB used to ExitVehicle while standing still.
hook.Add("Think", "zc_lvs_ragdoll_eject", function()
	if not ZC_LVS.Enabled() then return end

	for _, ply in player.Iterator() do
		if ply.switchingseat then continue end
		if ply.lastswitched and ply.lastswitched > CurTime() then continue end
		if not ply:Alive() or not ply:InVehicle() then continue end
		if not ZC_LVS.IsLVSSeat(ply:GetVehicle()) then continue end

		local rag = ply.FakeRagdoll
		if not IsValid(rag) then continue end
		if rag.welds then continue end
		if rag.removingwelds then continue end
		if rag.zc_lvs_seatfake then continue end
		if IsValid(rag:GetParent()) then continue end

		local veh = ZC_LVS.GetVehicle(ply)
		if not IsValid(veh) then continue end
		-- Closed hull: fake is ghosted on purpose and may sit outside the
		-- OBB. Never ExitVehicle from that.
		if ZC_LVS.IsClosedVehicle(veh) or ZC_LVS.IsAircraft(veh) or ZC_LVS.IsPlane(veh) then
			continue
		end
		-- Cars: stay welded. Eject-on-gap yeets you out of a crash (РЎС“Р В»Р ВµРЎвЂљР ВµР В» Р Р† Р В¶Р С•Р С—РЎС“).
		-- Cars are controlled only by the crash detector. Do not use the old
		-- gap-based fallback: pose updates can trigger it during normal driving.
		if ZC_LVS.IsCar(veh) then continue end
		if ZC_LVS.IsTurretSeat(ply) or ZC_LVS.ShouldStandAtWeapon(ply) then
			continue
		end
		local cam = ZC_LVS.CameraMode(ply)
		if cam == "lvs_closed" or cam == "lvs_air" or cam == "lvs_plane" or cam == "lvs_gun" then
			continue
		end
		local pod = ply:GetVehicle()
		if IsValid(pod) and rag:WorldSpaceCenter():DistToSqr(pod:GetPos()) < 100 * 100 then continue end
		if rag:WorldSpaceCenter():DistToSqr(veh:WorldSpaceCenter()) < 400 * 400 then continue end

		ZC_LVS.AllowExit(ply)
		ply:ExitVehicle()
	end
end)

local function blockRagdollGrab(ply)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ply) then return end

	local rag = ply.FakeRagdoll
	if not IsValid(rag) then return end
	local cargo = IsValid(ply.zc_lvs_cargo)
	local seated = ply:InVehicle() and (ZC_LVS.IsLVSSeat(ply:GetVehicle()) or IsValid(ZC_LVS.GetVehicle(ply)))
	if not cargo and not seated then return end

	-- ZC: Shift = left hand, Alt = right hand. Keep cooldown hot so the
	-- Fake Think cannot weld a hand to the LVS chassis (camera yank / Use-eject).
	rag.cooldownLH = CurTime() + 1
	rag.cooldownRH = CurTime() + 1

	if IsValid(rag.ConsLH) then
		rag.ConsLH:Remove()
		rag.ConsLH = nil
	end
	if IsValid(rag.ConsRH) then
		rag.ConsRH:Remove()
		rag.ConsRH = nil
	end
end

-- Stop Z-City's grab/hand bindings before its own PlayerButtonDown hooks see
-- Shift or Alt. In an open LVS car those keys must never move the seated fake
-- or run the fake's vehicle-use path.
hook.Add("PlayerButtonDown", "!!!!zc_lvs_block_open_car_grab", function(ply, button)
	if not ZC_LVS.Enabled() or not IsValid(ply) or not ply:InVehicle() then return end
	local pod = ply:GetVehicle()
	if not ZC_LVS.IsLVSSeat(pod) then return end
	local veh = ZC_LVS.GetChassis(pod)
	if not IsValid(veh) or not ZC_LVS.IsOpenCarHull(veh) then return end
	if button == KEY_LSHIFT or button == KEY_RSHIFT or button == KEY_LALT or button == KEY_RALT then
		return true
	end
end)

hook.Add("StartCommand", "zc_lvs_no_climb", function(ply, cmd)
	blockRagdollGrab(ply)
end)

hook.Add("Think", "zc_lvs_no_climb", function()
	if not ZC_LVS.Enabled() then return end
	for _, ply in player.Iterator() do
		if ply:InVehicle() or IsValid(ply.zc_lvs_cargo) then
			blockRagdollGrab(ply)
		end
	end
end)

local function isLVSUseTarget(ent)
	if not IsValid(ent) then return false end
	if ent.LVS then return true end
	if ZC_LVS.IsLVSSeat(ent) then return true end
	local parent = ent:GetParent()
	return IsValid(parent) and parent.LVS == true
end

-- LVS chassis is not ent:IsVehicle(), so ZC grab does ent:Use() = SetPassenger / eject.
hook.Add("PlayerUse", "!!!!zc_lvs_no_use_while_seated", function(ply, ent)
	if not ZC_LVS.Enabled() then return end
	if ZC_LVS.IsCrashEjected(ply) then
		if isLVSUseTarget(ent) then return false end
		return
	end
	if IsValid(ply) and IsValid(ply.zc_lvs_cargo) then
		ZC_LVS.DebugLog("cargo_use_block", "ply=" .. ply:EntIndex(), "ent=" .. (IsValid(ent) and ent:GetClass() or "invalid"), "lvs=" .. tostring(IsValid(ent) and ent.LVS or false))
		return false
	end
	if IsValid(ply) and not ply:InVehicle() and isLVSUseTarget(ent) then
		standAfterVehicle(ply)
		clearPodLeftovers(ent)
		-- Downed ragdoll cannot Use. Leftover vehicle fake already stood up.
		if IsValid(ply.FakeRagdoll) and ZC_LVS.IsUnconscious(ply) then
			return false
		end
		return
	end
	if not IsValid(ply) or not ply:InVehicle() then return end
	if not ZC_LVS.IsLVSSeat(ply:GetVehicle()) and not IsValid(ZC_LVS.GetVehicle(ply)) then return end
	if isLVSUseTarget(ent) then
		return false
	end
end)

-- Hatch/gun/air: LVS weapons only. ZC Z/C selector stays off.
hook.Add("PlayerUse", "zc_lvs_pull_occupant", function(ply, ent)
	if not ZC_LVS.Enabled() then return end
	local occ = occupantFromRagdoll(ent)
	if not IsValid(occ) then return end
	pullOutOccupant(occ)
	return false
end)

hook.Add("StartCommand", "zc_lvs_no_eject_flight", function(ply, cmd)
	-- Hand controls remain available after a crash. The force source must be
	-- fixed in the ragdoll controller rather than hiding the controls.
	if not ZC_LVS.Enabled() or not IsValid(ply) or not ply:InVehicle() then return end
	local pod = ply:GetVehicle()
	local veh = ZC_LVS.GetChassis(pod)
	-- Z-City binds Shift/Alt to fake grab/climb. While seated in an open
	-- LVS car that action moves the fake and looks like a collision to the
	-- crash detector. Keep the keys for normal movement outside the vehicle.
	if IsValid(veh) and ZC_LVS.IsOpenCarHull(veh) and cmd:KeyDown(IN_SPEED) then
		cmd:RemoveKey(IN_SPEED)
	end
	-- ZC lean reads IN_DUCK server-side (fake/sv_control.lua) and would
	-- throw the fake back while CTRL should toggle the LVS third person
	-- (LVS reads it client-side via input.IsKeyDown — RemoveKey does not
	-- affect that). Strip DUCK in LVS seats so CTRL is LVS-only here.
	if not ZC_LVS.IsOpenCarHull(veh) then
		local mode = ZC_LVS.CameraMode(ply)
		if mode == "lvs_closed" or mode == "lvs_air" or mode == "lvs_plane" or mode == "lvs_gun" then
			if cmd:KeyDown(IN_DUCK) then
				cmd:RemoveKey(IN_DUCK)
			end
		end
	end
end)

hook.Add("PlayerSpawn", "zc_lvs_unstick", function(ply)
	ply.zc_lvs_eject_state = nil
	ply.zc_lvs_cargo = nil
	ply:SetNWEntity("zc_lvs_cargo", NULL)
	ply:SetNWBool("zc_lvs_ejected", false)
	timer.Simple(0, function()
		if IsValid(ply) then
			unstickSeatFake(ply)
		end
	end)
end)

hook.Add("PlayerSwitchWeapon", "zc_lvs_no_zc_guns", function(ply, oldWep, newWep)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ply) or not ply:InVehicle() then return end
	if not ZC_LVS.ShouldBlockZCWeapons(ply) then return end
	if not IsValid(newWep) then return end
	local class = newWep:GetClass()
	if class == "weapon_hands_sh" or class == "weapon_hands" then return end
	return true
end)

-- Two-handed gun: hands are busy, car is slower to steer/throttle.
hook.Add("Think", "zzzz_zc_lvs_twohand_drive", function()
	if not ZC_LVS.Enabled() then return end

	for _, ply in player.Iterator() do
		if not ply:InVehicle() then continue end
		if not ZC_LVS.IsTwoHandedWeapon(ply) then continue end

		local veh = ZC_LVS.GetVehicle(ply)
		if not IsValid(veh) or not ZC_LVS.IsCar(veh) then continue end
		if not ZC_LVS.IsDriver(ply, veh) then continue end

		-- Do not SetSteer: that fights LVS mouse-steer (GAZ-66 self-drive).
		if veh.GetThrottle and veh.SetThrottle then
			local t = veh:GetThrottle()
			if isnumber(t) then
				veh:SetThrottle(t * 0.58)
			end
		end
	end
end)

-- hg.Fake calls Entity:SetPos(world) on the seated player. Prisoner_pod
-- treats that as local РІвЂ вЂ™ Bad SetLocalOrigin zРІвЂ°в‚¬-22000, dummy on the roof.
-- Wrap Entity, not Player: Player.SetPos is often just Entity's function.
-- ZC sv_control uses vector_origin (legal). Re-bind on every include.
do
	local emeta = FindMetaTable("Entity")
	if emeta and emeta.SetPos then
		if not ZC_LVS._origEntSetPos then
			ZC_LVS._origEntSetPos = emeta.SetPos
		end
		local oldSetPos = ZC_LVS._origEntSetPos
		function emeta:SetPos(pos, ...)
			if isvector(pos) and self.IsPlayer and self:IsPlayer() then
				local pod = self.GetVehicle and self:GetVehicle()
				if IsValid(pod) and pod:GetClass() == "prop_vehicle_prisoner_pod" then
					if math.abs(pos.x) > 64 or math.abs(pos.y) > 64 or pos.z < -64 or pos.z > 128 then
						return
					end
				end
			end
			return oldSetPos(self, pos, ...)
		end
		ZC_LVS._wrappedSetPos = true
	end
end

-- ZC fake_enterveh returns false if veh.rags still holds the last dummy.
if hg and hg.RemoveDeadBodies and not ZC_LVS._wrappedRemoveDead then
	ZC_LVS._wrappedRemoveDead = true
	local oldRemove = hg.RemoveDeadBodies
	function hg.RemoveDeadBodies(veh)
		if ZC_LVS.Enabled() and ZC_LVS.IsLVSSeat(veh) then
			local function scrub(ent)
				if not IsValid(ent) or not istable(ent.rags) then return end
				for i = #ent.rags, 1, -1 do
					local rag = ent.rags[i]
					if not IsValid(rag) or not (rag.organism and rag.organism.isPly) then
						table.remove(ent.rags, i)
					end
				end
			end
			scrub(veh)
			local ch = ZC_LVS.GetChassis(veh)
			if IsValid(ch) then
				scrub(ch)
			end
			return false
		end
		return oldRemove(veh)
	end
end

-- Seatbelt: weld CallOnRemove / physics dump call ExitVehicle directly.
-- Only E/EXIT / seat switch / our eject may leave.
do
	local pmeta = FindMetaTable("Player")
	if pmeta and pmeta.ExitVehicle then
		if not ZC_LVS._origExitVehicle then
			ZC_LVS._origExitVehicle = pmeta.ExitVehicle
		end
		local oldExit = ZC_LVS._origExitVehicle
		function pmeta:ExitVehicle(...)
			if ZC_LVS.Enabled() and self.InVehicle and self:InVehicle() then
				if ZC_LVS.IsLVSSeat(self:GetVehicle()) and not ZC_LVS.MayExitVehicle(self) then
					return
				end
			end
			return oldExit(self, ...)
		end
	end
end

if constraint and constraint.Weld then
	if not ZC_LVS._origWeld then
		ZC_LVS._origWeld = constraint.Weld
	end
	local oldWeld = ZC_LVS._origWeld
	function constraint.Weld(ent1, ent2, ...)
		local function seatedDummy(e)
			if not IsValid(e) or e:GetClass() ~= "prop_ragdoll" then return false end
			for _, ply in player.Iterator() do
				if ply:InVehicle() and ply.FakeRagdoll == e and ZC_LVS.IsLVSSeat(ply:GetVehicle()) then
					return true
				end
			end
			return false
		end
		if seatedDummy(ent1) or seatedDummy(ent2) then
			return nil
		end
		return oldWeld(ent1, ent2, ...)
	end
end

hook.Add("LVS.PlayerKeyDown", "zc_lvs_allow_exit_key", function(ply, name, pressed)
	if name == "EXIT" and pressed then
		ZC_LVS.AllowExit(ply)
	end
end)

-- LVS EXIT is PlayerButtonDown РІвЂ вЂ™ ExitVehicle() in the same stack.
-- Allow before that hook so the seatbelt does not eat a real leave.
hook.Add("PlayerButtonDown", "!!!!zc_lvs_exit_belt", function(ply, button)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ply) or not ply:InVehicle() then return end
	if not ZC_LVS.IsLVSSeat(ply:GetVehicle()) then return end
	local cvar = GetConVar("lvs_exit")
	local exitBtn = (cvar and cvar:GetInt()) or KEY_E
	if button == exitBtn or button == KEY_E then
		ZC_LVS.AllowExit(ply)
	end
end)

