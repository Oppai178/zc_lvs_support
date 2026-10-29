-- [Z-CITY] LVS SUPPORT
-- Author: Oppai
--
-- CAMERA DISPATCH — one order, identical in every wrapper below
-- (hg.CalcViewFake, "!!!!LVS_calcview", "homigrad-view"):
--   mode "zc"  → the ORIGINAL Z-City camera. We return no view of our own
--                on this path, so nothing here can mute ZC's own
--                drawviewer / viewmodel decisions.
--   mode lvs_* → vanillaLVSView: native LVS view plus the pelvis-cam /
--                seat-pan fixes. zc_lvs_air_lvcam=1 is the opt-out convar
--                that flips aircraft onto this path (default 0 = ZC eyes).
--   The "zc" exceptions are the MOUSE and the PILOT VIEW (InputMouseApply
--   + wrapCalcViewFake): in aviation the pilot's mouse must feed the LVS
--   stick (and stock LVS FREELOOK) and his camera IS EyeAngles (1:1 with
--   the stick, LVS heli PlayerMouseAim reads EyeAngles); plain passengers
--   turn the head the ZC way and keep the ZC fake cam.
-- airView / waitCarView / waitingCarCam / airMouse are DEAD paths since the
-- "zc"-first dispatch (ShouldUseOurCamera requires mode "zc", which
-- ShouldUseZCityCamera already matched first). Kept below, commented, for
-- history — do not route anything new through them.

ZC_LVS = ZC_LVS or {}

-- World-up from the pod origin. Pod local axes differ per LVS pack;
-- Vector(0,0,30) in pod-space was the seat pan on some trucks.
local SEAT_EYE_WORLD_Z = 32
local STAND_EYE_WORLD_Z = 64
local EYE_NEAR_SEAT = 72 * 72
local EYE_NEAR_STAND = 110 * 110

-- Prisoner pod sits inside tank armor. Vanilla LVS first-person then
-- looks into the mantlet (black plate). Climb world-up out of the hull.
local function closedHatchPos(pod, veh)
	if not IsValid(pod) then return vector_origin end
	local start = pod:GetPos()
	local function inHull(p)
		local tr = util.TraceLine({
			start = p,
			endpos = p + Vector(0, 0, 2),
			filter = function(hit)
				if not IsValid(hit) then return false end
				if hit == pod or hit:IsPlayer() then return false end
				local class = hit:GetClass()
				if class == "prop_ragdoll" or class == "prop_vehicle_prisoner_pod" then return false end
				return hit == veh or hit:GetParent() == veh or hit.LVS == true
			end,
			mask = MASK_SOLID,
		})
		return tr.StartSolid
	end
	local p = start + Vector(0, 0, 8)
	for _ = 1, 14 do
		if not inHull(p) then
			return p + Vector(0, 0, 28)
		end
		p = p + Vector(0, 0, 8)
	end
	return start + Vector(0, 0, 64)
end

-- Shared-with-sv_seats sanity check (local copy: that one is server-only).
local function isCrazyPos(pos)
	if not isvector(pos) then return true end
	if pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z then return true end
	if math.abs(pos.x) > 16384 or math.abs(pos.y) > 16384 or math.abs(pos.z) > 16384 then return true end
	return false
end

local function localAirRagdoll(ply)
	if not IsValid(ply) then return NULL end
	if IsValid(ply.FakeRagdoll) then return ply.FakeRagdoll end
	if ply.GetNWEntity then
		local rag = ply:GetNWEntity("FakeRagdoll")
		if IsValid(rag) then return rag end
	end
	return NULL
end

-- Entity:GetPos on a kinematic ragdoll can stay at the sit spot.
-- Eyes / pelvis follow the hull.
local function ragEyesNear(rag, dest, dist)
	if not IsValid(rag) or not isvector(dest) then return false end
	dist = dist or 110
	local pos
	local id = rag:LookupAttachment("eyes")
	if id and id > 0 then
		local att = rag:GetAttachment(id)
		if att and att.Pos then
			pos = att.Pos
		end
	end
	if not pos then
		local bone = rag:LookupBone("ValveBiped.Bip01_Head1")
		if bone then
			local mat = rag.GetBoneMatrix and rag:GetBoneMatrix(bone)
			if mat then
				pos = mat:GetTranslation()
			end
		end
	end
	pos = pos or rag:WorldSpaceCenter()
	return pos:DistToSqr(dest) < dist * dist
end

-- Camera at sitting-eye height. Never use pod-local Z: LVS packs rotate
-- prisoner pods so (0,0,30) local is the seat pan / under the truck.
function ZC_LVS.SeatCamPos(ply, pod)
	if not IsValid(pod) then
		return ply:EyePos()
	end

	local rag = localAirRagdoll(ply)
	local eyePos
	local standing = ZC_LVS.ShouldStandAtWeapon(ply)
	local near = standing and EYE_NEAR_STAND or EYE_NEAR_SEAT
	local veh = ZC_LVS.GetChassis(pod)
	-- Hatch dummy sits in the hull — don't look from the cabin floor.
	-- Cars: use dummy EYES (that's "see yourself" + TPIK hands). Pelvis = ass cam.
	local hatch = IsValid(veh) and not ZC_LVS.IsClosedVehicle(veh) and not ZC_LVS.IsAircraft(veh)
		and (ZC_LVS.IsRoofSeat(pod, veh) or (IsValid(ply) and ZC_LVS.IsTurretSeat(ply)))

	if not hatch and IsValid(rag) then
		local id = rag:LookupAttachment("eyes")
		if id and id > 0 then
			local att = rag:GetAttachment(id)
			if att and att.Pos and (not IsValid(veh) or (ZC_LVS.IsOpenCarHull(veh) and not hatch) or att.Pos:DistToSqr(pod:GetPos()) < near) then
				eyePos = att.Pos
			end
		end

		if not eyePos then
			local bone = rag:LookupBone("ValveBiped.Bip01_Head1")
			if bone then
				local mat = rag:GetBoneMatrix(bone)
				if mat then
					local headPos = mat:GetTranslation()
				if not IsValid(veh) or (ZC_LVS.IsOpenCarHull(veh) and not hatch) or headPos:DistToSqr(pod:GetPos()) < near then
						eyePos = headPos
					end
				end
			end
		end
	end

	if eyePos then
		if IsValid(veh) and ZC_LVS.IsAircraft(veh) then
			-- Keep height, drop sideways offset so looking down is the floor.
			local rel = eyePos - pod:GetPos()
			local right = pod:GetRight()
			rel = rel - right * rel:Dot(right)
			return pod:GetPos() + rel
		end
		return eyePos
	end

	if IsValid(veh) then
		return ZC_LVS.CabinCamPos(pod, veh)
	end
	local z = standing and STAND_EYE_WORLD_Z or SEAT_EYE_WORLD_Z
	return pod:GetPos() + Vector(0, 0, z)
end

-- DEAD PATH (unreachable, see header): waitingCarCam requires
-- ShouldUseZCityCamera (mode "zc") and no fake yet, but every wrapper
-- checks ShouldUseZCityCamera FIRST and hands the frame to the original
-- ZC camera before waitingCarCam could matter. Also, the 0.8s window it
-- covered is handled by zc_lvs_cache_cockpit (ply.zc_lvs_view_local).
-- Sitting view that rides the hull. Not fake-eye physics, not pod EyePos.
local function waitCarView(ply, origin, angles, fov, znear, zfar)
	if not IsValid(ply) then return end
	local pod = ply:GetVehicle()
	if not IsValid(pod) then return end

	local veh = ZC_LVS.GetChassis(pod)
	local pos = ZC_LVS.CarEyePos(ply, pod, veh)
	local ang = ZC_LVS.CarEyeAngles(ply, veh, pod)

	return {
		origin = pos,
		angles = ang,
		fov = fov or 90,
		znear = znear or 1,
		zfar = zfar,
		drawviewer = false,
	}
end

local function waitingCarCam(ply)
	if not ZC_LVS.ShouldUseZCityCamera(ply) then return false end
	return not IsValid(localAirRagdoll(ply))
end

-- FP: hide player (hg.Fake), show fake only if it is in the cabin.
-- TP/Control: show the player mesh at the cabin seat.
-- Hatch: hide both meshes (clip 18.01 — roof dummy is that draw).
local function applyCarBodyDraw(ply)
	if not IsValid(ply) then return end
	local rag = localAirRagdoll(ply)
	local pod = ply:GetVehicle()
	local veh = ZC_LVS.GetChassis(pod)
	local inCar = ply:InVehicle() and IsValid(veh) and ZC_LVS.IsCar(veh)
		and not ZC_LVS.IsClosedVehicle(veh)
	local hatch = inCar and ZC_LVS.IsHatchSeat(ply, pod, veh)

	if not inCar then
		if ply.zc_lvs_cl_body then
			ply:SetRenderMode(RENDERMODE_NORMAL)
			ply:SetNoDraw(false)
			ply.zc_lvs_cl_body = nil
		end
		if IsValid(rag) and rag.zc_lvs_cl_hid then
			rag:SetNoDraw(false)
			rag.zc_lvs_cl_hid = nil
		end
		return
	end

	ply.zc_lvs_cl_body = true
	if hatch then
		ply:SetRenderMode(RENDERMODE_NONE)
		ply:SetNoDraw(true)
		if IsValid(rag) then
			rag:SetNoDraw(true)
			rag:DrawShadow(false)
			rag.zc_lvs_cl_hid = true
		end
		return
	end

	local cabin = ZC_LVS.CarEyePos(ply, pod, veh)
	-- 90u hid a dummy that was already in the cabin.
	local fakeIn = ragEyesNear(rag, cabin, 200)

	local third = pod.GetThirdPersonMode and pod:GetThirdPersonMode()
	if third then
		ply:SetRenderMode(RENDERMODE_NORMAL)
		ply:SetNoDraw(false)
		if IsValid(rag) then
			rag:SetNoDraw(true)
			rag.zc_lvs_cl_hid = true
		end
	else
		ply:SetRenderMode(RENDERMODE_NONE)
		if IsValid(rag) then
			rag:SetNoDraw(not fakeIn)
			rag.zc_lvs_cl_hid = not fakeIn
		end
	end
end

-- 2.9.0: do not hide the dummy. Clip 22.09 sat with hands, then the
-- hide/fallback made the cabin empty while driving.

hook.Add("Think", "zc_lvs_cl_car_body", function()
	if not ZC_LVS.Enabled() then return end
	applyCarBodyDraw(LocalPlayer())
end)

hook.Add("PrePlayerDraw", "zc_lvs_cl_hatch_hide", function(ply)
	if not ZC_LVS.Enabled() or not IsValid(ply) then return end
	if not ply.InVehicle or not ply:InVehicle() then return end
	local pod = ply:GetVehicle()
	local veh = ZC_LVS.GetChassis(pod)
	if ZC_LVS.IsHatchSeat(ply, pod, veh) then
		return true
	end
end)

hook.Add("PlayerEnteredVehicle", "zc_lvs_cl_car_look", function(ply)
	if ply ~= LocalPlayer() then return end
	ply.zc_lvs_cl_enter = CurTime() + 0.8

	-- LVS caches pod:lvsGetWeapon() on the pod entity forever
	-- (_lvsWeaponEntChecked). After a seat switch the new pod answers
	-- correctly, but our per-pod/mode caches must not outlive the move:
	-- CameraMode stamps ply.zc_lvs_cam_mode for one frame only — clear
	-- it so the next CalcView re-derives the mode from the new pod.
	ply.zc_lvs_cam_mode = nil
	ply.zc_lvs_cam_t = nil

	-- LVS third person is a flag read via pod:GetThirdPersonMode() by the
	-- whole framework (set through vehicle:SetThirdPersonMode in
	-- lvs_hookers, guarded). A leftover "true" from the previous ride
	-- made the driver spawn in a bogus third person that showed the
	-- bench (clip 04.10). Reset on every closed-hull enter, on every
	-- entity that actually has the setter: chassis and pod.
	local pod = ply:GetVehicle()
	local veh = ZC_LVS.GetChassis(pod)
	if IsValid(veh) and ZC_LVS.IsClosedVehicle(veh) then
		for i = 1, 2 do
			local ent = (i == 1) and veh or pod
			if IsValid(ent)
				and isfunction(ent.GetThirdPersonMode)
				and isfunction(ent.SetThirdPersonMode)
				and ent:GetThirdPersonMode() then
				ent:SetThirdPersonMode(false)
			end
		end
	end
end)

-- DEAD PATH (unreachable, see header): ShouldUseOurCamera requires mode
-- "zc" on an open-car hull, but ShouldUseZCityCamera is checked first in
-- every wrapper and takes the frame. airMouse (the closed-hull mouse
-- driver at the bottom of the file) is reachable only from the same dead
-- branch in wrapFakeMouse.
local function airView(ply, origin, angles, fov, znear, zfar)
	if not IsValid(ply) then return end

	local veh = ZC_LVS.GetVehicle(ply)
	local pod = ply:GetVehicle()
	if not IsValid(pod) then return end

	fov = fov or 90
	angles = angles or ply:EyeAngles()
	local mode = ZC_LVS.CameraMode(ply)

	-- Per-frame view diagnostics: where the camera actually sits and why.
	ZC_LVS.DebugLog("view", "mode=" .. tostring(mode),
		"pod=(" .. string.format("%.0f %.0f %.0f", pod:GetPos().x, pod:GetPos().y, pod:GetPos().z) .. ")",
		"inpos=(" .. (isvector(origin) and string.format("%.0f %.0f %.0f", origin.x, origin.y, origin.z) or "?") .. ")",
		"fake=" .. tostring(IsValid(localAirRagdoll(ply))),
		"third=" .. tostring(pod.GetThirdPersonMode and pod:GetThirdPersonMode() or false))
	-- A5 (08.10): airView is the OPT-OUT path (mode lvs_air / lvs_plane,
	-- zc_lvs_air_lvcam=1). The default zc-air camera is the ZC fake cam
	-- above (wrapCalcViewFake). Kept: packs that force the native view.

	if IsValid(veh) and isfunction(veh.LVSCalcFov) then
		fov = veh:LVSCalcFov(fov, ply) or fov
	end

	-- Tank / closed hull: keep LVS hatch view.
	-- Open-car gunner (vanilla jeep MG etc.) must NOT use that path:
	-- LVSCalcView + ragdoll EyePos puts the camera above your own head.
	-- Those seats use the same sit-eye look as helicopters.
	local standGun = mode == "lvs_gun" and ZC_LVS.ShouldStandAtWeapon(ply)
	-- Heli/plane/tank: keep LVSCalcView. Overwriting origin with world-up
	-- SeatCamPos pulls the camera behind the nose when you pitch down,
	-- and EyeAngles vs a -90 pod yaws the stick left of the view.
	if (mode == "lvs_gun" and not standGun) or mode == "lvs_closed" or mode == "lvs_plane" or mode == "lvs_air" then
		local third = pod.GetThirdPersonMode and pod:GetThirdPersonMode()

		-- FP in AIR = the fake's eyes (rule, Oppai 05.10: ArmA style — the
		-- pilot sees his own body; ground closed seats are handled in
		-- vanillaLVSView, the actually-executed path for tanks).
		-- Control never follows the camera: LVS reads EyeAngles, free look
		-- is stock LVS FREELOOK — the camera is just a passenger.
		local isAir = mode == "lvs_air" or mode == "lvs_plane"
		if not third and isAir then
			local eyes = ragEyes(ply, pod)
			local rag = localAirRagdoll(ply)
			-- Only trust the eyes when the fake is actually IN the vehicle
			-- (a stray/garbage ragdoll put the camera "в пизде каком-то").
			if isvector(eyes) and IsValid(rag)
				and rag:WorldSpaceCenter():DistToSqr(veh:WorldSpaceCenter()) < 400 * 400 then
				-- Smoothed position: the fake shakes with physics, a raw
				-- bone cam would vibrate. Angles come from EyeAngles so
				-- control and view stay 1:1 (no stick/camera drift).
				ply.zc_lvs_eyelerp = ply.zc_lvs_eyelerp or eyes
				local lp = ply.zc_lvs_eyelerp
				local ft = math.min(FrameTime() * 12, 1)
				lp.x = lp.x + (eyes.x - lp.x) * ft
				lp.y = lp.y + (eyes.y - lp.y) * ft
				lp.z = lp.z + (eyes.z - lp.z) * ft
				local ang = ply:EyeAngles()
				ang.r = 0
				local view = {
					origin = lp,
					angles = ang,
					fov = fov,
					drawviewer = false,
					znear = znear or 1,
					zfar = zfar,
				}
				if ply.lvsSetView then
					return ply:lvsSetView(view)
				end
				return view
			end
		end

		local view
		local pos = origin or ply:EyePos()
		local base = isfunction(pod.lvsGetWeapon) and pod:lvsGetWeapon() or NULL
		if IsValid(base) then
			if base.IsAimVectorUnlocked and base:IsAimVectorUnlocked() then
				angles = ply:EyeAngles()
			end
			local weapon = base.GetActiveWeapon and base:GetActiveWeapon()
			if weapon and isfunction(weapon.CalcView) then
				view = weapon.CalcView(base, ply, pos, angles, fov, pod)
			end
		end
		if not istable(view) and IsValid(veh) and isfunction(veh.LVSCalcView) then
			view = veh:LVSCalcView(ply, pos, angles, fov, pod)
		end
		if not istable(view) then
			view = {
				origin = pos,
				angles = angles,
				fov = fov,
				drawviewer = false,
			}
		end
		if not third then
			view.drawviewer = false
		end
		view.znear = znear or 1
		view.zfar = zfar
		if ply.lvsSetView then
			return ply:lvsSetView(view)
		end
		return view
	end

	local pos = ZC_LVS.SeatCamPos(ply, pod)

	local view
	if IsValid(veh) and isfunction(veh.LVSCalcView) then
		view = veh:LVSCalcView(ply, pos, angles, fov, pod)
	end

	if not istable(view) then
		local ang = ply:EyeAngles()
		ang.r = 0
		view = {
			origin = pos,
			angles = ang,
			fov = fov,
			drawviewer = false,
		}
	end

	view.origin = view.origin or pos
	view.znear = znear or 1
	view.zfar = zfar

	local third = pod.GetThirdPersonMode and pod:GetThirdPersonMode()
	if not third then
		view.drawviewer = false
		local ang = ply:EyeAngles()
		ang.r = 0
		view.angles = ang
		view.origin = pos
	end

	if ply.lvsSetView then
		return ply:lvsSetView(view)
	end

	return view
end

-- DEAD PATH (see airView comment): only called from the unreachable
-- ShouldUseOurCamera branch in wrapFakeMouse.
local function airMouse(cmd, x, y, angle)
	if ZC_LVS.IsUnconscious(LocalPlayer()) then
		cmd:SetViewAngles(angle)
		return true
	end

	local yawCvar = GetConVar("m_yaw")
	local pitchCvar = GetConVar("m_pitch")
	local yaw = yawCvar and yawCvar:GetFloat() or 0.022
	local pitch = pitchCvar and pitchCvar:GetFloat() or 0.022

	angle.yaw = angle.yaw - x * yaw
	angle.pitch = math.Clamp(angle.pitch + y * pitch, -89, 89)
	angle.roll = 0
	cmd:SetViewAngles(angle)
	return true
end

local function isOurFn(fn)
	if not isfunction(fn) then return true end
	local info = debug.getinfo(fn, "S")
	local src = info and (info.short_src or "") or ""
	return string.find(src, "zc_lvs", 1, true) ~= nil
end

local function wrapFakeMouse()
	local hooks = hook.GetTable().InputMouseApply
	if not hooks then return end

	local fakeMouse = hooks["fakeCameraAngles"]
	if fakeMouse and not ZC_LVS._origFakeMouse and not isOurFn(fakeMouse) then
		ZC_LVS._origFakeMouse = fakeMouse
	end
	if not ZC_LVS._origFakeMouse then return end

	hook.Add("InputMouseApply", "fakeCameraAngles", function(cmd, x, y, angle)
		local ply = LocalPlayer()
		if not IsValid(ply) or not ply:InVehicle() then
			return ZC_LVS._origFakeMouse(cmd, x, y, angle)
		end
		local mode = ZC_LVS.CameraMode(ply)

		-- Aircraft with mode "zc" (ZC eyes + LVS controls, the default since
		-- 08.10): the mouse splits by ROLE.
		--   pilot / driver seat → FLIGHT CONTROL: get out of the way so the
		--     mouse keeps feeding the LVS stick (and stock LVS FREELOOK);
		--   plain passenger → head turns the ZC way (original ZC mouse).
		-- lvs_* modes are the zc_lvs_air_lvcam=1 opt-out: fully native,
		-- never ZC mouse (dead airMouse branch lives below for history).
		local veh = ZC_LVS.GetVehicle(ply)
		if IsValid(veh) and (ZC_LVS.IsAircraft(veh) or ZC_LVS.IsPlane(veh)) then
			if mode == "zc" then
				-- Merge resolution (A3+A5, 08.10): the PILOT's mouse is the
				-- stick — LVS heli PlayerMouseAim reads EyeAngles directly, a
				-- ZC quat rotation would turn the stick, so the pilot must
				-- NOT go through origFakeMouse. The PASSENGER has no stick:
				-- his mouse turns the head the ZC way (origFakeMouse).
				-- B3 (08.10) "штурвал в мертвой точке": a plain `return` let
				-- later InputMouseApply hooks eat the mouse — Z-City's
				-- homicide mode (cl_subrole_abilities.lua "HMCD_SubRole_Ab-
				-- ilities") does cmd:SetViewAngles(ply:EyeAngles()) every
				-- frame, i.e. writes the OLD angle back and freezes
				-- EyeAngles → ApproachTargetAngle target never moves. Fix:
				-- WRITE the engine-applied mouse angle (the `angle` argument
				-- already carries this frame's delta) into the cmd and
				-- return true — chain stops, no hook after us can un-eat it.
				local pod = ply:GetVehicle()
				local isDriverSeat = IsValid(pod) and isfunction(veh.GetDriverSeat)
					and veh:GetDriverSeat() == pod
				if isDriverSeat or ZC_LVS.IsDriver(ply, veh) then
					-- Revert (Oppai 09.10 "не могу двигать камерой"): B3's
					-- mouse-eater guard froze the pilot's view in one spot —
					-- InputMouseApply returning TRUE suppresses the whole
					-- mouse pipeline, the camera died. Plain return: the
					-- engine applies the delta, homicide-mode overwrites
					-- (stick freeze) stay a separate problem to solve
					-- WITHOUT eating the mouse.
					return
				end
				return ZC_LVS._origFakeMouse(cmd, x, y, angle)
			end
			-- lvs_air / lvs_plane: native LVS mouse all the way.
			return
		end

		if mode == "lvs_closed" or mode == "lvs_plane" or mode == "lvs_gun" or mode == "lvs_air" then
			return
		end
		return ZC_LVS._origFakeMouse(cmd, x, y, angle)
	end)
	ZC_LVS._wrappedFakeMouse = true
end

-- Snapshot EyePos in pod-space BEFORE Fake (the good 0.7s view).
-- After Fake, engine origin is the ragdoll pelvis (camera in the jeep bed).
-- Do not use LocalToWorld(0,0,33): MG pods are pitched -90, that IS the bed.
-- Read only on the lvs_* path: for mode "zc" the ZC camera owns the view
-- and must not see our cockpit offset.
hook.Add("Think", "zc_lvs_cache_cockpit", function()
	if not ZC_LVS.Enabled() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:InVehicle() then return end
	if not ZC_LVS.ShouldUseLVSCamera(ply) then return end
	if IsValid(localAirRagdoll(ply)) then return end
	local pod = ply:GetVehicle()
	if not IsValid(pod) then return end
	local veh = ZC_LVS.GetChassis(pod)
	if IsValid(veh) then
		if ZC_LVS.IsRoofSeat(pod, veh) then return end
		ply.zc_lvs_view_local = veh:WorldToLocal(ply:EyePos())
	else
		ply.zc_lvs_view_local = pod:WorldToLocal(ply:EyePos())
	end
end)

hook.Add("PlayerLeaveVehicle", "zc_lvs_cache_cockpit", function(ply)
	if IsValid(ply) then
		ply.zc_lvs_view_local = nil
		-- A5: the smoothed eye position must not ride into the next seat / jump.
		ply.zc_lvs_eyeride = nil
		-- A5: leaving mid-air (EXIT key, no parachute in this build): the
		-- one-frame mode cache would keep answering "zc" while ZC re-fakes
		-- the fall, so clear it — the free fall is a plain ZC ragdoll cam.
		ply.zc_lvs_cam_mode = nil
		ply.zc_lvs_cam_t = nil
		ply.zc_lvs_cam_last = nil
	end
end)

local function fakeCockpitPos(ply, pod)
	local veh = ZC_LVS.GetChassis(pod)
	if not IsValid(veh) then veh = pod end
	local loc = ply.zc_lvs_view_local
	if isvector(loc) then
		local world = pod:LocalToWorld(loc)
		-- Pelvis/ass is at the pod. Real eyes are tens of units away.
		if world:DistToSqr(pod:GetPos()) > 20 * 20 then
			return world
		end
	end
	-- Along the airframe up, not pod-local Z (jeep MG bed, Cessna ass).
	return pod:GetPos() + veh:GetUp() * 32
end

local function ragEyes(ply, pod)
	local rag = localAirRagdoll(ply)
	if not IsValid(rag) then return end
	local id = rag:LookupAttachment("eyes")
	if id and id > 0 then
		local att = rag:GetAttachment(id)
		if att and att.Pos then
			return att.Pos
		end
	end
	local bone = rag:LookupBone("ValveBiped.Bip01_Head1")
	if bone then
		local mat = rag.GetBoneMatrix and rag:GetBoneMatrix(bone)
		if mat then
			return mat:GetTranslation()
		end
		local hp = rag:GetBonePosition(bone)
		if hp then return hp end
	end
end

-- Layer B: LVS origin is the pod, never the dummy (dummy may sit on a wing).
-- Layer B: LVS origin is the pod, never the dummy (dummy may sit on a wing).
-- (fakeCockpitPos above is a DEAD PATH: only reachable from airView, which
-- is unreachable since the "zc"-first dispatch. zc_lvs_view_local is still
-- maintained by Think zc_lvs_cache_cockpit and consumed by eyeFromPod.)
function ZC_LVS.ViewOrigin(ply, pod, pos)
	if not IsValid(pod) then
		return pos or (IsValid(ply) and ply:EyePos()) or vector_origin
	end
	local veh = ZC_LVS.GetChassis(pod)
	local loc = IsValid(ply) and ply.zc_lvs_view_local
	if isvector(loc) and IsValid(veh) and not ZC_LVS.IsRoofSeat(pod, veh) then
		local world = veh:LocalToWorld(loc)
		if world:DistToSqr(pod:GetPos()) < 80 * 80 then
			return world
		end
	end
	local up = IsValid(veh) and veh:GetUp() or Vector(0, 0, 1)
	return pod:GetPos() + up * 42
end

local function eyeFromPod(ply, pod)
	return ZC_LVS.ViewOrigin(ply, pod)
end

-- True pelvis cam only (~head is 40–50u away). 36u fought LVS every frame
-- and wandered the heli view.
local function originIsAss(ply, pod, origin)
	if not isvector(origin) then return true end
	local rag = localAirRagdoll(ply)
	if not IsValid(rag) then return false end
	local pelvis
	local b = rag:LookupBone("ValveBiped.Bip01_Pelvis")
	if b then
		pelvis = rag:GetBonePosition(b)
	end
	pelvis = pelvis or rag:WorldSpaceCenter()
	return origin:DistToSqr(pelvis) < 14 * 14
end

-- Heli/tank FP at the prisoner_pod is the seat pan / dashboard.
-- Gun sights sit hundreds of units out — leave those.
local function originIsSeatPan(pod, origin)
	return IsValid(pod) and isvector(origin) and origin:DistToSqr(pod:GetPos()) < 22 * 22
end

-- LVS's own CalcView hook bails out with `ply:GetViewEntity() ~= ply`
-- (ZC fake sets a view entity). When it does, the pod-weapon dispatcher
-- never runs and the camera freezes at the pod origin ("seeing only the
-- M113 interior", "choosing the MG does not move the camera").
-- Replicate the stock dispatcher (framework cl_camera.lua):
--   base = pod:lvsGetWeapon(); weapon.CalcView else vehicle:LVSCalcView.
local function lvsPodWeaponView(ply, pod, pos, angles, fov)
	if not IsValid(pod) then return nil end
	local veh = ZC_LVS.GetChassis(pod)
	if not IsValid(veh) then return nil end

	local base = isfunction(pod.lvsGetWeapon) and pod:lvsGetWeapon() or NULL
	local view
	if IsValid(base) then
		if base.IsAimVectorUnlocked and base:IsAimVectorUnlocked() then
			angles = ply:EyeAngles()
		end
		local weapon = base.GetActiveWeapon and base:GetActiveWeapon()
		if weapon and isfunction(weapon.CalcView) then
			view = weapon.CalcView(base, ply, pos, angles, fov, pod)
		end
	end
	if not istable(view) and isfunction(veh.LVSCalcView) then
		view = veh:LVSCalcView(ply, pos, angles, fov, pod)
	end
	return istable(view) and view or nil
end

local function vanillaLVSView(ply, pos, angles, fov)
	local pod = ply:GetVehicle()
	local third = IsValid(pod) and pod.GetThirdPersonMode and pod:GetThirdPersonMode() or false
	ZC_LVS.DebugLog("view_lvs", "pos=(" .. (isvector(pos) and string.format("%.0f %.0f %.0f", pos.x, pos.y, pos.z) or "?") .. ")",
		"podw=" .. tostring(isfunction(pod.lvsGetWeapon) and IsValid(pod:lvsGetWeapon())),
		"third=" .. tostring(third))
	-- Under a live ZC fake the engine origin is the ragdoll PELVIS
	-- (standing "in front of the driver seat", clip 05.10). Tank driver
	-- views (CalcViewDriver + TankViewOverride) build from that pos and
	-- end up inside the armor. Feed LVS the pod origin instead — the
	-- same view the player had before the fake appeared.
	local rag = localAirRagdoll(ply)
	local posIn = pos
	if IsValid(rag) and originIsAss(ply, pod, pos) then
		posIn = pod:GetPos() + Vector(0, 0, 32)
	end

	-- FP camera matrix (Oppai 06.10, the user's own table — see
	-- ZC_LVS.SeatMatrix in sh_core.lua): "fake eyes" = the ZC camera
	-- (body, hands, weapon — SAME pipeline the cars use, handled in
	-- CameraMode -> "zc"; this vanilla path is only reached by seats
	-- WITHOUT eyes). Ctrl is debug-gated inside the matrix.
	local matrix = ZC_LVS.SeatMatrix(ply, pod)
	ZC_LVS.DebugLog("view_matrix", "fake=" .. tostring(matrix.fake),
		"eyes=" .. tostring(matrix.eyes), "ctrl=" .. tostring(matrix.ctrl))

	-- Tanks, enclosed seats, and LVS HidePlayer pods own both camera modes.
	-- Keep their native hatch/gunner view, including Ctrl third person —
	-- but only where the matrix allows Ctrl (vanilla seats).
	if ZC_LVS.IsExternalLVSSeat(ply) and not matrix.eyes then
		if third and not matrix.ctrl then
			-- Ctrl is not allowed on this seat (matrix): treat as FP.
			third = false
		end
		local view = ZC_LVS._origLVSCam and ZC_LVS._origLVSCam(ply, posIn, angles, fov) or nil
		if istable(view) then
			return view
		end
		-- LVS bailed (view entity ≠ player under the ZC fake): run the
		-- pod-weapon dispatcher ourselves so weapon views still work.
		view = lvsPodWeaponView(ply, pod, posIn, angles, fov)
		if istable(view) then
			view.znear = 1
			if ply.lvsSetView then return ply:lvsSetView(view) end
			return view
		end
		return
	end
	if third and matrix.ctrl then
		local view = ZC_LVS._origLVSCam and ZC_LVS._origLVSCam(ply, pos, angles, fov) or nil
		if istable(view) then
			return view
		end
		view = lvsPodWeaponView(ply, pod, pos, angles, fov)
		if istable(view) then
			view.znear = 1
			if ply.lvsSetView then return ply:lvsSetView(view) end
			return view
		end
		return
	end

	-- Feed LVS its own pos. Replace only pelvis-cam, or air seat-pan (dashboard).
	-- (The aircraft seat-pan fix needs the chassis: this branch is the
	-- lvs_* path, "veh" here is the chassis of this pod.)
	local veh = IsValid(pod) and ZC_LVS.GetChassis(pod) or NULL
	if originIsAss(ply, pod, pos) and posIn == pos then
		posIn = (IsValid(pod) and eyeFromPod(ply, pod)) or pos
	elseif IsValid(veh) and ZC_LVS.IsAircraft(veh) and originIsSeatPan(pod, pos) and posIn == pos then
		posIn = (IsValid(pod) and eyeFromPod(ply, pod)) or pos
	end

	local view
	if ZC_LVS._origLVSCam then
		view = ZC_LVS._origLVSCam(ply, posIn, angles, fov)
	end
	if not istable(view) then
		view = lvsPodWeaponView(ply, pod, posIn, angles, fov) or {
			origin = posIn,
			angles = angles,
			fov = fov,
			drawviewer = false,
		}
	end
	if originIsAss(ply, pod, view.origin) then
		view.origin = posIn
	elseif IsValid(veh) and ZC_LVS.IsAircraft(veh) and originIsSeatPan(pod, view.origin) then
		view.origin = posIn
	end
	view.drawviewer = false
	return view
end

local function wrapCalcViewFake()
	if not hg or not isfunction(hg.CalcViewFake) then return end
	if not ZC_LVS._origCalcViewFake then
		local info = debug.getinfo(hg.CalcViewFake, "S")
		local src = info and (info.short_src or info.source) or ""
		if not string.find(src, "zc_lvs", 1, true) then
			ZC_LVS._origCalcViewFake = hg.CalcViewFake
		end
	end
	if not ZC_LVS._origCalcViewFake then return end

	function hg.CalcViewFake(ply, origin, angles, fov, znear, zfar)
		ply = ply or LocalPlayer()
		-- AIR DIAGNOSTICS (Oppai 09.10 "камера не там где глаза"): log
		-- eyes/neck/pelvis/camera origins once per 3s while seated in an
		-- aircraft, so we can SEE which point the camera rides when wrong.
		local diagRag = localAirRagdoll(ply)
		if ply:InVehicle() and IsValid(diagRag) then
			local diagVeh = ZC_LVS.GetVehicle(ply)
			if IsValid(diagVeh) and (ZC_LVS.IsAircraft(diagVeh) or ZC_LVS.IsPlane(diagVeh)) then
				local aid = diagRag:LookupAttachment("eyes")
				local att = aid and aid > 0 and diagRag:GetAttachment(aid) or nil
				local neckId = diagRag:LookupBone("ValveBiped.Bip01_Neck1")
				local neckPos = neckId and diagRag:GetBonePosition(neckId) or nil
				local fmt = function(v)
					return isvector(v) and string.format("%.0f %.0f %.0f", v.x, v.y, v.z) or "nil"
				end
				ZC_LVS.DebugLog("eye_diag",
					"eyes=" .. fmt(att and att.Pos or nil),
					"neck=" .. fmt(neckPos),
					"cam=" .. fmt(origin),
					"ragpos=" .. fmt(diagRag:GetPos()))
			end
		end
		-- Civilian car: vanilla ZC fake cam. Do not waitCarView.
		-- Reforger gunner (Oppai 08.10): pure ZC camera — the eye rides
		-- the ragdoll, which crawls from the pod to the turret server-side
		-- (See Think in sv_seats: zc_lvs_gunlerp). No offset here: the
		-- old glide-path offset put the camera INSIDE the turret geometry
		-- (black shards, clip 08.10).
		if ZC_LVS.ShouldUseZCityCamera(ply) then
			-- B3 (08.10) PILOT 1:1 CAMERA: LVS heli sv_mouseaim
			-- PlayerMouseAim reads ply:EyeAngles() into the stick. The ZC
			-- fake cam builds its angles from the ragdoll eye attachment
			-- (head bones + viewpunch), so view and stick CAN drift — and
			-- with EyeAngles frozen (mouse eaten, see wrapFakeMouse) the
			-- stick sat in a dead point "somewhere to the left". Rule: the
			-- pilot's camera IS EyeAngles, one source of truth for view and
			-- stick. Position still rides the fake's eyes (ArmA body view),
			-- smoothed, lifted along the hull up so the chest does not fill
			-- the cabin view. Passengers / third person keep the ZC cam.
			local veh0 = ZC_LVS.GetVehicle(ply)
			local pod0 = IsValid(ply) and ply:GetVehicle() or NULL
			if IsValid(veh0) and (ZC_LVS.IsAircraft(veh0) or ZC_LVS.IsPlane(veh0))
				and IsValid(pod0) and not (pod0.GetThirdPersonMode and pod0:GetThirdPersonMode())
				and not ZC_LVS.IsUnconscious(ply) then
				local isPilot = (isfunction(veh0.GetDriverSeat) and veh0:GetDriverSeat() == pod0)
					or ZC_LVS.IsDriver(ply, veh0)
				local rag0 = localAirRagdoll(ply)
				if isPilot and IsValid(rag0) then
					local eyes = ragEyes(ply, pod0)
					if isvector(eyes)
						and rag0:WorldSpaceCenter():DistToSqr(veh0:WorldSpaceCenter()) < 400 * 400 then
						-- Smoothed eye position: the fake shakes on physics
						-- welds at speed. Snap over 128u (enter / seat swap).
						ply.zc_lvs_eyeride = ply.zc_lvs_eyeride or eyes
						local lp = ply.zc_lvs_eyeride
						if eyes:DistToSqr(lp) > 128 * 128 then
							lp.x, lp.y, lp.z = eyes.x, eyes.y, eyes.z
						else
							local ft = math.min(FrameTime() * 18, 1)
							lp.x = lp.x + (eyes.x - lp.x) * ft
							lp.y = lp.y + (eyes.y - lp.y) * ft
							lp.z = lp.z + (eyes.z - lp.z) * ft
						end
						local outFov = fov or 90
						if isfunction(veh0.LVSCalcFov) then
							outFov = veh0:LVSCalcFov(outFov, ply) or outFov
						end
						local ang0 = ply:EyeAngles()
						ang0.r = 0
						local view0 = {
							origin = lp + veh0:GetUp() * 8,
							angles = ang0,
							fov = outFov,
							drawviewer = false,
							znear = 1,
							zfar = zfar,
						}
						if ply.lvsSetView then
							return ply:lvsSetView(view0)
						end
						return view0
					end
				end
			end
			local view = ZC_LVS._origCalcViewFake(ply, origin, angles, fov, znear, zfar)
			-- A5 (08.10): zc-mode AIRCRAFT — the camera rides the fake's head
			-- bone, which hangs on physics welds. At 400+ u/s the bone jitters
			-- frame to frame. Smooth ONLY the eye POSITION here; the ANGLES are
			-- EyeAngles (flight control must stay 1:1 with the stick) and are
			-- returned raw. A jump over 128u (enter / seat switch / gib) snaps
			-- instead of gliding.
			if istable(view) and isvector(view.origin) then
				local veh = ZC_LVS.GetVehicle(ply)
				if IsValid(veh) and (ZC_LVS.IsAircraft(veh) or ZC_LVS.IsPlane(veh)) then
					local lp = ply.zc_lvs_eyeride
					if not (isvector(lp) and view.origin:DistToSqr(lp) < 128 * 128) then
						lp = Vector(view.origin.x, view.origin.y, view.origin.z)
						ply.zc_lvs_eyeride = lp
					else
						local ft = math.min(FrameTime() * 18, 1)
						lp.x = lp.x + (view.origin.x - lp.x) * ft
						lp.y = lp.y + (view.origin.y - lp.y) * ft
						lp.z = lp.z + (view.origin.z - lp.z) * ft
					end
					view.origin = lp
				end
			end
			return view
		end
		if ZC_LVS.ShouldUseOurCamera(ply) and IsValid(localAirRagdoll(ply)) then
			return airView(ply, origin, angles, fov, znear, zfar)
		end
		if ZC_LVS.ShouldUseLVSCamera(ply) then
			return vanillaLVSView(ply, origin, angles, fov)
		end
		return ZC_LVS._origCalcViewFake(ply, origin, angles, fov, znear, zfar)
	end
	ZC_LVS._wrappedCalcViewFake = true
end

local function wrapCalcView()
	local hooks = hook.GetTable().CalcView
	if not hooks then return end

	local lvsFn = hooks["!!!!LVS_calcview"]
	if lvsFn and not isOurFn(lvsFn) then
		ZC_LVS._origLVSCam = lvsFn
	end
	if isOurFn(lvsFn) and ZC_LVS._origLVSCam then
		-- Already wrapped. Do not return before the homigrad-view branch
		-- below: hg.CalcViewFake can appear (HomigradRun) after the first
		-- wrap pass, and skipping it left the fake cam unwrapped.
		ZC_LVS._wrappedLVSCam = true
		wrapCalcViewFake()
		return
	end

	local hgFn = hooks["homigrad-view"]
	if hgFn and not ZC_LVS._origHGCam and not isOurFn(hgFn) then
		ZC_LVS._origHGCam = hgFn
	end

	hook.Add("CalcView", "!!!!LVS_calcview", function(ply, pos, angles, fov)
		-- Civilian car: yield to ZC. LVS returning a view blocked Fake cam.
		if ZC_LVS.ShouldUseZCityCamera(ply) then
			return
		end
		if ZC_LVS.ShouldUseOurCamera(ply) and IsValid(localAirRagdoll(ply)) then
			return airView(ply, pos, angles, fov)
		end
		if ZC_LVS.ShouldUseLVSCamera(ply) then
			return vanillaLVSView(ply, pos, angles, fov)
		end
		if ZC_LVS._origLVSCam then
			return ZC_LVS._origLVSCam(ply, pos, angles, fov)
		end
	end)
	ZC_LVS._wrappedLVSCam = true

	if ZC_LVS._origHGCam then
		hook.Add("CalcView", "homigrad-view", function(ply, origin, angles, fov, znear, zfar)
			if ZC_LVS.ShouldUseZCityCamera(ply) then
				return ZC_LVS._origHGCam(ply, origin, angles, fov, znear, zfar)
			end
			if ZC_LVS.ShouldUseOurCamera(ply) and IsValid(localAirRagdoll(ply)) then
				return airView(ply, origin, angles, fov, znear, zfar)
			end
			if ZC_LVS.ShouldUseLVSCamera(ply) then
				return vanillaLVSView(ply, origin, angles, fov)
			end
			return ZC_LVS._origHGCam(ply, origin, angles, fov, znear, zfar)
		end)
		ZC_LVS._wrappedHGCam = true
	end
end

-- Packs draw their own gunner mannequin via CreatePlayerModel /
-- DrawGunner (cl_attachable_playermodels). Rule: the ZC fake IS the
-- visible body — the pack mannequin must not double it. Neuter the
-- factory so every CreatePlayerModel call gets a model that never draws.
local function neuterAttachedModelFactory(ent)
	if not IsValid(ent) or ent.zc_lvs_no_pm then return end
	if not isfunction(ent.CreatePlayerModel) then return end
	ent.zc_lvs_no_pm = true

	local oldCreate = ent.CreatePlayerModel
	function ent:CreatePlayerModel(ply, name)
		local model = oldCreate(self, ply, name)
		if IsValid(model) and not model.zc_lvs_neutered then
			model.zc_lvs_neutered = true
			-- Packs call model:DrawModel() manually; make it a no-op and
			-- keep SetRenderOrigin/Angles harmless.
			function model:DrawModel() end
			model:SetNoDraw(true)
		end
		return model
	end
end

function ZC_LVS.NeuterAttachedModels(veh)
	neuterAttachedModelFactory(veh)
end

local function wrapExistingAttachedModels()
	if not LVS or not isfunction(LVS.GetVehicles) then return end
	local list = LVS:GetVehicles()
	if not istable(list) then return end
	for i = 1, #list do
		neuterAttachedModelFactory(list[i])
	end
end

local function wrapAll()
	wrapCalcView()
	wrapCalcViewFake()
	wrapFakeMouse()
	wrapExistingAttachedModels()
	-- Never wrap forever: a 1s retry that re-hooks CalcView can recurse
	-- and freeze the game ~1s after map load (workshop reports).
	if ZC_LVS._origLVSCam or ZC_LVS._wrappedCalcViewFake then
		timer.Remove("zc_lvs_wrap_cam_retry")
	end
	ZC_LVS._wrapCamTries = (ZC_LVS._wrapCamTries or 0) + 1
	if ZC_LVS._wrapCamTries > 8 then
		timer.Remove("zc_lvs_wrap_cam_retry")
	end
end

hook.Add("InitPostEntity", "zc_lvs_wrap_camera", function()
	timer.Simple(0, wrapAll)
	timer.Simple(1, wrapAll)
	timer.Simple(3, wrapAll)
end)

-- Vehicles spawned later get the neutered factory too.
hook.Add("OnEntityCreated", "zc_lvs_neuter_pm", function(ent)
	if not IsValid(ent) or not ent.LVS then return end
	timer.Simple(0, function()
		if IsValid(ent) and isfunction(ent.CreatePlayerModel) then
			neuterAttachedModelFactory(ent)
		end
	end)
end)

hook.Add("HomigradRun", "zc_lvs_wrap_camera", function()
	timer.Simple(0, wrapAll)
end)

timer.Simple(0, wrapAll)

timer.Create("zc_lvs_wrap_cam_retry", 1, 0, wrapAll)

local vecHeadSmall = Vector(0.01, 0.01, 0.01)
local vecHeadFull = Vector(1, 1, 1)

local function inAirFirstPerson(ply)
	if not ZC_LVS.ShouldUseLVSCamera(ply) then return false end
	-- Only lvs_* modes reach here (mode "zc" is dispatched to the original
	-- ZC camera before this matters). Native LVS air FP hides the fake's
	-- chest from its own camera.
	local pod = ply:GetVehicle()
	if IsValid(pod) and pod.GetThirdPersonMode and pod:GetThirdPersonMode() then
		return false
	end
	return true
end

-- A5 (08.10): zc-air first person — same head-hide rule as the LVS-camera
-- air seats, but keyed on CameraMode == "zc" + aircraft + no third person.
-- Without this the local heli passenger's own body filled the fake-eye view.
local function isAirZCSeat(ply)
	if not IsValid(ply) or not ply:InVehicle() then return false end
	local veh = ZC_LVS.GetVehicle(ply)
	if not IsValid(veh) then return false end
	if not (ZC_LVS.IsAircraft(veh) or ZC_LVS.IsPlane(veh)) then return false end
	return ZC_LVS.CameraMode(ply) == "zc"
end

local function inAirZCFirstPerson(ply)
	if not isAirZCSeat(ply) then return false end
	local pod = ply:GetVehicle()
	if IsValid(pod) and pod.GetThirdPersonMode and pod:GetThirdPersonMode() then
		return false
	end
	return true
end

local function resetHeadLook(rag)
	if not IsValid(rag) then return end
	if not rag.zc_lvs_headlook and not rag.zc_lvs_head_scaled then return end

	local head = rag:LookupBone("ValveBiped.Bip01_Head1")
	if head then
		rag:ManipulateBoneAngles(head, angle_zero)
		if rag.zc_lvs_head_scaled then
			rag:ManipulateBoneScale(head, vecHeadFull)
		end
	end
	local neck = rag:LookupBone("ValveBiped.Bip01_Neck1")
	if neck then rag:ManipulateBoneAngles(neck, angle_zero) end
	rag.zc_lvs_headlook = nil
	rag.zc_lvs_head_scaled = nil
end

-- Local FP: hide the skull so it cannot wrap into the camera.
-- Everyone else / third person: turn the head toward EyeAngles,
-- relative to the seat (body stays facing the dash).
local function applyHeadLook(rag, lookAng, hideHead, ply)
	if not IsValid(rag) then return end

	local head = rag:LookupBone("ValveBiped.Bip01_Head1")
	if not head then return end

	if hideHead then
		rag:ManipulateBoneAngles(head, angle_zero)
		local neck = rag:LookupBone("ValveBiped.Bip01_Neck1")
		if neck then rag:ManipulateBoneAngles(neck, angle_zero) end
		rag:ManipulateBoneScale(head, vecHeadSmall)
		rag.zc_lvs_head_scaled = true
		rag.zc_lvs_headlook = true
		return
	end

	if rag.zc_lvs_head_scaled then
		rag:ManipulateBoneScale(head, vecHeadFull)
		rag.zc_lvs_head_scaled = nil
	end

	local baseAng
	local pod = IsValid(ply) and ply:GetVehicle() or NULL
	if IsValid(pod) then
		baseAng = pod:LocalToWorldAngles(angle_zero)
		baseAng.p = 0
		baseAng.r = 0
	else
		local id = rag:LookupAttachment("eyes")
		local att = (id and id > 0) and rag:GetAttachment(id) or nil
		baseAng = (att and att.Ang) or rag:GetAngles()
	end

	local _, diff = WorldToLocal(vector_origin, lookAng, vector_origin, baseAng)
	diff.p = math.Clamp(math.NormalizeAngle(diff.p), -35, 35)
	diff.y = math.Clamp(math.NormalizeAngle(diff.y), -55, 55)

	rag:ManipulateBoneAngles(head, Angle(0, diff.y, -diff.p))
	local neck = rag:LookupBone("ValveBiped.Bip01_Neck1")
	if neck then
		rag:ManipulateBoneAngles(neck, Angle(0, diff.y * 0.3, -diff.p * 0.2))
	end

	rag:SetEyeTarget(rag:GetPos() + lookAng:Forward() * 10000)
	rag.zc_lvs_headlook = true
end

-- CameraMode does a lot of pod/weapon/role work (PodRole walks seat
-- tables). Cache the per-player verdict: full pass at most every 0.2s,
-- or immediately on enter/leave (cache invalidation below).
local HEADLOOK_INTERVAL = 0.2
local headlookCache = {}
local zc_nextHeadlook = 0

local function headlookVerdict(ply)
	return ZC_LVS.ShouldUseLVSCamera(ply) or nil
end

local function cachedHeadlook(ply)
	local c = headlookCache[ply]
	if c and c.t > CurTime() then
		return c.lvs
	end
	local lvs = headlookVerdict(ply)
	headlookCache[ply] = { t = CurTime() + HEADLOOK_INTERVAL, lvs = lvs }
	return lvs
end

local function invalidateHeadlook(ply)
	headlookCache[ply] = nil
end

hook.Add("PlayerEnteredVehicle", "zc_lvs_air_headlook_cache", invalidateHeadlook)
hook.Add("PlayerLeaveVehicle", "zc_lvs_air_headlook_cache", invalidateHeadlook)
-- Disconnected players must not leak table entries.
hook.Add("PlayerDisconnected", "zc_lvs_air_headlook_cache", function(ply)
	headlookCache[ply] = nil
end)

-- A5 (08.10) throttle merged with A3 cache: 10Hz for remote fakes (the
-- local FP hide/show is pinned per frame in PreDrawOpaqueRenderables);
-- the verdict itself is cached 0.2s on top.
hook.Add("Think", "zc_lvs_air_headlook", function()
	if not ZC_LVS.Enabled() then return end

	if CurTime() < zc_nextHeadlook then return end
	zc_nextHeadlook = CurTime() + 0.1

	local lp = LocalPlayer()
	for _, ply in player.Iterator() do
		local rag = localAirRagdoll(ply)
		if not IsValid(rag) then continue end

		-- Unconsciousness must be instant (ejected ragdoll should not keep
		-- a frozen head pose): check it live, it is cheap. Head-look verdict
		-- cached per 0.2s (perf); zc-aviation counts as head-look too (A5).
		local isLocal = ply == LocalPlayer()
		if not cachedHeadlook(ply) and not isAirZCSeat(ply) or ZC_LVS.IsUnconscious(ply) then
			resetHeadLook(rag)
			if rag.zc_lvs_nodraw then
				rag:SetNoDraw(false)
				rag.zc_lvs_nodraw = nil
			end
			continue
		end

		if isLocal and (not ply.lvsKeyDown or not ply:lvsKeyDown("FREELOOK")) then
			ply.zc_lvs_storedAim = ply:EyeAngles()
		end

		local look = ply:EyeAngles()
		look.r = 0
		-- B3: "hide" only shrinks the SKULL now (applyHeadLook scales the
		-- head bone). The zc-air FP body must stay VISIBLE (ArmA style —
		-- the pilot sees his own body, Oppai 08.10 "фейка нету"): the camera
		-- was lifted +8 hull-up in wrapCalcViewFake so the chest no longer
		-- fills the view. Only the NATIVE lvs_* air path still hides the
		-- whole fake (camera sits at the pod eyes there, chest in camera).
		local zcFP = isLocal and inAirZCFirstPerson(ply)
		local hide = isLocal and (inAirFirstPerson(ply) or zcFP)
		applyHeadLook(rag, look, hide, ply)

		-- Local first person on the NATIVE lvs_* path: body was filling the
		-- view (heli chest in camera). Others still see the fake.
		if hide and not zcFP then
			if not rag:GetNoDraw() then
				rag:SetNoDraw(true)
				rag.zc_lvs_nodraw = true
			end
		elseif rag.zc_lvs_nodraw then
			rag:SetNoDraw(false)
			rag.zc_lvs_nodraw = nil
		end
	end
end)

-- ZC rewrites head bone scale in DrawPlayerRagdoll; pin it again before draw.
-- A5: also covers zc-air first person (default aircraft camera).
hook.Add("PreDrawOpaqueRenderables", "zc_lvs_air_headlook", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	if not (inAirFirstPerson(ply) or inAirZCFirstPerson(ply)) then return end
	local rag = localAirRagdoll(ply)
	if not IsValid(rag) then return end
	local look = ply:EyeAngles()
	look.r = 0
	applyHeadLook(rag, look, true, ply)
end)

hook.Add("PlayerLeaveVehicle", "zc_lvs_air_headlook", function(ply)
	local rag = localAirRagdoll(ply)
	resetHeadLook(rag)
	if IsValid(rag) and rag.zc_lvs_nodraw then
		rag:SetNoDraw(false)
		rag.zc_lvs_nodraw = nil
	end
	if IsValid(ply) then
		ply.zc_lvs_storedAim = nil
	end
end)
