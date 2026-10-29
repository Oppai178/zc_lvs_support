-- [Z-CITY] LVS SUPPORT
-- Author: Oppai

ZC_LVS = ZC_LVS or {}

local function organismTarget(ply)
	if not IsValid(ply) then return end
	if IsValid(ply.FakeRagdoll) then
		return ply.FakeRagdoll
	end
	return ply
end

local SIT_MINS = Vector(-16, -16, -8)
local SIT_MAXS = Vector(16, 16, 40)

-- B2 damage probe (08.10): who/what/how much reaches a seated occupant or
-- their fake. Gate: zc_lvs_debug 1. Run before ZC's "homigrad-damage" hook
-- ("!!!!" prefix) so we see the RAW damageinfo (ZC rescales it afterwards).
-- Used to prove the "gibbed on turn" source: LVS CRUSH vs our own BLAST.
hook.Add("EntityTakeDamage", "!!!!zc_lvs_dmg_probe", function(ent, dmginfo)
	if not ZC_LVS.Enabled() then return end
	if not ZC_LVS.DebugEnabled() then return end
	if not IsValid(ent) then return end

	local ply
	if ent:IsPlayer() then
		ply = ent
	else
		ply = (hg and hg.RagdollOwner and hg.RagdollOwner(ent)) or NULL
		if not IsValid(ply) and ent.GetNWEntity then
			ply = ent:GetNWEntity("ply")
		end
	end
	if not IsValid(ply) or not ply:IsPlayer() then return end
	if not ply:InVehicle() then return end
	local veh = ZC_LVS.GetVehicle(ply)
	if not IsValid(veh) then return end

	local atk = dmginfo:GetAttacker()
	local inf = dmginfo:GetInflictor()
	ZC_LVS.DebugLog("dmg_probe",
		"ply=" .. ply:EntIndex(),
		"tgt=" .. (ent:IsPlayer() and "player" or "fake"),
		"dmg=" .. string.format("%.1f", dmginfo:GetDamage()),
		"type=0x" .. string.format("%x", dmginfo:GetDamageType()),
		"atk=" .. (IsValid(atk) and atk:GetClass() or "world"),
		"inf=" .. (IsValid(inf) and inf:GetClass() or "world"),
		"dist2ent=" .. string.format("%.0f", math.max(0.1, (ent:GetPos() - dmginfo:GetDamagePosition()):Length())))
end)

-- CRUSH GUARD (Oppai 09.10 "разорвало на части", proven by dmg_probe):
-- the seated fake is a physics body parented/welded to the hull; on
-- bumps, suspension shake and wall hits the engine resolves contacts
-- between the fake and its OWN vehicle (or world) as CRUSH (0x1) —
-- the log showed 50/100-damage DMG_CRUSH floods from ses_uaz452 and
-- world, killing a CONSCIOUS driver at low speed. A crew member cannot
-- be crushed by the seat he sits in: cancel CRUSH damage to an occupant
-- fake/player from his own vehicle while he is conscious and seated.
-- Real events still hurt: our crash spike (DMG_BLAST, dv>=120), bullets,
-- explosions. Grabs/pulls keep working (they are not CRUSH on the fake).
hook.Add("EntityTakeDamage", "!!!!zc_lvs_crush_guard", function(ent, dmginfo)
	if not ZC_LVS.Enabled() or not IsValid(ent) then return end
	local dtype = dmginfo:GetDamageType()
	if not bit.band(dtype, DMG_CRUSH) then return end
	if bit.band(dtype, DMG_BLAST) then return end

	local ply
	if ent:IsPlayer() then
		ply = ent
	else
		ply = (hg and hg.RagdollOwner and hg.RagdollOwner(ent)) or NULL
		if not IsValid(ply) and ent.GetNWEntity then
			ply = ent:GetNWEntity("ply")
		end
	end
	if not IsValid(ply) or not ply:IsPlayer() then return end
	if not ply:InVehicle() or ZC_LVS.IsUnconscious(ply) then return end

	local veh = ZC_LVS.GetVehicle(ply)
	local atk = dmginfo:GetAttacker()
	local inf = dmginfo:GetInflictor()
	local ownHull = IsValid(veh) and (atk == veh or inf == veh
		or (IsValid(veh:GetParent()) and (atk == veh:GetParent() or inf == veh:GetParent())))
	local fromWorld = (not IsValid(atk)) and (not IsValid(inf))
	if not ownHull and not fromWorld then return end

	ZC_LVS.DebugLog("crush_cancel", "ply=" .. ply:EntIndex(),
		"dmg=" .. string.format("%.0f", dmginfo:GetDamage()),
		"atk=" .. (IsValid(atk) and atk:GetClass() or "world"))
	dmginfo:SetDamage(0)
end)

function ZC_LVS.SeatHitPos(ply, veh)
	if not IsValid(ply) then return end
	veh = IsValid(veh) and veh or ZC_LVS.GetVehicle(ply)
	local rag = ply.FakeRagdoll
	if IsValid(rag) and IsValid(veh) and isvector(rag.zc_lvs_hit_local) then
		return veh:LocalToWorld(rag.zc_lvs_hit_local)
	end
	if IsValid(rag) then
		return rag:WorldSpaceCenter()
	end
	return IsValid(ply) and ply:EyePos() or nil
end

local function hurtOccupants(veh, amount, dmgType, attacker, inflictor, pos, knockOut)
	if not IsValid(veh) then return end

	amount = math.max(0, amount or 0)
	if amount <= 0 then return end

	attacker = IsValid(attacker) and attacker or veh
	inflictor = IsValid(inflictor) and inflictor or veh

	ZC_LVS.IterOccupants(veh, function(ply)
		if not ply:Alive() then return end
		local target = organismTarget(ply)
		if not IsValid(target) then return end

		local dmg = DamageInfo()
		dmg:SetDamage(amount)
		dmg:SetAttacker(attacker)
		dmg:SetInflictor(inflictor)
		dmg:SetDamageType(dmgType or DMG_BLAST)
		dmg:SetDamagePosition(pos or ZC_LVS.SeatHitPos(ply, veh) or ply:EyePos())
		dmg:SetDamageForce((ply:GetPos() - veh:GetPos()):GetNormalized() * amount * 40)
		target:TakeDamageInfo(dmg)
		if knockOut and ply.organism and ply:Alive() and not ply.organism.otrub then
			ply.organism.needotrub = true
		end
	end)
end

-- Cached convar lookups: the Tick/damage paths below poll these a lot.
local CV = {}
local function cvBool(name)
	local c = CV[name]
	if c == nil then
		c = GetConVar(name) or false
		CV[name] = c
	end
	return c ~= false and c:GetBool() or false
end

-- Roof dummy must not eat bullets. Crash/fire/pen still go through the vehicle.
hook.Add("EntityTakeDamage", "zc_lvs_closed_noshot", function(ent, dmginfo)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ent) or not ent:IsRagdoll() then return end
	if ZC_LVS._hurtingOccupants then return end
	-- Glass/door penetration (zc_lvs_glass_pen) already paid the armor toll
	-- and traced a real occupant: that pass must land even in a closed hull.
	if ZC_LVS._penBullet then return end
	if not (dmginfo:IsBulletDamage() or dmginfo:IsDamageType(DMG_CLUB) or dmginfo:IsDamageType(DMG_SLASH)) then
		return
	end
	for _, ply in player.Iterator() do
		if ply.FakeRagdoll ~= ent then continue end
		if not ply:InVehicle() then continue end
		local veh = ZC_LVS.GetVehicle(ply)
		-- Hidden inside armor: bullets ignore the dummy.
		-- Open hatch: the sitting fake SHOULD take shots.
		if IsValid(ply.FakeRagdoll) and ply.FakeRagdoll.zc_lvs_closed_hide then
			return true
		end
		if ZC_LVS.IsClosedVehicle(veh) and not ZC_LVS.IsRoofSeat(ply:GetVehicle(), veh) then
			return true
		end
	end
end)

-- HE vs armor (Task A4-3): LVS:BlastDamage / bombs apply blast as
-- DMG_SONIC/DMG_BLAST straight to the seated player (pods have no hull
-- between them and util.BlastDamageInfo). ZC's homigrad-damage hook then
-- re-posts it onto the fake ragdoll, so BOTH shapes arrive here.
-- Closed armor should soak part of it; open hulls take the full charge.
hook.Add("EntityTakeDamage", "zc_lvs_he_armor", function(ent, dmginfo)
	if not ZC_LVS.Enabled() then return end
	if ZC_LVS._hurtingOccupants then return end
	if not (dmginfo:IsDamageType(DMG_SONIC) or dmginfo:IsDamageType(DMG_BLAST)) then return end
	-- LVS HE only: the inflictor/attacker must be part of LVS (gun shell,
	-- bomb) or the vehicle itself. Z-City grenades keep full damage.
	local src = dmginfo:GetInflictor()
	if not IsValid(src) or not src.LVS then
		local atk = dmginfo:GetAttacker()
		if IsValid(atk) and atk.LVS then
			src = atk
		elseif IsValid(src) and isfunction(src.GetParent) then
			local par = src:GetParent()
			if IsValid(par) and par.LVS then src = par end
		end
	end
	if not IsValid(src) or not src.LVS then return end

	local ply, veh
	if ent:IsPlayer() then
		if not ent:InVehicle() then return end
		ply = ent
		veh = ZC_LVS.GetVehicle(ent)
	else
		-- The fake ragdoll route: find its seated owner.
		local owner
		if hg and hg.RagdollOwner then
			owner = hg.RagdollOwner(ent)
		end
		if not IsValid(owner) and ent.GetNWEntity then
			owner = ent:GetNWEntity("ply")
		end
		if not IsValid(owner) or not owner:InVehicle() or owner.FakeRagdoll ~= ent then return end
		ply = owner
		veh = ZC_LVS.GetVehicle(owner)
	end
	if not IsValid(veh) then return end

	if ZC_LVS.IsClosedVehicle(veh) then
		-- Tank/APC: armor soaks most of an outside HE hit. Interior
		-- explosions (mine under the floor) should still sting, but
		-- position vs OBB is not a reliable LOS test here — flat cut.
		dmginfo:ScaleDamage(0.25)
	elseif ZC_LVS.IsAircraft(veh) or ZC_LVS.IsOpenCarHull(veh) then
		-- Open hull: full damage, plus a real concussion.
		local org = ply.organism
		if org and not org.otrub and dmginfo:GetDamage() >= 25 then
			org.needotrub = true
		end
	end
end)

-- LVS only CRUSH-damages the hull at VelDif > 1000 (rare at car speeds).
-- Wheeldrive then sends that to the engine. Occupant injuries must use dv.
hook.Add("Tick", "zc_lvs_plane_dv", function()
	if not ZC_LVS.Enabled() then return end
	local crashEnabled = cvBool("zc_lvs_crash_damage")
	local seen = {}
	for _, ply in player.Iterator() do
		if not ply:InVehicle() then continue end
		local veh = ZC_LVS.GetVehicle(ply)
		if not IsValid(veh) or seen[veh] then continue end
		seen[veh] = true

		local cur = veh:GetVelocity()
		local prev = veh._zc_lvs_prevvel
		if prev then
			veh._zc_lvs_dv = (prev - cur):Length()
		else
			veh._zc_lvs_dv = 0
		end
		veh._zc_lvs_prevvel = cur

		if not crashEnabled then continue end
		if ZC_LVS._hurtingOccupants then continue end
		if ZC_LVS.IsAircraft(veh) then continue end
		-- Cars: ZC already injures the fake (clip 21.51 вывих/перелом).
		-- We only eject on a hard slam — 3.0.4 skipped eject entirely.
		-- B2 (08.10) "разрывает при поворотах": the old open-car branch fired
		-- at dv >= 10 EVERY tick with no cooldown. dv 10-40 per tick is normal
		-- driving noise (suspension bob, centripetal in a turn), so steering
		-- or throttle stacked 3-90 BLAST PER TICK (~60+ dmg/sec) into the
		-- organism — death from blood loss, and the death stack
		-- (DMG_BLAST * 200/lend, lend ~ body's own pelvis) tore the corpse
		-- apart. A real crash is a SINGLE-TICK spike (LVS itself only counts
		-- collision damage at VelDif > 1000, sv_physics.lua). Spike-only +
		-- 0.5s gate: 60 km/h into a wall (dv ~ 870) = heavy injury, plain
		-- driving/turning = zero.
		if ZC_LVS.IsCar(veh) then
			local dv = veh._zc_lvs_dv or 0
			-- Per-vehicle open/closed class is stable: cache on the hull so
			-- IsOpenCarHull (OBB + seat walk) does not run every tick.
			local openHull = veh._zc_lvs_openhull
			if openHull == nil then
				openHull = ZC_LVS.IsOpenCarHull(veh) or false
				veh._zc_lvs_openhull = openHull
			end
			if dv >= 20 or (prev and prev:Length() >= 780) then
				ZC_LVS.DebugLog("car_crash_check", "veh=" .. veh:GetClass() .. " open=" .. tostring(openHull) .. " gun=" .. tostring(ZC_LVS.CarHasGunSeat(veh)) .. " dv=" .. string.format("%.1f", dv) .. " speed=" .. string.format("%.1f", prev and prev:Length() or 0))
			end
			local spike = openHull and 120 or 260
			if dv >= spike and prev and prev:Length() >= 140 then
				local now = CurTime()
				-- One hit per 0.5s, and never twice in the same tick as the
				-- collision-event path below (zc_lvs_crash_org shares the gate).
				if not (veh._zc_lvs_org_t == now)
					and not (veh._zc_lvs_car_t and veh._zc_lvs_car_t > now) then
					veh._zc_lvs_org_t = now
					veh._zc_lvs_car_t = now + 0.5
					local amount
					if openHull then
						-- Wall at 60 km/h (dv ~ 870) -> ~40: injured, not gibbed.
						amount = math.Clamp((dv - 100) * 0.12, 3, 40)
					else
						-- Closed cabins do not eject occupants through the hull.
						-- Same short impact injury as before, just gated.
						amount = math.Clamp((dv - 220) * 0.035, 3, 12)
					end
					ZC_LVS.DebugLog("car_crash_dmg", "veh=" .. veh:GetClass(),
						"open=" .. tostring(openHull),
						"dv=" .. string.format("%.1f", dv),
						"speed=" .. string.format("%.1f", prev:Length()),
						"dmg=" .. string.format("%.1f", amount))
					ZC_LVS._hurtingOccupants = true
					-- Position from the HULL, not the occupant's pelvis: ZC
					-- multiplies BLAST death-stacks by 200/lend, and a damage
					-- position inside the body made every crash a dismemberment.
					hurtOccupants(veh, amount, DMG_BLAST, veh, veh, veh:GetPos(), dv >= 220)
					ZC_LVS._hurtingOccupants = false
				end
			end
			continue
		end

		local grace
		ZC_LVS.IterOccupants(veh, function(occ)
			if occ.zc_lvs_entered and occ.zc_lvs_entered > CurTime() then
				grace = true
			end
		end)
		if grace then continue end

		local dv = veh._zc_lvs_dv or 0
		if dv < 380 then continue end
		if not prev or prev:Length() < 140 then continue end
		local now = CurTime()
		if veh._zc_lvs_org_t == now then continue end
		veh._zc_lvs_org_t = now

		-- Bruises, not gibs. 50 BLAST + launch was "разорвало и убило".
		local amount = math.Clamp((dv - 300) * 0.04, 3, 12)
		local doEject = cvBool("zc_lvs_crash_eject")
			and not (veh._zc_lvs_eject_t and veh._zc_lvs_eject_t > now)
			and dv >= 620 and prev:Length() >= 300
		if doEject then
			amount = math.min(amount, 8)
		end
		ZC_LVS._hurtingOccupants = true
		 hurtOccupants(veh, amount, DMG_BLAST, veh, veh, nil, dv >= 220)
		ZC_LVS._hurtingOccupants = false

		if not doEject then continue end
		veh._zc_lvs_eject_t = now + 0.8
		ZC_LVS.IterOccupants(veh, function(occ)
			if not occ:Alive() or not occ:InVehicle() or occ.switchingseat then return end
			if ZC_LVS.EjectPlayer then
				ZC_LVS.EjectPlayer(occ, veh, true)
			end
		end)
	end
end)

-- ZC swallows DMG_CRUSH on the organism. Convert LVS crash into BLAST so bones/organs react.
hook.Add("EntityTakeDamage", "zc_lvs_crash_org", function(ent, dmginfo)
	if not ZC_LVS.Enabled() then return end
	if not cvBool("zc_lvs_crash_damage") then return end
	if not IsValid(ent) then return end
	-- Wheeldrive sends CRUSH to the engine, not the hull.
	if not ent.LVS then
		local par = ent.GetParent and ent:GetParent()
		if IsValid(par) and par.LVS then
			ent = par
		else
			return
		end
	end
	if ZC_LVS._hurtingOccupants then return end
	local isCrash = dmginfo:IsDamageType(DMG_CRUSH) or dmginfo:IsDamageType(DMG_VEHICLE)
	-- LVS:BlastDamage swaps DMG_BLAST -> DMG_SONIC before applying, so HE
	-- shells/bombs arrive here as SONIC. Treat both as HE.
	local isBlast = dmginfo:IsDamageType(DMG_BLAST) or dmginfo:IsDamageType(DMG_SONIC)
	if not isCrash and not isBlast then return end

	local raw = dmginfo:GetDamage()
	if raw < 20 then return end

	-- Sitting down / idle hull contact is not a crash. That was breaking
	-- legs on EnterVehicle.
	if isCrash and ent:GetVelocity():Length() < 140 then return end

	-- Wheeldrive often reports the impact on its engine child instead of
	-- producing a useful velocity delta. Handle open cars directly from the
	-- collision damage event; closed cars remain injury-only.
	-- B2 (08.10): damage position from the HULL center (see zc_lvs_plane_dv
	-- comment) and the same 0.5s gate — the collision event and the dv-Tick
	-- both see one crash; the old code let both fire full power.
	if isCrash and ZC_LVS.IsCar(ent) then
		local speed = ent:GetVelocity():Length()
		local now = CurTime()
		local gated = (ent._zc_lvs_org_t == now) or (ent._zc_lvs_car_t and ent._zc_lvs_car_t > now)
		if not gated then
			ent._zc_lvs_org_t = now
			ent._zc_lvs_car_t = now + 0.5
		end
		if not ZC_LVS.IsOpenCarHull(ent) then
			if not gated then
				hurtOccupants(ent, math.Clamp((dmginfo:GetDamage() - 20) * 0.08, 3, 12), DMG_BLAST, dmginfo:GetAttacker(), dmginfo:GetInflictor(), ent:GetPos())
			end
			return
		end
		if gated then return end
		local dv = ent._zc_lvs_dv or 0
		local impact = math.max(dmginfo:GetDamage(), dv * 0.6)
		-- Same spike math as the Tick branch: raw LVS collision damage is
		-- (VelDif-1000)/4000^2*200, 60 km/h wall hit ~ 170 raw / dv ~ 870.
		local amount = math.Clamp((impact - 15) * 0.12, 3, 40)
		ZC_LVS.DebugLog("car_crash_dmg", "veh=" .. ent:GetClass(), "src=damage_event",
			"raw=" .. string.format("%.1f", dmginfo:GetDamage()),
			"dv=" .. string.format("%.1f", dv),
			"speed=" .. string.format("%.1f", speed),
			"dmg=" .. string.format("%.1f", amount))
		hurtOccupants(ent, amount, DMG_BLAST, dmginfo:GetAttacker(), dmginfo:GetInflictor(), ent:GetPos(), impact >= 220)
		if cvBool("zc_lvs_crash_eject") and speed >= 780 and dv >= 35 and not (ent._zc_lvs_eject_t and ent._zc_lvs_eject_t > CurTime()) then
			ent._zc_lvs_eject_t = CurTime() + 0.8
			ZC_LVS.DebugLog("car_damage_eject", "veh=" .. ent:GetClass() .. " speed=" .. string.format("%.1f", speed) .. " raw=" .. string.format("%.1f", dmginfo:GetDamage()))
			ZC_LVS.IterOccupants(ent, function(occ)
				if occ:Alive() and occ:InVehicle() and not occ.switchingseat and (not ZC_LVS.IsHatchSeat(occ) or ZC_LVS.IsDriver(occ, ent)) then
					ZC_LVS.EjectPlayer(occ, ent, true)
				end
			end)
		end
		return
	end
	if isCrash and ent:GetVelocity():Length() >= 140 and ent:GetVelocity():Length() < 260 then
		hurtOccupants(ent, 4, DMG_BLAST, dmginfo:GetAttacker(), dmginfo:GetInflictor(), dmginfo:GetDamagePosition())
	end

	-- Fighter takeoff rumble is not a crash. Only a slam (building) hurts.
	-- Helis: bullet hits / fake phys must not look like a crash (fall FX + shake).
	if isCrash and (ZC_LVS.IsPlane(ent) or ZC_LVS.IsAircraft(ent)) then
		local dv = ent._zc_lvs_dv or 0
		if dv < 380 then return end
	end

	-- One transfer per vehicle per tick.
	local now = CurTime()
	if ent._zc_lvs_org_t == now then return end
	ent._zc_lvs_org_t = now

	local amount
	if ZC_LVS.IsCar(ent) then
		amount = math.Clamp((raw - 20) * 0.08, 3, 12)
	elseif isBlast then
		amount = math.Clamp(raw * 0.45, 10, 90)
		-- Closed armor eats an outside HE hit before the crew feels it.
		-- The zc_lvs_he_armor hook already cut the direct player hit; this
		-- hull-transfer path must match so the crew is not hit twice full.
		if ZC_LVS.IsClosedVehicle(ent) then
			amount = amount * 0.25
		end
	else
		amount = math.Clamp((raw - 20) * 0.35, 8, 70)
	end

	ZC_LVS._hurtingOccupants = true
	hurtOccupants(ent, amount, DMG_BLAST, dmginfo:GetAttacker(), dmginfo:GetInflictor(), dmginfo:GetDamagePosition())
	ZC_LVS._hurtingOccupants = false

	if not isCrash then return end
	if not cvBool("zc_lvs_crash_eject") then return end

	local speed = ent:GetVelocity():Length()
	local now = CurTime()
	if ent._zc_lvs_eject_t and ent._zc_lvs_eject_t > now then return end

	-- Planes: never eject on airspeed. Takeoff is 400+ u/s with tiny dv.
	-- Eject only on a slam (flew into a building): big deceleration this tick.
	if ZC_LVS.IsPlane(ent) then
		local dv = ent._zc_lvs_dv or 0
		if dv < 380 or raw < 35 then return end
		ent._zc_lvs_eject_t = now + 0.8
		if isfunction(ent.GetEveryone) then
			for _, ply in ipairs(ent:GetEveryone()) do
				if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then continue end
				if not ply:InVehicle() or ply.switchingseat then continue end
				if ZC_LVS.EjectPlayer then
					ZC_LVS.EjectPlayer(ply, ent, true)
				end
			end
		end
		return
	end

	-- Concussion while everyone is still attached (seats + cargo).
	if speed > 480 and raw > 35 then
		local extra = math.Clamp((speed - 400) / 50, 6, 22)
		ZC_LVS.IterOccupants(ent, function(ply)
			if not ply:Alive() then return end
			local target = organismTarget(ply)
			if not IsValid(target) then return end
			local dmg = DamageInfo()
			dmg:SetDamage(extra)
			dmg:SetAttacker(ent)
			dmg:SetInflictor(ent)
			dmg:SetDamageType(DMG_BLAST)
			dmg:SetDamagePosition(ply:EyePos())
			target:TakeDamageInfo(dmg)
		end)
	end

	local ejected
	if isfunction(ent.GetEveryone) then
		for _, ply in ipairs(ent:GetEveryone()) do
			if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then continue end
			if not ply:InVehicle() or ply.switchingseat then continue end

			local thresh = 420
			if ZC_LVS.IsUnconscious(ply) then
				thresh = 190
			end
			if ZC_LVS.IsAircraft(ent) and ZC_LVS.IsAirborne(ent) and cvBool("zc_lvs_air_fall") then
				thresh = thresh * 0.45
			end
			local org = ply.organism
			if org then
				if org.llegamputated or org.rlegamputated or org.llegbroken or org.rlegbroken then
					thresh = thresh * 0.7
				end
				if (org.immobilization or 0) > 2 then
					thresh = thresh * 0.85
				end
			end

			if speed > thresh and raw > 28 then
				if not ejected then
					ent._zc_lvs_eject_t = now + 0.8
					ejected = true
				end
				if ZC_LVS.EjectPlayer then
				ZC_LVS.EjectPlayer(ply, ent, true)
				end
			end
		end
	end

	-- Cargo riders are not in GetEveryone. Throw them on a hard hit even
	-- if nobody in a seat met the eject threshold.
	if ejected or (speed > 280 and raw > 22) then
		if not ejected then
			ent._zc_lvs_eject_t = now + 0.8
		end
		for _, ply in player.Iterator() do
			if ply.zc_lvs_cargo == ent and ZC_LVS.ExitCargo then
				ZC_LVS.ExitCargo(ply, true)
			end
		end
	end
end)

local function posInDoor(door, worldPos)
	if not IsValid(door) then return false end
	local lp = door:WorldToLocal(worldPos)
	local mins, maxs = door:GetMins(), door:GetMaxs()
	if not mins or not maxs then return false end
	if lp.x < mins.x - 8 or lp.x > maxs.x + 8 then return false end
	if lp.y < mins.y - 8 or lp.y > maxs.y + 8 then return false end
	if lp.z < mins.z - 8 or lp.z > maxs.z + 28 then return false end
	return true
end

local function cabinThinHit(veh, hitPos)
	if not IsValid(veh) or not hitPos then return false, false end

	if isfunction(veh.GetDoorHandlers) then
		for _, door in ipairs(veh:GetDoorHandlers()) do
			if not IsValid(door) then continue end
			if posInDoor(door, hitPos) then
				return true, door.IsOpen and door:IsOpen()
			end
		end
	end

	local lp = veh:WorldToLocal(hitPos)
	local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
	local h = maxs.z - mins.z
	if h < 8 then return false, false end
	local zFrac = (lp.z - mins.z) / h
	local depth = maxs.x - mins.x
	local width = maxs.y - mins.y

	-- Windshield / canopy: upper front.
	if zFrac > 0.42 and depth > 1 and lp.x > mins.x + depth * 0.55 then
		return true, false
	end
	-- Side glass band when the vehicle has no door boxes.
	if zFrac > 0.48 and zFrac < 0.92 and width > 1 and math.abs(lp.y) > width * 0.28 then
		return true, false
	end
	-- Helicopters: most of the upper cabin is glass.
	if ZC_LVS.IsAircraft(veh) and zFrac > 0.4 then
		return true, false
	end

	return false, false
end

local function isHeadish(ent, pos)
	if not IsValid(ent) or not pos then return false end
	if ent:IsPlayer() then
		return pos:DistToSqr(ent:EyePos()) < 400
	end
	if ent:GetClass() == "prop_ragdoll" then
		local bone = ent:LookupBone("ValveBiped.Bip01_Head1")
		if bone then
			local hp = ent:GetBonePosition(bone)
			if hp then
				return pos:DistToSqr(hp) < 324
			end
		end
	end
	return false
end

-- Layer C: fake has collisions off, so ZC bullets never land on it.
-- After a shot, if the ray crosses an occupant's dummy OBB, write organism.
local function dummyHidden(ply)
	local rag = ply.FakeRagdoll
	if not IsValid(rag) then return true end
	local veh = ZC_LVS.GetVehicle(ply)
	-- Armor: bullets must not sew the crew. Open HidePlayer (FlaK) still takes hits.
	if ZC_LVS.IsClosedVehicle(veh) and not ZC_LVS.IsRoofSeat(ply:GetVehicle(), veh) then
		return true
	end
	return false
end

local function rayHitsDummy(start, dir, rag)
	if not IsValid(rag) or not isvector(start) or not isvector(dir) then return end
	if dir:LengthSqr() < 0.01 then return end
	dir = dir:GetNormalized()
	local origin, ang, mins, maxs
	local veh = rag.zc_lvs_follow
	if IsValid(veh) and isvector(rag.zc_lvs_hit_local) then
		origin = veh:LocalToWorld(rag.zc_lvs_hit_local)
		ang = veh:GetAngles()
		mins = SIT_MINS
		maxs = SIT_MAXS
	else
		origin = rag:GetPos()
		ang = rag:GetAngles()
		mins = (rag.OBBMins and rag:OBBMins() or Vector(-16, -16, -8)) - Vector(6, 6, 6)
		maxs = (rag.OBBMaxs and rag:OBBMaxs() or Vector(16, 16, 40)) + Vector(6, 6, 6)
	end
	local hitp, _, frac = util.IntersectRayWithOBB(
		start,
		dir * 4000,
		origin,
		ang,
		mins,
		maxs
	)
	if not hitp then return end
	return hitp, frac or 0
end

local function applyDummyBullet(ply, rag, dmginfo, hitp, dir)
	if ZC_LVS._penBullet or ZC_LVS._hurtingOccupants then return end
	ZC_LVS._penBullet = true
	local pass = DamageInfo()
	pass:SetDamage(dmginfo:GetDamage())
	local atk = dmginfo:GetAttacker()
	pass:SetAttacker(IsValid(atk) and atk or game.GetWorld())
	local inf = dmginfo:GetInflictor()
	pass:SetInflictor(IsValid(inf) and inf or (IsValid(atk) and atk or game.GetWorld()))
	pass:SetDamageType(dmginfo:GetDamageType())
	pass:SetDamagePosition(hitp)
	pass:SetDamageForce(dir * math.max(1, dmginfo:GetDamage()) * 40)
	rag:TakeDamageInfo(pass)
	ZC_LVS._penBullet = false
end

local function dummyBulletHit(attacker, tr, dmginfo)
	if not ZC_LVS.Enabled() then return end
	if not tr or not dmginfo then return end
	if ZC_LVS._penBullet or ZC_LVS._hurtingOccupants then return end
	if not (dmginfo:IsBulletDamage() or dmginfo:IsDamageType(DMG_BUCKSHOT) or dmginfo:IsDamageType(DMG_SNIPER)) then
		return
	end

	local start = tr.StartPos
	if not isvector(start) and IsValid(attacker) and attacker.EyePos then
		start = attacker:EyePos()
	end
	if not isvector(start) then return end

	local dir = tr.Normal
	if not isvector(dir) or dir:LengthSqr() < 0.01 then
		if isvector(tr.HitPos) then
			dir = (tr.HitPos - start):GetNormalized()
		else
			return
		end
	end

	local best, bestPly, bestRag, bestFrac
	for _, ply in player.Iterator() do
		if not ply:Alive() or not ply:InVehicle() then continue end
		if dummyHidden(ply) then continue end
		local rag = ply.FakeRagdoll
		if not IsValid(rag) then continue end
		if IsValid(tr.Entity) and tr.Entity == rag then return end
		local hitp, frac = rayHitsDummy(start, dir, rag)
		if not hitp then continue end
		-- Hull is in front of the dummy. Still a hit if we struck THIS car.
		local hitEnt = tr.Entity
		local hitHull = IsValid(hitEnt) and (hitEnt.LVS and hitEnt or ZC_LVS.GetChassis(hitEnt)) or NULL
		local dummyHull = rag.zc_lvs_follow
		if not (IsValid(hitHull) and hitHull == dummyHull) then
			if tr.Hit and isvector(tr.HitPos) and start:DistToSqr(hitp) > start:DistToSqr(tr.HitPos) + 64 then
				continue
			end
		end
		if not bestFrac or frac < bestFrac then
			best, bestPly, bestRag, bestFrac = hitp, ply, rag, frac
		end
	end
	if best and IsValid(bestRag) then
		applyDummyBullet(bestPly, bestRag, dmginfo, best, dir)
	end
end

hook.Add("EntityFireBullets", "zc_lvs_dummy_hit", function(ent, data)
	if not ZC_LVS.Enabled() then return end
	if not istable(data) then return end
	local any
	for _, ply in player.Iterator() do
		if ply:Alive() and ply:InVehicle() and ZC_LVS.IsLVSSeat(ply:GetVehicle()) and IsValid(ply.FakeRagdoll) then
			any = true
			break
		end
	end
	if not any then return end
	local prev = data.Callback
	data.Callback = function(atk, tr, dmg)
		if isfunction(prev) then
			prev(atk, tr, dmg)
		end
		dummyBulletHit(atk, tr, dmg)
	end
	return true
end)

-- Bullets through glass / open doors into whoever sits inside.
hook.Add("EntityTakeDamage", "zc_lvs_glass_pen", function(ent, dmginfo)
	if not ZC_LVS.Enabled() then return end
	if not cvBool("zc_lvs_pen") then return end
	if ZC_LVS._penBullet then return end
	if not IsValid(ent) or not ent.LVS then return end
	if not (dmginfo:IsBulletDamage() or dmginfo:IsDamageType(DMG_BUCKSHOT) or dmginfo:IsDamageType(DMG_SNIPER)) then
		return
	end

	local hitPos = dmginfo:GetDamagePosition()
	local thin, doorOpen = cabinThinHit(ent, hitPos)
	if not thin then return end

	local dir = dmginfo:GetDamageForce():GetNormalized()
	if dir:LengthSqr() < 0.01 then
		local atk = dmginfo:GetAttacker()
		if IsValid(atk) and atk.EyePos then
			dir = (hitPos - atk:EyePos()):GetNormalized()
		else
			dir = ent:GetForward()
		end
	end

	local scale = doorOpen and 0.05 or 0.22
	dmginfo:ScaleDamage(scale)

	local ed = EffectData()
	ed:SetOrigin(hitPos)
	ed:SetNormal(-dir)
	util.Effect("GlassImpact", ed, true, true)
	ent:EmitSound("physics/glass/glass_impact_bullet" .. math.random(1, 4) .. ".wav", 70, 100, 0.55)

	local tr = util.TraceLine({
		start = hitPos + dir * 6,
		endpos = hitPos + dir * 110,
		filter = function(hit)
			if not IsValid(hit) then return false end
			if hit == ent then return false end
			if hit:GetParent() == ent and hit:GetClass() ~= "prop_ragdoll" then return false end
			if hit.LVS then return false end
			return true
		end,
	})

	if not tr.Hit or not IsValid(tr.Entity) then return end

	local target = tr.Entity
	if target:IsPlayer() then
		target = organismTarget(target) or target
	elseif target:GetClass() ~= "prop_ragdoll" then
		return
	end
	if not IsValid(target) then return end

	local pen = dmginfo:GetDamage() / math.max(scale, 0.05)
	local passed = pen * (doorOpen and 0.92 or 0.78)

	ZC_LVS._penBullet = true
	local pass = DamageInfo()
	pass:SetDamage(passed)
	local atk = dmginfo:GetAttacker()
	pass:SetAttacker(IsValid(atk) and atk or game.GetWorld())
	local inf = dmginfo:GetInflictor()
	pass:SetInflictor(IsValid(inf) and inf or ent)
	pass:SetDamageType(dmginfo:GetDamageType())
	pass:SetDamagePosition(tr.HitPos)
	pass:SetDamageForce(dir * passed * 40)
	target:TakeDamageInfo(pass)

	if isHeadish(target, tr.HitPos) and not doorOpen then
		local shard = DamageInfo()
		shard:SetDamage(math.random(6, 12))
		shard:SetAttacker(IsValid(atk) and atk or game.GetWorld())
		shard:SetInflictor(ent)
		shard:SetDamageType(DMG_SLASH)
		shard:SetDamagePosition(tr.HitPos)
		target:TakeDamageInfo(shard)
	end
	ZC_LVS._penBullet = false
end)

local function fireShrapnel(veh, attacker, inflictor)
	if not IsValid(veh) then return end
	if not cvBool("zc_lvs_shrapnel") then return end

	local src = veh:WorldSpaceCenter() + Vector(0, 0, 18)
	attacker = IsValid(attacker) and attacker or veh
	inflictor = IsValid(inflictor) and inflictor or veh

	local ed = EffectData()
	ed:SetOrigin(src)
	ed:SetScale(1)
	pcall(util.Effect, "eff_jack_hmcd_shrapnel", ed, true, true)

	if not IsValid(veh) then return end

	for i = 1, 12 do
		local dir = VectorRand()
		dir.z = dir.z * 0.45
		dir:Normalize()
		pcall(veh.FireBullets, veh, {
			Attacker = attacker,
			Damage = math.random(16, 28),
			Force = 12,
			Distance = 720,
			Num = 1,
			Tracer = 1,
			Dir = dir,
			Src = src,
			AmmoType = "Buckshot",
			IgnoreEntity = veh,
			Callback = function(_, tr, dmg)
				if not tr.Hit or not IsValid(tr.Entity) then return end
				if tr.Entity.LVS or tr.Entity == veh then
					dmg:SetDamage(0)
				end
			end,
		})
	end
end

hook.Add("LVS.OnVehicleDestroyed", "zc_lvs_explode_org", function(veh, attacker, inflictor)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(veh) then return end
	if isfunction(veh.GetEveryone) then
		for _, ply in ipairs(veh:GetEveryone()) do
			if IsValid(ply) then
				ZC_LVS.AllowExit(ply)
			end
		end
	end

	if cvBool("zc_lvs_explode_damage") then
		ZC_LVS._hurtingOccupants = true
		-- Wrecked while moving: the blast itself plus the tumble out.
		-- Static wreck = flat 42; fast wreck scales up to 70 (soft organs,
		-- not gibbing — the flat 42 is already near ZC blast tolerance).
		local speed = veh:GetVelocity():Length()
		local amount = 42 + math.Clamp((speed - 200) / 20, 0, 28)
		hurtOccupants(veh, amount, DMG_BLAST, attacker, inflictor, veh:GetPos())
		ZC_LVS._hurtingOccupants = false
	end

	fireShrapnel(veh, attacker, inflictor)

	-- Planes that slam the ground must dump the pilot.
	if ZC_LVS.IsAircraft(veh) and ZC_LVS.EjectPlayer and isfunction(veh.GetEveryone) then
		for _, ply in ipairs(veh:GetEveryone()) do
			if IsValid(ply) and ply:IsPlayer() and ply:Alive() and ply:InVehicle() then
				ZC_LVS.EjectPlayer(ply, veh, true)
			end
		end
	end
end)

-- Engine too wrecked to start.
hook.Add("LVS.IsEngineStartAllowed", "zc_lvs_wrecked_engine", function(veh)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(veh) then return end
	if veh._EngineDestroyed then return false end
	if veh.IsDestroyed and veh:IsDestroyed() then return false end
	if isfunction(veh.GetHP) and isfunction(veh.GetMaxHP) then
		local max = veh:GetMaxHP()
		if max > 0 and veh:GetHP() / max <= 0.12 then
			return false
		end
	end
end)

-- ZC only calls hg.VehiclePenetration if ent:IsVehicle(). LVS hull is not
-- a vehicle. Keep our PostEntityTakeDamage path, and also wrap the function
-- so anything else that calls it with an LVS ent still works.
if hg and hg.VehiclePenetration and not ZC_LVS._wrappedVehPen then
	ZC_LVS._origVehPen = hg.VehiclePenetration
	ZC_LVS._wrappedVehPen = true
	function hg.VehiclePenetration(ent, tr, bullet)
		if ZC_LVS.Enabled() and IsValid(ent) and ent.LVS then
			local pen = (istable(bullet) and tonumber(bullet.Penetration)) or 0
			local need = ZC_LVS.ArmorNeed(ent)
			local sew = pen >= need
			return sew, sew and math.Clamp(pen / math.max(need, 1), 1, 4) or 0.1
		end
		return ZC_LVS._origVehPen(ent, tr, bullet)
	end
end

-- ZC only calls hg.VehiclePenetration if ent:IsVehicle(). LVS hull is not
-- a vehicle entity. Caliber vs LVS armor class lives here.
local function zcBulletPen(dmginfo)
	local inf = dmginfo:GetInflictor()
	if IsValid(inf) and isnumber(inf.Penetration) then
		return inf.Penetration
	end
	local atk = dmginfo:GetAttacker()
	if IsValid(atk) and atk.IsPlayer and atk:IsPlayer() then
		local wep = atk:GetActiveWeapon()
		if IsValid(wep) and isnumber(wep.Penetration) then
			return wep.Penetration
		end
	end
	return 0
end

-- Matches ZC hg.vehicledetails.penetration: higher = thicker.
-- 9mm ~4–8, 5.56 ~12–18, 7.62 ~20+, .50/14.5 ~40+.
function ZC_LVS.ArmorNeed(veh)
	if ZC_LVS.IsClosedVehicle(veh) then
		return 38
	end
	if ZC_LVS.GetType(veh) == "gunner" then
		return 18
	end
	if ZC_LVS.IsAircraft(veh) then
		return 10
	end
	-- 9x18 in ZC is Penetration 4. need=5 meant pistols never sewed cars.
	return 4
end

hook.Add("PostEntityTakeDamage", "zc_lvs_caliber_pen", function(ent, dmginfo, took)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ent) or not ent.LVS then return end
	if not (dmginfo:IsBulletDamage() or dmginfo:IsDamageType(DMG_BUCKSHOT) or dmginfo:IsDamageType(DMG_SNIPER)) then
		return
	end
	if not isfunction(ent.GetHP) or not isfunction(ent.SetHP) then return end
	local pen = zcBulletPen(dmginfo)
	local need = ZC_LVS.ArmorNeed(ent)
	if pen < need then return end
	-- LVS already ate ~90% of bullet damage (or ignored tanks). Put sew back.
	local extra = math.max(1, dmginfo:GetDamage()) * math.Clamp(pen / need, 1, 4)
	if ZC_LVS.IsClosedVehicle(ent) then
		extra = extra * 0.45
	end
	ent:SetHP(math.max(-ent:GetMaxHP(), ent:GetHP() - extra))
end)

-- LVS fuel tank is SOLID_NONE; hits land on the hull. Test the real
-- tank box (AddFuelTank DS), not "rear underside of the OBB".
local function fuelTankHitBox(veh, tank)
	local pos = tank:GetPos()
	local ang = tank:GetAngles()
	if istable(veh._dmgParts) then
		for i = 1, #veh._dmgParts do
			local part = veh._dmgParts[i]
			if not part or not isvector(part.pos) then continue end
			local wpos = veh:LocalToWorld(part.pos)
			if wpos:DistToSqr(pos) < 48 * 48 then
				return part.mins or Vector(-15, -15, -5), part.maxs or Vector(15, 15, 5), wpos, veh:LocalToWorldAngles(part.ang or angle_zero)
			end
		end
	end
	return Vector(-18, -18, -8), Vector(18, 18, 10), pos, ang
end

local function hitLVSFuelTank(ent, hitPos, dmginfo)
	if ZC_LVS.GetType(ent) == "gunner" then return false end
	local tank = ZC_LVS.GetFuelTank(ent)
	if not IsValid(tank) then return false end
	local mins, maxs, pos, ang = fuelTankHitBox(ent, tank)
	-- Pad so a shot on the skin next to the tank still counts.
	mins = mins - Vector(10, 10, 6)
	maxs = maxs + Vector(10, 10, 8)
	local dir = dmginfo:GetDamageForce()
	if not isvector(dir) or dir:LengthSqr() < 4 then
		dir = pos - hitPos
	end
	if dir:LengthSqr() < 4 then
		dir = -ent:GetUp() * 64
	end
	dir = dir:GetNormalized() * 72
	local start = hitPos - dir:GetNormalized() * 12
	if util.IntersectRayWithOBB(start, dir, pos, ang, mins, maxs) then
		return true, tank
	end
	local lp = WorldToLocal(hitPos, angle_zero, pos, ang)
	if lp.x > mins.x and lp.x < maxs.x and lp.y > mins.y and lp.y < maxs.y and lp.z > mins.z and lp.z < maxs.z then
		return true, tank
	end
	return false, tank
end

local function applyFuelHit(ent, tank, dmginfo)
	if not cvBool("zc_lvs_fuel_leak") then return end
	ent._zc_lvs_fuel_leak = math.min((ent._zc_lvs_fuel_leak or 0) + 0.007, 0.045)
	if IsValid(tank) and tank.GetFuel and tank.SetFuel then
		tank:SetFuel(math.max(0, tank:GetFuel() - 0.04))
		if isfunction(tank.TakeTransmittedDamage) then
			local td = DamageInfo()
			td:SetDamage(math.random(10, 18))
			td:SetAttacker(IsValid(dmginfo:GetAttacker()) and dmginfo:GetAttacker() or ent)
			td:SetInflictor(IsValid(dmginfo:GetInflictor()) and dmginfo:GetInflictor() or ent)
			td:SetDamageType(dmginfo:GetDamageType())
			tank:TakeTransmittedDamage(td)
		end
	end
	local igniteChance = 0.07 + (ent._zc_lvs_fuel_leak or 0) * 5
	if math.Rand(0, 1) < igniteChance and not ent:IsOnFire() then
		ent:Ignite(12, 40)
	end
end

-- Front-low = engine (more damage). Fuel = real LVS tank entity.
hook.Add("EntityTakeDamage", "zc_lvs_weak_points", function(ent, dmginfo)
	if not ZC_LVS.Enabled() then return end
	if not IsValid(ent) or not ent.LVS then return end
	if not (dmginfo:IsBulletDamage() or dmginfo:IsDamageType(DMG_BUCKSHOT) or dmginfo:IsDamageType(DMG_BLAST)) then
		return
	end

	local hitPos = dmginfo:GetDamagePosition()
	if not hitPos then return end

	local fuelHit, tank = hitLVSFuelTank(ent, hitPos, dmginfo)
	if fuelHit then
		applyFuelHit(ent, tank, dmginfo)
	end

	-- LVS AddDS already runs component callbacks. Do not also guess
	-- "front-low = engine" when the vehicle has real DS boxes.
	if istable(ent._dmgParts) and #ent._dmgParts > 0 then
		return
	end

	local lp = ent:WorldToLocal(hitPos)
	local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
	local h = maxs.z - mins.z
	local depth = maxs.x - mins.x
	if h < 8 or depth < 8 then return end
	local zFrac = (lp.z - mins.z) / h
	if zFrac < 0.42 and lp.x > mins.x + depth * 0.58 then
		dmginfo:ScaleDamage(1.35)
	end
end)

timer.Create("zc_lvs_fuel_leak", 0.5, 0, function()
	if not ZC_LVS.Enabled() then return end
	if not cvBool("zc_lvs_fuel_leak") then return end
	if not LVS or not isfunction(LVS.GetVehicles) then return end

	for _, veh in ipairs(LVS:GetVehicles() or {}) do
		if not IsValid(veh) then continue end
		local leak = veh._zc_lvs_fuel_leak
		if not leak or leak <= 0 then continue end

		local tank = ZC_LVS.GetFuelTank(veh)
		if IsValid(tank) and tank.GetFuel and tank.SetFuel then
			local left = tank:GetFuel()
			if left > 0 then
				tank:SetFuel(math.max(0, left - leak))
			end
		end

		if leak > 0.012 and not veh:IsOnFire() and math.Rand(0, 1) < 0.035 then
			veh:Ignite(8, 28)
		end
	end
end)

-- Burning wreck: heat soaks into the organism until it explodes.
-- Open hull (Bukhanka, jeep): flames reach the body — DMG_BURN, ZC then
-- runs its own DMG_BURN→lungs/organ damage. Closed hull (tank/APC):
-- heat still soaks but slower, and smoke does the lungs through
-- hg.organism.GasDamage (the same ZC path NERVEGAS uses).
timer.Create("zc_lvs_fire_burn", 0.55, 0, function()
	if not ZC_LVS.Enabled() then return end
	if not LVS or not isfunction(LVS.GetVehicles) then return end

	for _, veh in ipairs(LVS:GetVehicles() or {}) do
		if not IsValid(veh) then continue end
		local burning = veh:IsOnFire() or (veh.IsDestroyed and veh:IsDestroyed())
		if not burning then continue end
		local onFire = veh:IsOnFire()

		local openHull = veh._zc_lvs_fire_open
		if openHull == nil then
			openHull = (ZC_LVS.IsAircraft(veh) or ZC_LVS.IsOpenCarHull(veh)) and true or false
			veh._zc_lvs_fire_open = openHull
		end

		ZC_LVS.IterOccupants(veh, function(ply)
			if not ply:Alive() then return end
			local target = organismTarget(ply)
			if not IsValid(target) then return end
			if openHull then
				local dmg = DamageInfo()
				dmg:SetDamage(onFire and 5 or 3)
				dmg:SetAttacker(veh)
				dmg:SetInflictor(veh)
				dmg:SetDamageType(DMG_BURN)
				dmg:SetDamagePosition(target:GetPos())
				target:TakeDamageInfo(dmg)
				-- vFire actually catches the dummy: ZC replaces ent:Ignite
				-- with vFire (characters get body fires). Ragdoll counts.
				if onFire and target:IsRagdoll() and not target:IsOnFire() then
					if isfunction(CreateVFireEntFires) then
						pcall(CreateVFireEntFires, target, 2)
					elseif isfunction(CreateVFire) then
						pcall(CreateVFire, target, target:GetPos(), vector_up, 50, target)
					end
				end
			else
				-- Closed armor: slower roast + smoke in the lungs.
				local dmg = DamageInfo()
				dmg:SetDamage(onFire and 2 or 1)
				dmg:SetAttacker(veh)
				dmg:SetInflictor(veh)
				dmg:SetDamageType(DMG_BURN)
				dmg:SetDamagePosition(target:GetPos())
				target:TakeDamageInfo(dmg)
				local org = ply.organism
				if org and hg and hg.organism and isfunction(hg.organism.GasDamage) then
					hg.organism.GasDamage(org, onFire and 1.2 or 0.6, dmg)
				end
			end
		end)
	end
end)

-- If the chassis is deleted while occupied, still dump the organism out as ragdoll.
hook.Add("EntityRemoved", "zc_lvs_removed", function(ent)
	if not ZC_LVS.Enabled() then return end
	if not ent.LVS then return end
	if not isfunction(ent.GetEveryone) then return end

	local ok, everyone = pcall(ent.GetEveryone, ent)
	if not ok or not istable(everyone) then return end

	for _, ply in ipairs(everyone) do
		if not IsValid(ply) or not ply:IsPlayer() then continue end
		local rag = ply.FakeRagdoll
		if IsValid(rag) then
			rag.zc_lvs_follow = nil
			rag.zc_lvs_follow_local = nil
			rag.zc_lvs_seatfake = nil
			rag:SetParent(NULL)
			rag.removingwelds = true
			if rag.welds then
				for _, weld in pairs(rag.welds) do
					if IsValid(weld) then weld:Remove() end
				end
				rag.welds = nil
			end
		end
		if ply:InVehicle() then
			ZC_LVS.AllowExit(ply)
			ply:ExitVehicle()
		end
		timer.Simple(0, function()
			if not IsValid(ply) or ply:InVehicle() then return end
			if ply:GetMoveType() == MOVETYPE_NOCLIP and not (ply.organism and ply.organism.otrub) then
				ply:SetMoveType(MOVETYPE_WALK)
			end
			ply:SetCollisionGroup(COLLISION_GROUP_PLAYER)
			ply:SetNoDraw(false)
			if hg and isfunction(hg.FakeUp) and IsValid(ply.FakeRagdoll) then
				if not (ply.organism and ply.organism.otrub) then
					ply.FakeRagdoll.removingwelds = true
					hg.FakeUp(ply, true, true)
				end
			end
		end)
	end
	for _, ply in player.Iterator() do
		if ply.zc_lvs_cargo == ent and ZC_LVS.ExitCargo then
			ZC_LVS.ExitCargo(ply, true)
		end
	end
end)
