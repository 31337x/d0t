#!/usr/bin/env python3
"""Run parser/service tests with system Lua 5.4 when Luau CLI is unavailable.

The only syntax conversion is Luau's compound assignments. This checks behavior,
not Noctalia's VM budgets or rendering; lint and a live shell check those.
"""
import ctypes
import ctypes.util
import json
import pathlib
import re
import tempfile
import sys
import tomllib

def lua(value):
    if isinstance(value, str):
        # Lua long strings preserve TOML backslashes and newlines exactly.
        delimiter = '='
        while ']' + delimiter + ']' in value:
            delimiter += '='
        return '[' + delimiter + '[\n' + value + ']' + delimiter + ']'
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, dict):
        return '{' + ','.join('[ ' + lua(k) + ' ]=' + lua(v) for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '{' + ','.join(map(lua, value)) + '}'
    return str(value)

ROOT = pathlib.Path(__file__).resolve().parents[1]
lib = ctypes.CDLL(ctypes.util.find_library('lua-5.4') or 'liblua-5.4.so')
lib.luaL_newstate.restype = ctypes.c_void_p
lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
lib.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ssize_t, ctypes.c_void_p]
lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lib.lua_tolstring.restype = ctypes.c_char_p
lib.lua_close.argtypes = [ctypes.c_void_p]

with tempfile.TemporaryDirectory(prefix='umbriel-tests-') as temporary:
    for path in ROOT.rglob('*.luau'):
        source = re.sub(r'(\b\w+(?:\[[^\]\n]+\]|\.\w+)*)\s*([+-])=\s*([#\w.]+)',
                        lambda m: f'{m[1]} = {m[1]} {m[2]} {m[3]}', path.read_text())
        dest = pathlib.Path(temporary) / path.relative_to(ROOT)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(source)
    program = '''
local cache = {}
getfenv = function() return _G end -- Luau's callback export environment
math.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
function require(name)
  name = name:gsub('^%./', ''):gsub('%.luau$', '')
  if cache[name] then return cache[name] end
  local chunk = assert(loadfile(ROOT .. '/' .. name .. '.luau'))
  cache[name] = chunk()
  return cache[name]
end
require('./tests/test_umbriel')
'''
    fixtures = { '/plugin/' + str(p.relative_to(ROOT)): p.read_text()
                 for p in (ROOT / 'tests/fixtures').rglob('*') if p.is_file() }
    expected = json.loads((ROOT / 'tests/expected.json').read_text())
    translations = json.loads((ROOT / 'translations/en.json').read_text())
    hypr_json = json.loads((ROOT / 'tests/fixtures/hypr/binds.json').read_text())
    program += '''
local host = require('./tests/host_mock')
local service = require('./service.luau')
host.setFiles(FIXTURES)
host.noctalia.tr = function(key) return TRANSLATIONS[key] or key end
host.setFile('/plugin/tests/expected.json', host.noctalia.json.encode(EXPECTED))
host.setFile('/plugin/tests/fixtures/hypr/binds.json', host.noctalia.json.encode(HYPR_JSON))
service.runSelfTest()
local report = host.noctalia.json.decode(host.fileContent('/data/selftest.json'))
assert(report.passed, 'Upstream parser regression')
print('Upstream: all five parser fixture suites passed')
'''
    program = ('FIXTURES=' + lua(fixtures) + '\nEXPECTED=' + lua(expected) +
               '\nTRANSLATIONS=' + lua(translations) + '\nHYPR_JSON=' + lua(hypr_json) + '\n' + program)
    if len(sys.argv) > 1:
        config = pathlib.Path(sys.argv[1]).resolve()
        config_files = {}
        def load_config(path, active=()):
            path = path.resolve()
            if path in active:
                raise ValueError('Include cycle')
            content = path.read_text()
            config_files[str(path)] = content
            data = tomllib.loads(content)
            binds = {}
            includes = data.get('include', {})
            for optional, paths in ((False, includes.get('files', [])),
                                    (True, includes.get('optional', {}).get('files', []))):
                for include in paths:
                    import os
                    child = pathlib.Path(os.path.expandvars(os.path.expanduser(include)))
                    if not child.is_absolute():
                        child = path.parent / child
                    if optional and not child.exists():
                        continue
                    binds.update(load_config(child, (*active, path)))
            binds.update(data.get('keybinds', {}))
            return binds
        binds = load_config(config)
        program += ('\nhost.setFiles(' + lua(config_files) + ')\nhost.setConfig({compositor="umbriel",umbriel_config=' + lua(str(config)) + '})\n' +
                    'service.resetForTests()\nlocal snapshot=host.stateValue(service.snapshotKey)\n' +
                    'assert(snapshot.status=="ready", snapshot.error)\n' +
                    'assert(#snapshot.bindings==' + str(len(binds)) + ', "Config binding count mismatch")\n' +
                    'for _, b in ipairs(snapshot.bindings) do assert(b.description ~= "") end\n' +
                    'print("Local config: " .. #snapshot.bindings .. " bindings parsed with descriptions")\n')
    program = 'ROOT = "' + temporary + '"\n' + program
    state = lib.luaL_newstate()
    try:
        lib.luaL_openlibs(state)
        status = lib.luaL_loadstring(state, program.encode())
        if status == 0:
            status = lib.lua_pcallk(state, 0, -1, 0, 0, None)
        if status:
            raise SystemExit(lib.lua_tolstring(state, -1, None).decode())
    finally:
        lib.lua_close(state)
