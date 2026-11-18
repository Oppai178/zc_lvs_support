--[[
	[Z-CITY] LVS SUPPORT — HE-СНАРЯДЫ (сервер)
	Author: Oppai

	Что делает: когда LVS взрывает HE-снаряд, бомбу или мину, поверх
	родного урона LVS проигрывается НАСТОЯЩИЙ взрывной конвейер Z-City:
	осколки, звук детонации гранаты, частицы jack-airsplode, тряска
	экрана, след копоти. Файлы LVS не патчатся — оборачивается
	LVS:BlastDamage.

	КАК УСТРОЕН УРОН LVS (важно понимать, прочитано в исходниках
	lvs_framework/init.lua:79 и lvs_bulletsystem.lua)

	  1. Орудие/бомба зовёт LVS:BlastDamage(pos, dir, attacker, inflictor,
	     damage, damagetype, radius, force).
	  2. Внутри LVS ПЕРЕКЛЮЧАЕТ DMG_BLAST -> DMG_SONIC и применяет
	     util.BlastDamageInfo по сфере.
	  3. Затем 16 трасс «осколков» + обход техники в сфере: каждому
	     попавшему LVS-энтити наносится DMG_BLAST, пересчитанный по числу
	     попаданий (DamageBoost).

	  Отсюда два следствия, из-за которых раньше ломалось:
	    - inflictor/attacker это НЕ шасси: у снаряда это lvs_base_gunner
	      (у него LVS_GUNNER, но НЕТ .LVS), у бомбы — сама бомба
	      (lvsProjectile). Поэтому любой фильтр по src.LVS молча не
	      срабатывал. Разбор цепочки — см. lvsRoot в sv_organism.lua.
	    - до наших хуков урон приходит как DMG_SONIC, а не DMG_BLAST.

	ОТКУДА БЕРУТСЯ ОСКОЛКИ Z-CITY
	  Это копия механики F1/RGN (ent_hg_grenade/init.lua): FireLuaBullets
	  с AmmoType "Metal Debris" (sh_ammostuff.lua: Damage 16, Speed 700,
	  Penetration 8), направление — полусфера со смещением вверх,
	  QuickTrace-фильтр (осколок летит только если в этой стороне есть
	  энтити), а чтобы не подвесить сервер — корутина в общей таблице
	  Z-City APScheduledExplosions (её разгоняет Think-хук самого ZC).
	  Если таблицы нет (чистый ZC другого билда) — сливаем синхронно.
]]

ZC_LVS = ZC_LVS or {}

CreateConVar("zc_lvs_he_fx", "1", FCVAR_ARCHIVE, "LVS HE/splash uses Z-City explosion FX", 0, 1)

local lastBoom = 0
local lastPos = vector_origin
local coCounter = 0

-- ZC grenade detonate sounds (ent_hg_grenade/shared.lua) — played on the
-- client through Z-City's own "projectileFarSound" receiver with distance
-- delay, near AND far variant (cl part of entities/projectile_base.lua).
local SND_NEAR = {
	"m67/m67_detonate_01.wav",
	"m67/m67_detonate_02.wav",
	"m67/m67_detonate_03.wav",
}
local SND_FAR = {
	"m67/m67_detonate_far_dist_01.wav",
	"m67/m67_detonate_far_dist_02.wav",
	"m67/m67_detonate_far_dist_03.wav",
}
local SND_WATER = "m67/water/m67_water_detonate_01.wav"

-- Осколки по механике гранаты Z-City. Зеркало
-- ent_hg_grenade/init.lua ENT:Explode -> корутина FireLuaBullets.
-- Направления — случайная полусфера со смещением вверх, QuickTrace-
-- фильтр (осколок летит только в сторону энтити, не в небо/землю),
-- боеприпас "Metal Debris" (Speed 700, Penetration 8 в sh_ammostuff.lua).
local function zcShrapnel(pos, attacker, inflictor, fragments, fragDamage, fragDistance, fragPen, filter)
	local world = game.GetWorld()
	if not isfunction(world.FireLuaBullets) then return end

	local bullet = {}
	bullet.Src = pos
	bullet.Spread = vector_origin
	bullet.Force = 20
	bullet.Damage = fragDamage
	bullet.Speed = 700 -- BulletSettings.Speed у "Metal Debris", как у гранаты
	bullet.Penetration = fragPen
	bullet.AmmoType = "Metal Debris"
	bullet.Attacker = IsValid(attacker) and attacker or world
	bullet.Inflictor = IsValid(inflictor) and inflictor or world
	bullet.Distance = fragDistance
	bullet.DisableLagComp = true
	bullet.Filter = filter
	bullet.TraceFilter = filter -- путь phys_bullets читает именно TraceFilter
	bullet.IgnoreEntity = filter[1]
	-- hg.bulletHit — обработчик попаданий ZC (ранения, кровь). Без него
	-- осколок нанесёт голый урон без органики.
	if isfunction(hg.bulletHit) then
		bullet.Callback = hg.bulletHit
	end

	local co = coroutine.create(function()
		local lastShrapnel = SysTime()
		for _ = 1, fragments do
			lastShrapnel = SysTime()

			-- Полусфера со смещением вверх — как у гранаты ZC.
			local dir = VectorRand(-1, 1):GetNormalized()
			dir.z = dir.z > 0 and math.abs(dir.z - 0.5) or -math.abs(dir.z + 0.5)
			dir:Normalize()

			-- Осколок летит только если в этой стороне есть энтити.
			local tr = util.QuickTrace(pos, dir * 10000, filter)
			if tr.Hit and not tr.HitSky and not tr.HitWorld then
				bullet.Dir = dir
				pcall(world.FireLuaBullets, world, bullet, true)
			end

			-- Отдаём управление, если пачка заняла больше 1 мс — иначе
			-- 900 осколков подвесили бы сервер на кадр.
			lastShrapnel = SysTime() - lastShrapnel
			if lastShrapnel > 0.001 then
				coroutine.yield()
			end
		end
	end)

	-- Планирование без сущности — ровно как у взрывных боеприпасов Z-City
	-- (sh_ammostuff.lua, Think-хук APScheduledExplosions). Если таблицы
	-- нет (другой билд ZC), сливаем корутину синхронно.
	if istable(APScheduledExplosions) then
		coCounter = coCounter + 1
		local id = "zc_lvs_he_" .. coCounter
		APScheduledExplosions[id] = co
		coroutine.resume(co)
	else
		while coroutine.status(co) == "suspended" do
			coroutine.resume(co)
		end
	end
end

-- Главная функция взрыва. Вызывается из обёртки LVS:BlastDamage.
-- Порядок: контузия экипажа -> контузия стоящих рядом -> осколки -> FX.
-- Контузия идёт ДО проверки FX-конвара: это урон, а не косметика.
local function zcHeBoom(pos, radius, damage, attacker, inflictor)
	if not isvector(pos) then return end
	radius = tonumber(radius) or 0
	damage = tonumber(damage) or 0
	-- МАЛЫЙ КАЛИБР: 20-мм автопушки и прочий лёгкий HE (radius < 48 и
	-- damage < 25) получают полноценный взрыв Z-City в масштабе РГН,
	-- включая родную механику осколков. Крупные снаряды идут по тому же
	-- конвейеру, отличается только масштаб.
	local small = radius < 48 and damage < 25
	if radius < 12 and damage < 5 then return end -- пыль от попадания пули, не HE

	local now = CurTime()
	-- Фильтр спама: очередь автопушки раскладывает попадания по земле и
	-- целям, поэтому гасим только повтор В ОДНОЙ ТОЧКЕ внутри окна
	-- (0.12 с малый / 0.04 с крупный). Очередь не теряет все взрывы сразу.
	local spamT = small and 0.12 or 0.04
	if now - lastBoom < spamT and lastPos:DistToSqr(pos) < 64 * 64 then
		return
	end
	lastBoom = now
	lastPos = pos

	-- Радиус поражения контузией — не меньше разумного, иначе осколок
	-- 20-мм снаряда никого не задевал.
	local reach = math.max(radius, small and 90 or 120)

	-- HE рядом с бронёй. Контур контузии Z-City трогает только те сущности,
	-- которые сфера видит напрямую; сидящие в закрытом корпусе (их фейк
	-- припарентован под корпусом) этот FindInSphere не проходят. Поэтому
	-- контузию доводим до экипажа через корпус со скидкой на броню.
	-- AddForceRag сидячим фейкам не зовём намеренно: припарентованный
	-- регдолл скорости не получает, это ломало физику корпуса.
	if hg then
		for _, veh in ipairs(ents.FindInSphere(pos, reach)) do
			if not IsValid(veh) or not veh.LVS then continue end
			if not ZC_LVS.IterOccupants then break end
			local closed = ZC_LVS.IsClosedVehicle(veh) and not ZC_LVS.IsAircraft(veh)
			local dist = veh:WorldSpaceCenter():Distance(pos)
			local frac = 1 - math.Clamp(dist / reach, 0, 1)
			if frac <= 0 then continue end
			ZC_LVS.IterOccupants(veh, function(ply)
				local org = ply.organism
				if not org then return end
				-- Закрытая броня гасит взрыв: слабее тряска, без контузии.
				local scale = closed and 0.25 or 1
				if small then scale = scale * 0.5 end
				org.disorientation = math.min((org.disorientation or 0) + 5 * frac * scale, 8)
				if isfunction(ply.AddTinnitus) then
					ply:AddTinnitus(4 * frac * scale)
				end
				-- Ближний разрыв открытого корпуса крупным снарядом валит
				-- в отключку. Уже отключённого не трогаем.
				if not closed and not small and frac > 0.45 and not ZC_LVS.IsUnconscious(ply) then
					org.needotrub = true
				end
			end)
		end
	end

	-- Z-City native concussion for everyone the blast actually sees
	-- (grenade's disorientation loop, weapon_traitor_ied.lua:166).
	-- FIX 09.10 (crash from the log): ZC ExplosionDisorientation calls
	-- ent.AddTinnitus — fakes (prop_ragdoll) don't have it → "call nil as
	-- function" + "net.Send to non-player". Only real players pass here;
	-- seated players get their concussion through the hull loop above.
	if hg and isfunction(hg.ExplosionDisorientation) then
		for _, ent in ipairs(ents.FindInSphere(pos, reach)) do
			if IsValid(ent) and ent:IsPlayer() and ent.organism then
				local frac = 1 - math.Clamp(ent:GetPos():Distance(pos) / reach, 0, 1)
				pcall(hg.ExplosionDisorientation, ent, 4 * frac * (small and 0.5 or 1), 5 * frac * (small and 0.5 or 1))
			end
		end
	end

	-- Фильтр осколков: стрелок и его собственное орудие/техника не должны
	-- получать свои же осколки.
	local filter = {}
	if IsValid(attacker) then filter[#filter + 1] = attacker end
	if IsValid(inflictor) and inflictor ~= attacker then filter[#filter + 1] = inflictor end

	if GetConVar("zc_lvs_shrapnel"):GetBool() then
		-- Граната F1 = 300*3 осколков (ent_hg_grenade/shared.lua:13).
		-- Малый калибр = масштаб РГН 0.55, крупные снаряды растут с радиусом.
		local scale = small and 0.55 or math.Clamp(radius / 110, 0.9, 1.5)
		local fragments = math.Round((small and 450 or 900) * scale)
		-- У малых урон осколка срезан: прямой урон LVS по ним уже прошёл.
		local fragDamage = small and 12 or 40
		local fragDistance = small and 700 or 2500
		local fragPen = small and 5 or 8 -- Penetration как у гранаты
		zcShrapnel(pos, attacker, inflictor, fragments, fragDamage, fragDistance, fragPen, filter)
	end

	-- Дальше только косметика: её можно выключить конваром.
	if not GetConVar("zc_lvs_he_fx"):GetBool() then return end

	-- Проверка воды: граната смотрит WaterLevel сущности, у нас сущности
	-- нет — проверяем содержимое самой точки.
	local inWater = bit.band(util.PointContents(pos), MASK_WATER) ~= 0

	-- Звук детонации через собственный приёмник Z-City: ближний и дальний
	-- варианты с настоящей задержкой по расстоянию
	-- (entities/projectile_base.lua:317). Порядок полей важен — приёмник
	-- читает их именно так.
	pcall(function()
		net.Start("projectileFarSound")
		net.WriteString(SND_NEAR[math.random(#SND_NEAR)])
		net.WriteString(SND_FAR[math.random(#SND_FAR)])
		net.WriteVector(pos)
		net.WriteEntity(Entity(0))
		net.WriteBool(inWater)
		net.WriteString(inWater and SND_WATER or "")
		net.SendPVS(pos)
	end)

	-- Частицы взрыва Z-City: airsplode_small3 для малых калибров,
	-- airsplode_medium (из projectile_base) для крупных, в воде — общий
	-- взрыв. Зарегистрированы самим Z-City (game.AddParticles).
	pcall(function()
		if inWater then
			local ed = EffectData()
			ed:SetOrigin(pos)
			ed:SetScale(small and 1 or 3)
			ed:SetNormal(vector_up)
			util.Effect("eff_jack_genericboom", ed, true, true)
		else
			ParticleEffect(small and "pcf_jack_airsplode_small3" or "pcf_jack_airsplode_medium", pos, -vector_up:Angle())
		end
		-- Вторичная вспышка осколков, как Poof у гранаты.
		local poof = EffectData()
		poof:SetOrigin(pos)
		poof:SetScale(1.2)
		util.Effect("eff_jack_hmcd_shrapnel", poof, true, true)
	end)

	util.ScreenShake(pos, 35, 200, 1, small and 600 or 2000)

	-- След копоти только для крупного: очередь автопушки иначе зататуирует
	-- всю карту. Одна трасса вниз, один декаль.
	if not small then
		local tr = util.QuickTrace(pos, -vector_up * 500, filter)
		if tr.Hit then
			util.Decal("Scorch", tr.HitPos + tr.HitNormal, tr.HitPos - tr.HitNormal)
		end
	end
end

-- Обёртка над LVS:BlastDamage. Сначала даём LVS нанести свой урон
-- (иначе HE перестанет пробивать корпуса вообще), затем добавляем наш
-- конвейер. Флаг _wrappedBlast защищает от двойной обёртки при
-- перезагрузке файлов на живом сервере.
local function wrapBlast()
	if not LVS or ZC_LVS._wrappedBlast then return end
	local old = LVS.BlastDamage
	if not isfunction(old) then return end
	ZC_LVS._wrappedBlast = true
	function LVS:BlastDamage(pos, forward, attacker, inflictor, damage, damagetype, radius, force)
		old(self, pos, forward, attacker, inflictor, damage, damagetype, radius, force)
		if not ZC_LVS.Enabled() then return end
		zcHeBoom(pos, radius, damage, attacker, inflictor)
	end
end

hook.Add("HomigradRun", "zc_lvs_he_wrap", function()
	timer.Simple(0, wrapBlast)
end)
hook.Add("LVS:Initialize", "zc_lvs_he_wrap", function()
	timer.Simple(0, wrapBlast)
end)
hook.Add("InitPostEntity", "zc_lvs_he_wrap", function()
	timer.Simple(1, wrapBlast)
end)
timer.Simple(0, wrapBlast)
