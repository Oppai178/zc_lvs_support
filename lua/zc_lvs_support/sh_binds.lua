--[[
	[Z-CITY] LVS SUPPORT — РАЗВЕДЕНИЕ КЛАВИШ (shared)
	Author: Oppai

	Проблема: у LVS и Z-City одни и те же клавиши значат разное.
	  Цифры 1-0 : LVS = оружие техники, Z-City = слоты личного оружия
	  Alt       : LVS = FREELOOK (осмотр), Z-City = «идти шагом»
	  Ctrl      : LVS = третье лицо, Z-City = присесть/наклон
	  R         : LVS = двигатель, Z-City = перезарядка

	Здесь мы разводим их по контексту. Обёртки ставятся на хуки LVS
	("!!!lvsButtonDown", "!!!lvsSeatSwitcherButtonDown") — они
	регистрируются позже нас, поэтому ловим их ретраями.

	Итоговое управление:
	  1-0        — оружие техники
	  Alt + 1-0  — смена места
	  E          — выход (Alt НЕ выходит, это «шаг» у ZC)
	  ПКМ        — прицел LVS на месте стрелка
	  Ctrl       — наклон Z-City в открытой машине (третьего лица нет)
]]

ZC_LVS = ZC_LVS or {}

local ALT_KEYS = {
	[KEY_LALT] = true,
	[KEY_RALT] = true,
}

-- Оборачиваем хуки кнопок LVS. Хуки LVS появляются не сразу, поэтому
-- пробуем на InitPostEntity, LVS:Initialize и раз в секунду (до 20 раз).
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
				-- В отключке никакие клавиши техники не работают.
				if ZC_LVS.IsUnconscious(ply) then
					return
				end
				-- Alt в машине — только модификатор смены места.
				-- В авиации пропускаем его в LVS как FREELOOK (осмотр).
				if ALT_KEYS[button] then
					if ZC_LVS.ShouldUseLVSCamera(ply) then
						return oldDown(ply, button)
					end
					return
				end
				-- Alt+цифра = смена места. LVS не должен считать это оружием.
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
			-- В открытых машинах смену мест ведёт Z-City (как в Glide),
			-- наш переключатель там не нужен.
			local chassis = ZC_LVS.GetChassis(ply:GetVehicle())
			if IsValid(chassis) and ZC_LVS.IsOpenCarHull(chassis) then return end
			if ZC_LVS.IsUnconscious(ply) then
				return
			end
			if not ZC_LVS.HoldingAlt(ply) then
				return
			end

			-- Не проверяем lastswitched: этот флаг ставят и клавиши оружия,
			-- и mark-хук — из-за него Alt+цифра не работала.
			if ply.zc_lvs_switch_press and ply.zc_lvs_switch_press > CurTime() then
				return
			end
			ply.zc_lvs_switch_press = CurTime() + 0.25

			-- ВАЖНО: внутри oldSwitch LVS вызывает ExitVehicle ДО
			-- OnPlayerRequestSeatSwitch. Помечаем смену места заранее,
			-- иначе Z-City поднимет игрока на ноги (FakeUp) вместо
			-- пересадки, и на скорости тело выкинет.
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
	-- R — это и двигатель LVS, и перезарядка Z-City. Глушим двигатель
	-- только с пустыми руками: с оружием R должна перезаряжать, а не
	-- глушить машину.
	if name == "ENGINE" and not ZC_LVS.HasEmptyHands(ply) then
		return false
	end
	-- THIRDPERSON у LVS висит на +duck. Но Ctrl с фейком — это наклон
	-- Z-City (ноги уходят из вида, ты откидываешься назад). Одно нажатие
	-- заодно переключало погонную камеру LVS — глушим в открытой машине.
	if name == "THIRDPERSON" then
		local veh = ZC_LVS.GetVehicle(ply)
		if ZC_LVS.IsOpenCarHull(veh) then
			return false
		end
	end
end)

-- Если Ctrl уже переключил вид до нашего хука — возвращаем обратно.
-- В стоке LVS ThirdPersonMode — метод ШАССИ (lvs_hookers.lua зовёт
-- vehicle:SetThirdPersonMode). Некоторые паки определяют его и на поде,
-- поэтому сбрасываем оба, но только если метод реально существует.
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
	-- Цифры 5-0: LVS сам обрабатывает только 1-4, остальные добираем
	-- через оружейный хендлер. С Alt не срабатывает — это смена места.
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
