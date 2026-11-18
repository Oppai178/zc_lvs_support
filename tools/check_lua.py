#!/usr/bin/env python3
"""Syntax-check all zc_lvs_support lua files with REAL Lua (lupa).

luaparser silently swallowed some errors ("syntax errors: None") and let
a stray `end` through (clip 06.10). lupa runs actual load() with a line
number. GMod-only tokens are stubbed first: `continue` -> `do end`.
Usage: python tools/check_lua.py [file ...]
"""
import sys
from pathlib import Path
import re


def check(path: Path) -> bool:
    src = path.read_text(encoding="utf-8", errors="replace")
    if src.startswith("﻿"):
        print(f"[FAIL] {path}: UTF-8 BOM at file start")
        return False
    src = re.sub(r"(?<![.\w])continue(?=\s)", "do end", src)
    try:
        from lupa import LuaRuntime
        lua = LuaRuntime()
        fn = lua.eval("function(src) local f, err = load(src) if f then return 'OK' else return err end end")
        result = str(fn(src))
    except ImportError:
        print(f"[skip] {path}: lupa not installed (pip install lupa)")
        return True
    if result != "OK":
        print(f"[FAIL] {path}: {result}")
        return False
    print(f"[ ok ] {path}")
    return True


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    files = [root / "lua" / "autorun" / "sh_zc_lvs_support.lua"]
    files += sorted((root / "lua" / "zc_lvs_support").glob("*.lua"))
    # autorun/server and autorun/client were never checked before, which is
    # how a file with raw newlines inside string literals got shipped
    # (zc_lvs_dump.lua, "unfinished string"). Scan the whole lua tree.
    files += sorted(p for p in (root / "lua").rglob("*.lua")
                    if "zc_lvs_support" not in p.parts)
    files = sorted(set(files))
    if len(sys.argv) > 1:
        files = [Path(a) for a in sys.argv[1:]]
    ok = all(check(f) for f in files)
    print("ALL OK" if ok else "FAILURES PRESENT")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
