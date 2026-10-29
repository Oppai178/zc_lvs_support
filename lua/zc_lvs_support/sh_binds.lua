-- [Z-CITY] LVS SUPPORT
-- Author: Oppai

ZC_LVS = ZC_LVS or {}

local ALT_KEYS = {
	[KEY_LALT] = true,
	[KEY_RALT] = true,
}

local function wrapLVSBinds()
	local hooks = hook.GetTable().PlayerButtonDown
	if not hooks then return end
	ZC_LVS._wrapBindTries = (ZC_LVS._wrapBindTries or 0) + 1
	if ZC_LVS._wrappedLVSButtons and (not SERVER or ZC_LVS._wrappedSeatSwitch) then
		timer.Remove("zc_lvs_wrap_binds_retry")
		return
	end
	if ZC_LVS._wrapBindTries > 20 then
		timer.Remove("zc_lvs_wrap_binds_retry")
	end

	if hooks["!!!lvsButtonDown"] and not ZC_LVS._wrappedLVSButtons then
		ZC_LVS._wrappedLVSButtons = true
		local oldDown = hooks["!!!lvsButtonDown"]
		hook.Add("PlayerButtonDown", "!!!lvsButtonDown", function(ply, button)
			if ZC_LVS.Enabled() and IsValid(ply) and ply.lvsGetVehicle and IsValid(ply:lvsGetVehicle()) then
				if ZC_LVS.IsUnconscious(ply) then
					return
				end
				-- Walk is often Alt. In cars Alt is seat-switch only.
				-- In aircraft let LVS see Alt as FREELOOK (look around).
				if ALT_KEYS[button] then
					if ZC_LVS.ShouldUseLVSCamera(ply) then
						return oldDown(ply, button)
					end
					return
				end
				-- Alt+1-0 is seat switch. Never let LVS treat it as a weapon.
				if ZC_LVS.WEAPON_KEYS[button] and ZC_LVS.HoldingAlt(ply) then
					return
				end
			end
			return oldDown(ply, button)
		end)
	end

	if SERVER and hooks["!!!lvsSeatSwitcherButtonDown"] and not ZC_LVS._wrappedSeatSwitch then
		ZC_LVS._wrappedSeatSwitch = true
		local oldSwitch = hooks["!!!lvsSeatSwitcherButtonDown"]
		hook.Add("PlayerButtonDown", "!!!lvsSeatSwitcherButtonDown", function(ply, button)
			if not ZC_LVS.Enabled() then
				return oldSwitch(ply, button)
			end
			if not ZC_LVS.WEAPON_KEYS[button] then
				return
			end
			local chassis = ZC_LVS.GetChassis(ply:GetVehicle())
			if IsValid(chassis) and ZC_LVS.IsOpenCarHull(chassis) then return end
			if ZC_LVS.IsUnconscious(ply) then
				return
			end
			if not ZC_LVS.HoldingAlt(ply) then
				return
			end

			-- Do not abort on lastswitched: that flag is also set by
			-- weapon keys / the mark-hook, and it blocked Alt+digit.
			if ply.zc_lvs_switch_press and ply.zc_lvs_switch_press > CurTime() then
				return
			end
			ply.zc_lvs_switch_press = CurTime() + 0.25

			-- LVS ExitVehicle runs inside oldSwitch, before
			-- OnPlayerRequestSeatSwitch. Mark first so ZC FakeUp's
			-- instead of yeeting the ragdoll at speed.
			if ZC_LVS.MarkSeatSwitch then
				ZC_LVS.MarkSeatSwitch(ply)
			else
				ply.switchingseat = true
				ply.lastswitched = CurTime() + 1.5
			end

			return oldSwitch(ply, button)
		end)
	end
end

hook.Add("InitPostEntity", "zc_lvs_wrap_binds", function()
	timer.Simple(0, wrapLVSBinds)
	timer.Simple(1, wrapLVSBinds)
	timer.Simple(3, wrapLVSBinds)
end)

hook.Add("LVS:Initialize", "zc_lvs_wrap_binds", function()
	timer.Simple(0, wrapLVSBinds)
end)

timer.Simple(0, wrapLVSBinds)
timer.Create("zc_lvs_wrap_binds_retry", 1, 0, wrapLVSBinds)

hook.Add("LVS.PlayerKeyDown", "zc_lvs_otrub", function(ply, name, pressed)
	if not pressed then return end
	if not ZC_LVS.Enabled() then return end
	if ZC_LVS.IsUnconscious(ply) then
		return false
	end
	-- R is both LVS ENGINE and weapon reload. Only mute the engine
	-- when hands are empty; a gun should reload, not stall the car.
	if name == "ENGINE" and not ZC_LVS.HasEmptyHands(ply) then
		return false
	end
	-- LVS THIRDPERSON defaults to +duck. CTRL on a fake is the Z-City
	-- lean (legs leave the view, you sit back). Clip 18.55: that press
	-- also toggled the LVS chase camera.
	if name == "THIRDPERSON" then
		local veh = ZC_LVS.GetVehicle(ply)
		if ZC_LVS.IsOpenCarHull(veh) then
			return false
		end
	end
end)

-- If CTRL already flipped the view before the key hook, put it back.
-- ThirdPersonMode is a CHASSIS method in stock LVS (lvs_hookers.lua
-- calls vehicle:SetThirdPersonMode). Some packs also define it on pods;
-- reset both when present, never call a method that does not exist.
hook.Add("Think", "zc_lvs_no_open_car_tp", function()
	if not ZC_LVS.Enabled() then return end
	for _, ply in player.Iterator() do
		if not ply:InVehicle() then continue end
		local pod = ply:GetVehicle()
		local veh = ZC_LVS.GetChassis(pod)
		if not ZC_LVS.IsOpenCarHull(veh) then continue end
		local targets = { veh, pod }
		for i = 1, 2 do
			local ent = targets[i]
			if IsValid(ent)
				and isfunction(ent.GetThirdPersonMode)
				and ent:GetThirdPersonMode()
				and isfunction(ent.SetThirdPersonMode) then
				ent:SetThirdPersonMode(false)
			end
		end
	end
end)

if SERVER then
	hook.Add("PlayerButtonDown", "zc_lvs_extra_weapons", function(ply, button)
		if not ZC_LVS.Enabled() then return end
		if not IsValid(ply) or not ply.lvsGetWeaponHandler then return end
		if ZC_LVS.IsUnconscious(ply) then return end
		if ZC_LVS.HoldingAlt(ply) then return end

		local id = ZC_LVS.WEAPON_KEYS[button]
		if not id or id < 5 then return end

		local base = ply:lvsGetWeaponHandler()
		if IsValid(base) then
			base:SelectWeapon(id)
		end
	end)
end
