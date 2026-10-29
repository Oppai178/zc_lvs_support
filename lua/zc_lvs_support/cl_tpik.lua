-- [Z-CITY] LVS SUPPORT
-- Author: Oppai

ZC_LVS = ZC_LVS or {}

local function wrapTPIK()
	if not hg then return end

	-- ZC "Identifier" HUD hook prints the name over whatever hg.eyeTrace
	-- hits — including our seat fake inside a closed hull and the LVS
	-- attached player model. Cannot patch ZC files: filter the trace
	-- itself. While the local player rides a closed/LVS-camera vehicle,
	-- occupant fakes stop being trace targets.
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
		-- GATE TABLE (Oppai 08.10, final):
		--   mode "zc" (open cars, air, closed-hull seats with eyes, troop
		--     ramp, hatch gunner standing at the MG) → the ZC fake IS the
		--     viewmodel: ORIGINAL TPIK, always. This is the
		--     gaz-66-works / M113-and-gaz-24-don't arms fix: hands must
		--     render in EVERY zc seat — driver of an open car, passenger,
		--     helicopter/plane crew.
		--     Exception: pods that hide the player (HidePlayer turret seats)
		--     have no visible body to hang hands on → muffled.
		--   lvs_closed / lvs_gun (native LVS camera: tank periscopes, pack
		--     sights) → muffled: TPIK would draw the jacket into the camera
		--     (clip 18.01 red vs black in M113).
		--   lvs-driver of a LVS car (the no-Glide case below) → Glide
		--     substitute so the hands sit on the wheel.
		function hg.MainTPIKFunction(ent, ply, wpn)
			if not ZC_LVS.Enabled() or not IsValid(ply) or not ply:IsPlayer() or not ply.InVehicle or not ply:InVehicle() then
				return oldMain(ent, ply, wpn)
			end

			local mode = ZC_LVS.CameraMode(ply)
			local veh = ZC_LVS.GetVehicle(ply)
			local pod = ply:GetVehicle()

			if mode == "zc" then
				-- "zc" everywhere: hands render. Except hidden pods — a
				-- HidePlayer turret seat shows no body at all, so no arms.
				if ZC_LVS.PodHidesPlayer(pod) then return end
				return oldMain(ent, ply, wpn)
			end

			if mode == "lvs_closed" or mode == "lvs_gun"
				or mode == "lvs_air" or mode == "lvs_plane" then
				-- Native LVS camera: their own sights/interior own the view.
				return
			end

			-- mode "none" or off: not our seat — vanilla behavior, EXCEPT
			-- the driver of a LVS car that slipped past the mode gate
			-- (IsExternalLVSSeat covers closed hulls; enclosed pods would
			-- draw the jacket into the camera, clip 18.01).
			if ZC_LVS.IsExternalLVSSeat(ply) then return end
			if ZC_LVS.IsClosedVehicle(veh) or ZC_LVS.PodHidesPlayer(pod)
				or ZC_LVS.IsHatchSeat(ply, pod, veh)
				or ZC_LVS.SeatEnclosed(pod, veh) then
				return
			end
			if not IsValid(veh) or not ZC_LVS.IsCar(veh) or not ZC_LVS.IsDriver(ply, veh) then
				return oldMain(ent, ply, wpn)
			end

			-- ZC TPIK only looks at Glide/simfphys/GetVehicle(). Temporarily
			-- present the LVS chassis as a Glide vehicle so the driver holds the wheel.
			-- Conflicts with the "zc" skip above: none — this branch only
			-- runs when mode is NOT "zc", and the zc driver took the early
			-- oldMain return already.
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
