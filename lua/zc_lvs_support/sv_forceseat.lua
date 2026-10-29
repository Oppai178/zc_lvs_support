--[[
	[Z-CITY] LVS SUPPORT
	Author: Oppai

	Force seat: put another player (knocked out / tied / willing) into an
	LVS vehicle and pull them out. ArmA-style drag & load.

	Server part: net handler + guards. The forced seat flag bypasses our
	own CanPlayerEnterVehicle blocker (enter_block_fake) for one action.
	Disabled by default (zc_lvs_forceseat 0) until verified.
]]

ZC_LVS = ZC_LVS or {}

util.AddNetworkString("zc_lvs_forceseat")

local SEAT_DELAY = "zc_lvs_forceseat_next"

local REACH_PLAYER = 120
local REACH_VEHICLE = 160

-- Guard the action end-to-end: living initiator, empty hands, distance,
-- pod free, chassis LVS. Server only — the client menu is a mirror.
local function canForceSeat(actor, target, pod)
	if not ZC_LVS.Enabled() then return false end
	if not GetConVar("zc_lvs_forceseat"):GetBool() then return false end
	if not IsValid(actor) or not actor:Alive() then return false end
	if ZC_LVS.IsUnconscious(actor) then return false end
	if not ZC_LVS.HasEmptyHands(actor) then return false end
	if not IsValid(target) or not target:IsPlayer() or not target:Alive() then return false end
	if target == actor then return false end
	if not IsValid(pod) or not ZC_LVS.IsLVSSeat(pod) then return false end

	-- Occupied pod: deny (do not shove two bodies into one seat).
	local seated = pod.GetDriver and pod:GetDriver()
	if IsValid(seated) then return false end

	local veh = ZC_LVS.GetChassis(pod)
	if not IsValid(veh) then return false end

	-- Both near the machine: actor near the pod, target near the chassis.
	local podPos = pod:GetPos()
	local hull = target:OBBMaxs().z
	local targetPos = IsValid(target.FakeRagdoll) and target.FakeRagdoll:GetPos() or target:GetPos()
	if actor:GetPos():DistToSqr(podPos) > REACH_VEHICLE * REACH_VEHICLE then return false end
	if targetPos:DistToSqr(veh:GetPos()) > (REACH_VEHICLE + hull) * (REACH_VEHICLE + hull) then return false end

	return true
end

local function forceSeatIn(actor, target, pod)
	if not canForceSeat(actor, target, pod) then return false end

	-- One forced move at a time; 2s window to pass our enter blockers.
	if (target[SEAT_DELAY] or 0) > CurTime() then return false end
	target[SEAT_DELAY] = CurTime() + 2

	target.zc_lvs_force_seat = CurTime() + 2
	ZC_LVS.MarkSeatSwitch(target)

	if not target:EnterVehicle(pod) then
		target.zc_lvs_force_seat = nil
		return false
	end
	ZC_LVS.DebugLog("forceseat_in",
		"actor=" .. actor:EntIndex(),
		"target=" .. target:EntIndex(),
		"pod=" .. pod:EntIndex(),
		"veh=" .. (ZC_LVS.GetChassis(pod):GetClass() or "?"))
	return true
end

local function forceSeatOut(actor, target)
	if not ZC_LVS.Enabled() then return false end
	if not GetConVar("zc_lvs_forceseat"):GetBool() then return false end
	if not IsValid(actor) or not actor:Alive() then return false end
	if ZC_LVS.IsUnconscious(actor) then return false end
	if not ZC_LVS.HasEmptyHands(actor) then return false end

	local pod = IsValid(target) and target.GetVehicle and target:GetVehicle() or NULL
	if not IsValid(pod) or not ZC_LVS.IsLVSSeat(pod) then return false end

	-- Near the machine they are being pulled from.
	local veh = ZC_LVS.GetChassis(pod)
	local podPos = IsValid(veh) and veh:GetPos() or pod:GetPos()
	if actor:GetPos():DistToSqr(podPos) > REACH_VEHICLE * REACH_VEHICLE then return false end

	if (target[SEAT_DELAY] or 0) > CurTime() then return false end
	target[SEAT_DELAY] = CurTime() + 2

	target.zc_lvs_force_seat = CurTime() + 2
	target.zc_lvs_allow_exit = CurTime() + 2
	target:ExitVehicle()

	-- Knocked out: the freed ragdoll simply stays where it was dropped.
	if not ZC_LVS.IsUnconscious(target) then
		timer.Simple(0, function()
			if IsValid(target) and not target:InVehicle() then
				ZC_LVS.AllowExit(target, 1.5)
			end
		end)
	end
	ZC_LVS.DebugLog("forceseat_out",
		"actor=" .. actor:EntIndex(),
		"target=" .. target:EntIndex(),
		"pod=" .. pod:EntIndex())
	return true
end

net.Receive("zc_lvs_forceseat", function(len, ply)
	if not IsValid(ply) then return end
	local target = net.ReadEntity()
	local pod = net.ReadEntity()
	local wantIn = net.ReadBool()

	local ok
	if wantIn then
		ok = IsValid(pod) and forceSeatIn(ply, target, pod)
	else
		ok = forceSeatOut(ply, target)
	end

	-- Quiet feedback: no chat spam, the state itself is the feedback.
	if not ok then
		ply:PrintMessage(HUD_PRINTCENTER, "Не получилось")
	end
end)
