-- [Z-CITY] LVS SUPPORT
-- Author: Oppai

ZC_LVS = ZC_LVS or {}

hook.Add("PlayerBindPress", "!!!!zc_lvs_block_open_car_grab", function(ply, bind, pressed)
	if not pressed or not ZC_LVS.Enabled() or not IsValid(ply) or not ply:InVehicle() then return end
	local veh = ZC_LVS.GetChassis(ply:GetVehicle())
	if not IsValid(veh) or not ZC_LVS.IsOpenCarHull(veh) then return end
	if bind == "+speed" or bind == "+walk" then return true end
end)

local SLOT_BINDS = {
	slot1 = true,
	slot2 = true,
	slot3 = true,
	slot4 = true,
	slot5 = true,
	slot6 = true,
	slot7 = true,
	slot8 = true,
	slot9 = true,
	slot0 = true,
	invnext = true,
	invprev = true,
}

local function keyFromBind(bindName, fallback)
	local name = input.LookupBinding(bindName)
	if isstring(name) then
		local code = input.GetKeyCode(name)
		if isnumber(code) and code > 0 then
			return code
		end
	end
	return fallback
end

local function applyWeaponBinds()
	local keys = {KEY_1, KEY_2, KEY_3, KEY_4}
	for i = 1, 4 do
		local name = "lvs_select_weapon" .. i
		local cvar = GetConVar(name)
		if cvar then
			if cvar:GetInt() ~= keys[i] then
				cvar:SetInt(keys[i])
			end
		else
			CreateClientConVar(name, tostring(keys[i]), true, true)
		end
	end

	-- Keep EXIT on +use (E). Walk is often Alt; that must not leave the vehicle.
	local exitCvar = GetConVar("lvs_exit")
	if exitCvar then
		local useKey = keyFromBind("+use", KEY_E)
		if exitCvar:GetInt() ~= useKey then
			exitCvar:SetInt(useKey)
		end
	end

	local ply = LocalPlayer()
	if IsValid(ply) and ply.lvsBuildControls then
		ply:lvsBuildControls()
	end
end

hook.Add("InitPostEntity", "zc_lvs_weapon_binds", function()
	timer.Simple(0.5, applyWeaponBinds)
	timer.Simple(2, applyWeaponBinds)
end)

hook.Add("LVS:Initialize", "zc_lvs_weapon_binds", function()
	timer.Simple(0.2, applyWeaponBinds)
end)

hook.Add("LVS.PlayerEnteredVehicle", "zc_lvs_rebuild_binds", function()
	applyWeaponBinds()
end)

-- Civilian car: LVS ZOOM (RMB) yeets the camera. Keep ZC zoom.
local function wrapLVSZoom()
	local ply = LocalPlayer()
	if not IsValid(ply) or not isfunction(ply.lvsKeyDown) then return end
	if ply.zc_lvs_zoomwrap then return end
	ply.zc_lvs_zoomwrap = true
	local old = ply.lvsKeyDown
	ply.lvsKeyDown = function(self, name)
		if name == "ZOOM" and ZC_LVS.ShouldUseZCityCamera(self) then
			return false
		end
		return old(self, name)
	end
end

hook.Add("PlayerEnteredVehicle", "zc_lvs_no_lvs_zoom", function(ply)
	if ply ~= LocalPlayer() then return end
	timer.Simple(0, wrapLVSZoom)
end)

hook.Add("PlayerBindPress", "zc_lvs_no_hl2_zoom", function(ply, bind, pressed)
	if not ZC_LVS.Enabled() or not pressed then return end
	if not ZC_LVS.ShouldUseZCityCamera(ply) then return end
	if bind == "+zoom" or bind == "zoom" then
		return true
	end
end)

-- Stop Z-City's slot selector from eating 1-6 while in LVS.
local function wrapWeaponSelector()
	local hooks = hook.GetTable().PlayerBindPress
	if not hooks or not hooks["WeaponSelector_PlayerBindPress"] or ZC_LVS._wrappedWepSel then return end

	ZC_LVS._wrappedWepSel = true
	local old = hooks["WeaponSelector_PlayerBindPress"]
	hook.Add("PlayerBindPress", "WeaponSelector_PlayerBindPress", function(ply, bind, pressed)
		if ZC_LVS.Enabled() and pressed and SLOT_BINDS[bind] and IsValid(ply) and ZC_LVS.ShouldBlockZCWeapons(ply) then
			return true
		end
		return old(ply, bind, pressed)
	end)
end

hook.Add("InitPostEntity", "zc_lvs_wrap_wepsel", function()
	timer.Simple(0, wrapWeaponSelector)
	timer.Simple(2, wrapWeaponSelector)
end)

timer.Simple(0, wrapWeaponSelector)

hook.Add("PlayerBindPress", "zc_lvs_block_zc_slots", function(ply, bind, pressed)
	if not ZC_LVS.Enabled() then return end
	if not pressed then return end
	if not SLOT_BINDS[bind] then return end
	if not IsValid(ply) then return end
	if not ZC_LVS.ShouldBlockZCWeapons(ply) then return end
	return true
end)

-- Z/C and the ZC HUD selector in hatch/gun/air. LVS 1-4 still work via LVS binds.
hook.Add("PlayerBindPress", "zc_lvs_block_zc_wepsel", function(ply, bind, pressed)
	if not ZC_LVS.Enabled() then return end
	if not pressed then return end
	if not IsValid(ply) then return end
	if not ZC_LVS.ShouldBlockZCWeapons(ply) then return end
	if SLOT_BINDS[bind] or bind == "invnext" or bind == "invprev" then
		return true
	end
	if string.find(bind, "slot", 1, true) then
		return true
	end
end)
