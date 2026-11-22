#!/usr/bin/env python3
"""Run the Lua tests under LuaJIT (the same Lua flavour KOReader uses)."""
import datetime
import os
import sys
import tempfile
import time

os.environ["TZ"] = "America/New_York"
time.tzset()

try:  # LuaJIT is what KOReader runs; plain Lua 5.1 is close enough when lupa has no LuaJIT build
    from lupa.luajit21 import LuaRuntime  # noqa: E402
except ImportError:
    from lupa.lua51 import LuaRuntime  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.environ.get("PLUGIN_DIR") or os.path.join(HERE, "..", "ticktick.koplugin")


def run(test_file: str) -> int:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        'package.path = "%s/?.lua;%s/?.lua;" .. package.path' % (HERE, PLUGIN)
    )
    g = lua.globals()
    g.EXPECT_DAYS_2026_11_04 = (datetime.date(2026, 11, 4) - datetime.date(1970, 1, 1)).days
    g.TEST_TMPDIR = tempfile.mkdtemp(prefix="ticktick-test-")
    with open(os.path.join(HERE, test_file), encoding="utf-8") as handle:
        chunk = lua.eval("function(src, name) return assert(loadstring(src, name)) end")(handle.read(), "@" + test_file)
    return int(chunk() or 0)


if __name__ == "__main__":
    failures = 0
    for name in sys.argv[1:] or ["test_logic.lua", "test_plugin.lua"]:
        failures += run(name)
    sys.exit(1 if failures else 0)
