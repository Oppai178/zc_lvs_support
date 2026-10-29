-- [Z-CITY] LVS SUPPORT
-- Author: Oppai
-- LVS HE / splash / bombs use the REAL Z-City explosion pipeline:
-- grenade-style shrapnel (FireLuaBullets "Metal Debris"), grenade
-- detonate sound (net "projectileFarSound"), jack-airsplode particles.
-- Does not patch LVS files. Wraps LVS:BlastDamage.

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

-- Native Z-City shrapnel (the F1/RGN grenade mechanic, mirror of
-- ent_hg_grenade/init.lua ENT:Explode -> FireLuaBullets coroutine):
-- random hemisphere-biased dirs, QuickTrace gate (only entities get a
-- fragment, world/sky rays are skipped), ammo "Metal Debris"
-- (sh_ammostuff.lua: Speed 700, Penetration 8).
local function zcShrapnel(pos, attacker, inflictor, fragments, fragDamage, fragDistance, fragPen, filter)
	local world = game.GetWorld()
	if not isfunction(world.FireLuaBullets) then return end

	local bullet = {}
	bullet.Src = pos
	bullet.Spread = vector_origin
	bullet.Force = 20
	bullet.Damage = fragDamage
	bullet.Speed = 700 -- "Metal Debris" BulletSettings.Speed, as the grenade uses
	bullet.Penetration = fragPen
	bullet.AmmoType = "Metal Debris"
	bullet.Attacker = IsValid(attacker) and attacker or world
	bullet.Inflictor = IsValid(inflictor) and inflictor or world
	bullet.Distance = fragDistance
	bullet.DisableLagComp = true
	bullet.Filter = filter
	bullet.TraceFilter = filter -- phys_bullets path reads TraceFilter
	bullet.IgnoreEntity = filter[1]
	if isfunction(hg.bulletHit) then
		bullet.Callback = hg.bulletHit
	end

	local co = coroutine.create(function()
		local lastShrapnel = SysTime()
		for _ = 1, fragments do
			lastShrapnel = SysTime()

			local dir = VectorRand(-1, 1):GetNormalized()
			dir.z = dir.z > 0 and math.abs(dir.z - 0.5) or -math.abs(dir.z + 0.5)
			dir:Normalize()

			local tr = util.QuickTrace(pos, dir * 10000, filter)
			if tr.Hit and not tr.HitSky and not tr.HitWorld then
				bullet.Dir = dir
				pcall(world.FireLuaBullets, world, bullet, true)
			end

			lastShrapnel = SysTime() - lastShrapnel
			if lastShrapnel > 0.001 then
				coroutine.yield()
			end
		end
	end)

	-- Entity-less scheduling, exactly like Z-City's explosive ammo
	-- (sh_ammostuff.lua APScheduledExplosions Think hook). Fallback:
	-- drain synchronously if Z-City's table is missing.
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

local function zcHeBoom(pos, radius, damage, attacker, inflictor)
	if not isvector(pos) then return end
	radius = tonumber(radius) or 0
	damage = tonumber(damage) or 0
	-- SMALL CALIBER (Oppai, asked 10x): 20mm autocannons and other light
	-- HE (radius < 48 AND damage < 25) get the REAL Z-City grenade
	-- explosion at RGN scale — native shrapnel mechanic included.
	-- Big shells run the SAME Z-City pipeline, only the scale differs.
	local small = radius < 48 and damage < 25
	if radius < 12 and damage < 5 then return end -- bullet-impact dust, not HE

	local now = CurTime()
	-- Spam filter: an autocannon burst walks its impacts across ground /
	-- targets, so only SAME-POSITION repeats inside the window are eaten.
	-- 0.12s small / 0.04s big, per pos — a queue never loses every boom.
	local spamT = small and 0.12 or 0.04
	if now - lastBoom < spamT and lastPos:DistToSqr(pos) < 64 * 64 then
		return
	end
	lastBoom = now
	lastPos = pos

	local reach = math.max(radius, small and 90 or 120)

	-- HE near armor: ZC disorientation only touches entities the sphere
	-- sees directly. Seated players inside a closed hull (their fake is
	-- parented under the hull) never pass that FindInSphere test.
	-- Route the concussion through the hull with an armor cut. Runs even
	-- with FX off: this is damage, not cosmetics. (No AddForceRag on
	-- seated fakes — parented ragdolls never get velocities, per contract.)
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
				-- Closed armor soaks the blast: weaker shake, no concussion.
				local scale = closed and 0.25 or 1
				if small then scale = scale * 0.5 end
				org.disorientation = math.min((org.disorientation or 0) + 5 * frac * scale, 8)
				if isfunction(ply.AddTinnitus) then
					ply:AddTinnitus(4 * frac * scale)
				end
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

	-- Shrapnel filter: never frag the shooter or his own weapon/vehicle.
	local filter = {}
	if IsValid(attacker) then filter[#filter + 1] = attacker end
	if IsValid(inflictor) and inflictor ~= attacker then filter[#filter + 1] = inflictor end

	if GetConVar("zc_lvs_shrapnel"):GetBool() then
		-- F1 grenade = 300*3 fragments (ent_hg_grenade/shared.lua:13).
		-- Small caliber = RGN scale 0.55; big shells scale with radius.
		local scale = small and 0.55 or math.Clamp(radius / 110, 0.9, 1.5)
		local fragments = math.Round((small and 450 or 900) * scale)
		local fragDamage = small and 12 or 40 -- grenade shrapnel bullet.Damage (small cut: direct LVS dmg already lands)
		local fragDistance = small and 700 or 2500
		local fragPen = small and 5 or 8 -- grenade Penetration
		zcShrapnel(pos, attacker, inflictor, fragments, fragDamage, fragDistance, fragPen, filter)
	end

	if not GetConVar("zc_lvs_he_fx"):GetBool() then return end

	-- Water check (grenade uses WaterLevel; we have no entity, so sample
	-- the position itself).
	local inWater = bit.band(util.PointContents(pos), MASK_WATER) ~= 0

	-- Grenade detonate sound through Z-City's own receiver: near + far
	-- variants with real distance delay (entities/projectile_base.lua:317).
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

	-- Z-City boom particles: grenade's airsplode_small3 for small calibers,
	-- projectile_base's airsplode_medium for big shells; water gets the
	-- generic boom. Registered by Z-City itself
	-- (entities/projectile_base.lua:28-30 game.AddParticles).
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
		-- Secondary frag flash, same as the grenade's Poof.
		local poof = EffectData()
		poof:SetOrigin(pos)
		poof:SetScale(1.2)
		util.Effect("eff_jack_hmcd_shrapnel", poof, true, true)
	end)

	util.ScreenShake(pos, 35, 200, 1, small and 600 or 2000)

	-- Scorch decal for the big stuff only (autocannon spam would tattoo
	-- the whole map); one trace down, one decal.
	if not small then
		local tr = util.QuickTrace(pos, -vector_up * 500, filter)
		if tr.Hit then
			util.Decal("Scorch", tr.HitPos + tr.HitNormal, tr.HitPos - tr.HitNormal)
		end
	end
end

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
