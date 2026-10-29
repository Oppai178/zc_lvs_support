--[[
	[Z-CITY] LVS SUPPORT
	Author: Oppai

	Force seat, client side: radial menu entries (Z-City radialOptions
	hook). Shows "Посадить" / "Вытащить" when the eye trace is on an LVS
	vehicle (or its seated occupant) and a second player is nearby.
]]

ZC_LVS = ZC_LVS or {}

local REACH_TARGET = 120

local function nearbyForceTarget()
	local lply = LocalPlayer()
	if not IsValid(lply) or not lply:Alive() then return nil end
	if not ZC_LVS.Enabled() then return nil end
	if not GetConVar("zc_lvs_forceseat"):GetBool() then return nil end
	if ZC_LVS.IsUnconscious(lply) then return nil end

	for _, ply in player.Iterator() do
		if ply == lply or not IsValid(ply) or not ply:Alive() then continue end
		-- Seated in an LVS vehicle: candidate for "Вытащить".
		local pod = ply:GetVehicle()
		if IsValid(pod) and ZC_LVS.IsLVSSeat(pod) then
			local veh = ZC_LVS.GetChassis(pod)
			local vehPos = IsValid(veh) and veh:GetPos() or pod:GetPos()
			if lply:GetPos():DistToSqr(vehPos) < 160 * 160 then
				return ply, nil, false
			end
		-- Not seated but has a fake (tied / knocked out / dragged):
		-- candidate for "Посадить" into the traced vehicle.
		elseif (IsValid(ply.FakeRagdoll) or ZC_LVS.IsUnconscious(ply))
			and not ply:InVehicle() then
			local pos = IsValid(ply.FakeRagdoll) and ply.FakeRagdoll:GetPos() or ply:GetPos()
			if lply:GetPos():DistToSqr(pos) < REACH_TARGET * REACH_TARGET then
				return ply, nil, true
			end
		end
	end
	return nil
end

-- The pod the local player is looking at: the LVS chassis or a child pod.
local function tracedSeatPod()
	if not isfunction(hg.eyeTrace) then return NULL end
	local lply = LocalPlayer()
	local tr = hg.eyeTrace(lply)
	local ent = tr and tr.Entity
	if not IsValid(ent) then return NULL end

	-- Direct hit on a pod.
	if ZC_LVS.IsLVSSeat(ent) then return ent end

	-- Hit on the chassis: use its first free passenger pod, else driver.
	local veh = ent
	if not veh.LVS then
		veh = ZC_LVS.GetChassis(ent)
	end
	if not IsValid(veh) or not veh.LVS then return NULL end

	local driverSeat = isfunction(veh.GetDriverSeat) and veh:GetDriverSeat() or NULL
	if IsValid(driverSeat) and not IsValid(driverSeat:GetDriver()) then
		return driverSeat
	end
	if isfunction(veh.GetPassengerSeats) then
		local seats = veh:GetPassengerSeats()
		if istable(seats) then
			for i = 1, #seats do
				local pod = seats[i]
				if IsValid(pod) then
					local seated = pod.GetDriver and pod:GetDriver()
					if not IsValid(seated) then
						return pod
					end
				end
			end
		end
	end
	return NULL
end

hook.Add("radialOptions", "zc_lvs_forceseat", function()
	local lply = LocalPlayer()
	if not IsValid(lply) then return end
	if not ZC_LVS.HasEmptyHands(lply) then return end

	local target, _, wantIn = nearbyForceTarget()
	if not target then return end

	if wantIn then
		local pod = tracedSeatPod()
		if not IsValid(pod) then return end
		hg.radialOptions = hg.radialOptions or {}
		hg.radialOptions[#hg.radialOptions + 1] = {
			function()
				net.Start("zc_lvs_forceseat")
					net.WriteEntity(target)
					net.WriteEntity(pod)
					net.WriteBool(true)
				net.SendToServer()
			end,
			"Посадить " .. (target:Nick() or "?"),
		}
	else
		hg.radialOptions = hg.radialOptions or {}
		hg.radialOptions[#hg.radialOptions + 1] = {
			function()
				net.Start("zc_lvs_forceseat")
					net.WriteEntity(target)
					net.WriteEntity(NULL)
					net.WriteBool(false)
				net.SendToServer()
			end,
			"Вытащить " .. (target:Nick() or "?"),
		}
	end
end)
