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
    lib.luaL_openlibs(state)
    check(lib.luaL_loadstring(state, (harness + 'local function segmentDistance(a, b)' + helper + cases).encode()))
    check(lib.lua_pcallk(state, 0, 0, 0, 0, None))
    print('PASS: syntax and six segment-distance cases; Roblox APIs not executed')
finally:
    lib.lua_close(state)
