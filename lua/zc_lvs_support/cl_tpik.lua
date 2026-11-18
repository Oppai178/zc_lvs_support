--[[
	[Z-CITY] LVS SUPPORT — TPIK: РУКИ И ВЗГЛЯД (клиент)
	Author: Oppai

	TPIK (third person IK) — система Z-City, которая ставит руки игрока
	на руль, оружие и предметы. Она знает только про Glide/simfphys,
	про LVS не знает ничего. Здесь мы её учим.

	ЧТО ДЕЛАЕМ
	  1. hg.eyeTrace — фильтр взгляда. HUD Z-City («Identifier») печатает
	     имя того, во что упёрся взгляд, включая нашего же фейка внутри
	     закрытого корпуса. Патчить ZC нельзя — фильтруем саму трассу.
	  2. hg.GetCarSteering — подсовываем шасси вместо пода, иначе ZC
	     ищет кость руля не там.
	  3. hg.MainTPIKFunction — главный решатель: рисовать руки или нет.
	  4. hg.CanUseLeftHand — то же для левой руки.

	ГЛАВНОЕ ПРАВИЛО ПО РУКАМ (08.10)
	  режим "zc" -> руки рисуем ВСЕГДА (водитель открытой машины,
	                пассажир, экипаж вертолёта, десант на трапе,
	                стрелок в люке). Фейк здесь и есть вьюмодель.
	                Исключение: под с HidePlayer — тела не видно,
	                вешать руки не на что.
	  режим lvs_* -> руки НЕ рисуем: там свой прицел/интерьер пака,
	                TPIK затягивал куртку прямо в камеру.
]]

ZC_LVS = ZC_LVS or {}

local function wrapTPIK()
	if not hg then return end

	-- HUD Z-City печатает имя над тем, что поймал hg.eyeTrace — в том
	-- числе над нашим фейком в закрытом корпусе и над моделью игрока,
	-- прикреплённой к LVS. Пока локальный игрок едет в закрытой технике
	-- (или с камерой LVS), фейки пассажиров перестают быть целью трассы.
	if hg.eyeTrace and not ZC_LVS._wrappedEyeTrace then
		ZC_LVS._wrappedEyeTrace = true
		local oldEyeTrace = hg.eyeTrace
		function hg.eyeTrace(ply, dist, ent, aim_vector, startpos, fFilter)
			local tr = oldEyeTrace(ply, dist, ent, aim_vector, startpos, fFilter)
			if not tr then return tr end
			if CLIENT and ply == LocalPlayer() and ply:InVehicle() then
				local veh = ZC_LVS.GetVehicle(ply)
				local pod = ply:GetVehicle()
				if IsValid(veh) and (ZC_LVS.IsClosedVehicle(veh) or ZC_LVS.PodHidesPlayer(pod)) then
					local hit = tr.Entity
					if IsValid(hit) then
						local hitRag = hit.IsPlayer and hit:IsPlayer() and hit.FakeRagdoll or hit
						if IsValid(hitRag) and hitRag.PlayerClassName == nil
							and (hit:IsRagdoll() or hit:IsPlayer()) then
							-- Skip our own and others' occupant fakes.
							for _, p in player.Iterator() do
								if p.FakeRagdoll == hit or hit == p then
									tr = table.Copy(tr)
									tr.Entity = veh
									tr.HitPos = tr.HitPos
									break
								end
							end
						end
					end
				end
			end
			return tr
		end
	end

	-- ZC ищет кость руля (steering / steeringwheel) на переданной
	-- сущности. Если передать под — кости там нет. Подменяем на шасси.
	if hg.GetCarSteering and not ZC_LVS._wrappedSteer then
		ZC_LVS._wrappedSteer = true
		local oldSteer = hg.GetCarSteering
		function hg.GetCarSteering(Car)
			if IsValid(Car) and not Car.LVS then
				local chassis = ZC_LVS.GetChassis(Car)
				if IsValid(chassis) then
					Car = chassis
				end
			end
			return oldSteer(Car)
		end
	end

	if hg.MainTPIKFunction and not ZC_LVS._wrappedTPIK then
		ZC_LVS._wrappedTPIK = true
		local oldMain = hg.MainTPIKFunction
		-- Решатель рук. Порядок важен: сначала режим камеры, потом
		-- частные случаи. Это исправление «у газ-66 руки есть, а у
		-- M113 и газ-24 нет»: руки должны быть на КАЖДОМ zc-месте.
		function hg.MainTPIKFunction(ent, ply, wpn)
			if not ZC_LVS.Enabled() or not IsValid(ply) or not ply:IsPlayer() or not ply.InVehicle or not ply:InVehicle() then
				return oldMain(ent, ply, wpn)
			end

			local mode = ZC_LVS.CameraMode(ply)
			local veh = ZC_LVS.GetVehicle(ply)
			local pod = ply:GetVehicle()

			if mode == "zc" then
				-- Руки рисуем везде. Кроме скрытых подов: на месте
				-- стрелка с HidePlayer тела не видно вовсе.
				if ZC_LVS.PodHidesPlayer(pod) then return end
				return oldMain(ent, ply, wpn)
			end

			if mode == "lvs_closed" or mode == "lvs_gun"
				or mode == "lvs_air" or mode == "lvs_plane" then
				-- Родная камера LVS: вид принадлежит их прицелу/интерьеру.
				return
			end

			-- Режим "none" или мод выключен: не наше место, ведём себя
			-- ванильно. Кроме водителя машины LVS, который проскочил
			-- мимо проверки режима — там подменяем Glide (ниже).
			if ZC_LVS.IsExternalLVSSeat(ply) then return end
			if ZC_LVS.IsClosedVehicle(veh) or ZC_LVS.PodHidesPlayer(pod)
				or ZC_LVS.IsHatchSeat(ply, pod, veh)
				or ZC_LVS.SeatEnclosed(pod, veh) then
				return
			end
			if not IsValid(veh) or not ZC_LVS.IsCar(veh) or not ZC_LVS.IsDriver(ply, veh) then
				return oldMain(ent, ply, wpn)
			end

			-- ZC TPIK смотрит только на Glide/simfphys/GetVehicle().
			-- Временно выдаём шасси LVS за машину Glide, чтобы водитель
			-- взял руль. Подмена снимается сразу после вызова — иначе
			-- она утекла бы в остальную логику ZC.
			local oldGet = ply.GlideGetVehicle
			local oldSeat = ply.GlideGetSeatIndex
			ply.GlideGetVehicle = function()
				return veh
			end
			ply.GlideGetSeatIndex = function()
				return 1
			end

			local ok, err = pcall(oldMain, ent, ply, wpn)

			ply.GlideGetVehicle = oldGet
			ply.GlideGetSeatIndex = oldSeat

			if not ok then
				ErrorNoHalt("[Z-CITY LVS SUPPORT] TPIK: " .. tostring(err) .. "\n")
			end
		end
	end

	-- Левая рука: та же подмена Glide, чтобы ZC разрешил её использовать
	-- за рулём (иначе левая рука «занята» несуществующей машиной).
	if hg.CanUseLeftHand and not ZC_LVS._wrappedLeftHand then
		ZC_LVS._wrappedLeftHand = true
		local oldLeft = hg.CanUseLeftHand
		function hg.CanUseLeftHand(ply)
			if ZC_LVS.Enabled() and IsValid(ply) and ply:IsPlayer() and ply.InVehicle and ply:InVehicle() then
				local veh = ZC_LVS.GetVehicle(ply)
				if IsValid(veh) and ZC_LVS.IsCar(veh) and ZC_LVS.IsDriver(ply, veh) then
					local oldGet = ply.GlideGetVehicle
					ply.GlideGetVehicle = function()
						return veh
					end
					local ok, result = pcall(oldLeft, ply)
					ply.GlideGetVehicle = oldGet
					if ok then return result end
				end
			end
			return oldLeft(ply)
		end
	end
end

hook.Add("InitPostEntity", "zc_lvs_wrap_tpik", function()
	timer.Simple(0, wrapTPIK)
	timer.Simple(2, wrapTPIK)
end)

timer.Simple(0, wrapTPIK)
