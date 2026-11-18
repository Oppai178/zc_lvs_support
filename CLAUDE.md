# zc_lvs_support — briefing for Claude Code

You are continuing Oppai's Garry's Mod addon. Speak Russian with the user. Do not rewrite the architecture. After lua edits, copy `lua` (and addon files) into `D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod\addons\zc_lvs_support`. User fully restarts GMod to test.

Working copy: `C:\Users\lazyg\OneDrive\Desktop\zc_mod\zc_lvs_support`
(Moved 18.10 from `C:\Users\lazyg\Desktop\zc_mod` — that was a legacy path;
the real desktop is the OneDrive one. The old copy still exists but is
NOT the working copy — do not edit there.)
Game copy: `D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod\addons\zc_lvs_support`

Full Codex chat extract: `CODEX_HISTORY.md` (read it if you need prior decisions).
Gameplay contract (same as Grok memory): keep driving, camera, and ragdoll/damage/eject separate. Live player stays in the LVS seat. Never `SetPos` a parented ragdoll, never weld a living driver, never BindSeatFake. Hatch/«дед» is the live player mesh in the roof pod — hide it, do not Fake the turret. Crash eject: 2.3.0 was the good feel (fake in seat, ragdoll eject). Bukhanka/ZAZ first; if that is broken, stop.

Read `lua/autorun/sh_zc_lvs_support.lua` for `ZC_LVS.Version` and the loader. Modules are under `lua/zc_lvs_support/`.
