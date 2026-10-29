-- [Z-CITY] LVS SUPPORT
-- Author: Oppai

ZC_LVS = ZC_LVS or {}

local hintColor = Color(255, 255, 255, 230)

local function keptVehicleOf(ent)
	if not IsValid(ent) then return NULL end
	if ent.GetNWEntity then
		local veh = ent:GetNWEntity("zc_lvs_keep_veh")
		if IsValid(veh) then return veh end
	end
	if ent:GetClass() == "prop_ragdoll" and ent.GetNWEntity then
		local owner = ent:GetNWEntity("ply")
		if IsValid(owner) and owner.GetNWEntity then
			local cargo = owner:GetNWEntity("zc_lvs_cargo")
			if IsValid(cargo) then return cargo end
		end
	end
	return NULL
end

hook.Add("HUDPaint", "zc_lvs_cargo", function()
	if not ZC_LVS.Enabled() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	local cx, cy = ScrW() * 0.5, ScrH() * 0.82

	if ply:InVehicle() then return end

	local ownRag = ply.FakeRagdoll
	if not IsValid(ownRag) and ply.GetNWEntity then
		ownRag = ply:GetNWEntity("FakeRagdoll")
	end
	if IsValid(ownRag) then
		local ownVeh = keptVehicleOf(ownRag)
		if IsValid(ownVeh) then
			draw.SimpleText("лежит в кузове", "DermaDefault", cx, cy, hintColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			return
		end
	end

	local tr = ply:GetEyeTrace()
	local ent = IsValid(tr.Entity) and tr.Entity or NULL
	if not IsValid(ent) then return end
	if ply:GetPos():DistToSqr(ent:WorldSpaceCenter()) > 170 * 170 then return end

	local veh = keptVehicleOf(ent)
	if not IsValid(veh) then return end

	draw.SimpleText("лежит в кузове", "DermaDefault", cx, cy, hintColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	local atDoor = ZC_LVS.IsInOpenDoorway and ZC_LVS.IsInOpenDoorway(veh, ply:GetPos())
	if not atDoor and ZC_LVS.IsAtRear then
		atDoor = ZC_LVS.IsAtRear(ply, veh)
	end
	if atDoor then
		draw.SimpleText("E — выгрузить", "DermaDefault", cx, cy + 18, hintColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end)
