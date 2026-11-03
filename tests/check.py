"""Syntax and actual segment helper checks using system liblua5.4; no Roblox runtime."""
import ctypes
from pathlib import Path

root = Path(__file__).resolve().parents[1]
lib = ctypes.CDLL('liblua5.4.so.0')
ptr = ctypes.c_void_p
lib.luaL_newstate.restype = ptr
lib.luaL_openlibs.argtypes = [ptr]
lib.luaL_loadfilex.argtypes = [ptr, ctypes.c_char_p, ctypes.c_char_p]
lib.luaL_loadstring.argtypes = [ptr, ctypes.c_char_p]
lib.lua_pcallk.argtypes = [ptr, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ptr]
lib.lua_tolstring.argtypes = [ptr, ctypes.c_int, ptr]
lib.lua_tolstring.restype = ctypes.c_char_p
lib.lua_close.argtypes = [ptr]
state = lib.luaL_newstate()

def check(code):
    assert code == 0, lib.lua_tolstring(state, -1, None)

try:
    check(lib.luaL_loadfilex(state, str(root / 'uf-tracker.client.luau').encode(), None))
    source = (root / 'uf-tracker.client.luau').read_text()
    helper = source.split('local function segmentDistance(a, b)', 1)[1].split('\nlocal orb', 1)[0]
    harness = '''
math.clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local mt = {}
local function v(x, y, z) return setmetatable({x=x, y=y, z=z}, mt) end
mt.__add = function(a,b) return v(a.x+b.x,a.y+b.y,a.z+b.z) end
mt.__sub = function(a,b) return v(a.x-b.x,a.y-b.y,a.z-b.z) end
mt.__mul = function(a,b) return v(a.x*b,a.y*b,a.z*b) end
mt.__index = function(a,k)
    if k == 'Magnitude' then return math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z) end
    if k == 'Dot' then return function(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end end
end
'''
    cases = '''
assert(segmentDistance(v(-30,0,0),v(30,0,0)) == 0, 'fast crossing')
assert(segmentDistance(v(-30,25,0),v(30,25,0)) == 25, 'near miss')
assert(segmentDistance(v(-30,20,0),v(30,20,0)) == 20, 'tangent')
assert(segmentDistance(v(30,0,0),v(30,0,0)) == 30, 'stationary')
assert(segmentDistance(v(30,0,0),v(40,0,0)) == 30, 'moving away')
assert(segmentDistance(v(30,0,0),v(10,0,0)) == 10, 'outside to inside')
'''
    cases += """
assert(entersOrb(nil, v(10,0,0), 20, false), 'first sample inside')
assert(not entersOrb(nil, v(30,0,0), 20, false), 'first sample outside')
assert(entersOrb(v(-30,0,0), v(30,0,0), 20, true), 'sampled crossing')
assert(not entersOrb(v(-30,0,0), v(30,0,0), 20, false), 'invalid segment')
assert(not entersOrb(v(-30,25,0), v(30,25,0), 20, true), 'orb near miss')
"""
    restoration = source.split('local pendingMove', 1)[1].split('local function snapshot(ball)', 1)[0]
    restore_setup = """
local records = { { relative = 1, rootPosition = 2, rootRef = 3 } }
local player, observed = {}, {}
local function emit(kind, record, data) observed[#observed+1] = data end
"""
    restore_cases = """
local character = {}
local root = { IsDescendantOf = function(self, other) return other == character end }
local humanoid = { Health = 100 }
player.Character = character
local function saved()
    return { root = root, character = character, humanoid = humanoid,
        cframe = 10, linear = 20, angular = 30, id = 'B0001' }
end
pendingMove = saved()
restoreMove('disabled')
assert(root.CFrame == 10 and root.AssemblyLinearVelocity == 20 and root.AssemblyAngularVelocity == 30)
assert(pendingMove == nil and records[1].relative == nil and observed[1].restored)
restoreMove('closed')
assert(#observed == 1, 'restoration must be idempotent')
root.CFrame = 99
player.Character = {}
pendingMove = saved()
restoreMove('respawn')
assert(root.CFrame == 99 and not observed[2].restored, 'replacement character guard')
player.Character = character
humanoid.Health = 0
pendingMove = saved()
restoreMove('death')
assert(root.CFrame == 99 and not observed[3].restored, 'dead character guard')
"""
    lib.luaL_openlibs(state)
    check(lib.luaL_loadstring(state, (harness + 'local function segmentDistance(a, b)' + helper + cases + restore_setup + 'local pendingMove' + restoration + restore_cases).encode()))
    check(lib.lua_pcallk(state, 0, 0, 0, 0, None))
    print('PASS: syntax, geometry, inside-first detection and restoration/cancellation guards; Roblox APIs not executed')
    runtime = "TEST_SCRIPT_PATH = " + repr(str(root / 'uf-tracker.client.luau')) + "\n" + (root / 'tests/runtime.lua').read_text()
    check(lib.luaL_loadstring(state, runtime.encode()))
    check(lib.lua_pcallk(state, 0, 0, 0, 0, None))
finally:
    lib.lua_close(state)
