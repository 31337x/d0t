local reader = require('./umbriel.luau')
local host = require('./tests/host_mock')
local service = require('./service.luau')
local checks = 0
local function equal(a, b)
  assert(a == b, tostring(a) .. ' != ' .. tostring(b))
  checks = checks + 1
end
local text = [====[
[general]
mod_key = "Alt"
[include]
files = [
  "first.toml", # separate comment
  'second.toml',
]
[include.optional]
files = ["missing.toml"]
[keybinds]
# Category: My Applications
"Mod+Return" = "spawn:kitty" # Open my terminal
"Mod+H" = { action = "spawn:printf \"# hello\"", repeat = false } # Print a greeting
'Mod+Q' = 'window-close' # Close the focused window
"submap[capture],R" = { action = "spawn:grim", submap = "reset" } # Capture screen
"Mod" = "overview-toggle" # Show overview
"Mod+MouseMiddle" = "layout-scroll-drag" # Drag the layout
"Mod+1" = "workspace-switch:1"
"Mod+U" = "spawn:echo \u263A" # Unicode works
[unrelated]
value = """
# This is inside a string
[keybinds]
"Fake" = "window-close"
"""
]====]
local parsed = reader.parse(text, '/config.toml')
equal(#parsed.bindings, 8)
equal(#parsed.includes, 3)
equal(parsed.includes[3].optional, true)
equal(parsed.modKey, 'Alt')
equal(parsed.bindings[1].description, 'Open my terminal')
equal(parsed.bindings[1].category, 'My Applications')
equal(parsed.bindings[2].action, 'spawn:printf "# hello"')
equal(parsed.bindings[2].description, 'Print a greeting')
equal(parsed.bindings[8].action, 'spawn:echo ☺')
local staged = reader.new(text, '/config.toml')
while not reader.step(staged, 3) do end
equal(#staged.bindings, #parsed.bindings)
for i, b in ipairs(parsed.bindings) do
  equal(staged.bindings[i].action, b.action)
  equal(staged.bindings[i].description, b.description)
end
equal(reader.describe('workspace-switch:3'), 'Switch to workspace 3')
equal(reader.describe('spawn:kitty'), 'Open terminal')
equal(reader.describe('window-focus-left'), 'Focus the window on the left')
equal(pcall(reader.parse, '[keybinds]\n"Mod+Q" = "unterminated', '/bad'), false)

local function snapshot(files)
  host.setFiles(files)
  host.setConfig({compositor='umbriel', umbriel_config='/config.toml'})
  service.resetForTests()
  return host.stateValue(service.snapshotKey)
end
local state = snapshot({
  ['/config.toml']=text,
  ['/first.toml']='[general]\nmod_key="Ctrl"\n[keybinds]\n"Mod+Return"="spawn:old" # Old description\n"Mod+X"="spawn:first" # First',
  ['/second.toml']='[keybinds]\n"Mod+X"="spawn:second" # Second',
})
equal(state.status, 'ready')
equal(#state.bindings, 9)
local found = {}
for _, b in ipairs(state.bindings) do found[b.key] = b end
equal(found.Return.description, 'Open my terminal')
equal(found.Return.modifiers[1], 'ALT')
equal(found.X.description, 'Second')
equal(found.R.submap, 'capture')
equal(found.Alt.description, 'Show overview')
equal(found['1'].description, 'Switch to workspace 1')
equal(found.Return.sourceLine, 12)
equal(service.lifecycleState().refreshing, false)
-- Missing required files must not publish a partial result as successful.
host.setFile('/config.toml', '[include]\nfiles=["absent.toml"]\n[keybinds]\n"Q"="window-close"')
service.refresh()
local failed = host.stateValue(service.snapshotKey)
equal(#failed.bindings, 9) -- previous successful snapshot retained
assert(failed.error ~= '')
-- Include cycles terminate and produce an error instead of looping.
state = snapshot({ ['/config.toml']='[include]\nfiles=["config.toml"]' })
equal(state.status, 'error')
-- Repeat includes are applied in order (not globally skipped).
state = snapshot({ ['/config.toml']='[include]\nfiles=["a.toml","b.toml","a.toml"]',
  ['/a.toml']='[keybinds]\n"Mod+X"="spawn:a" # A',
  ['/b.toml']='[keybinds]\n"Mod+X"="spawn:b" # B' })
equal(#state.bindings, 1)
equal(state.bindings[1].description, 'A')
-- Comments inside strings, escaped backslashes, and literal quoted values.
parsed = reader.parse([====[
[keybinds]
'Mod+P' = 'spawn:printf "# literal"' # Print literal text
"Mod+S" = { action = "spawn:echo C:\\temp", repeat = false } # Backslash
]====], '/quoted.toml')
equal(parsed.bindings[1].action, 'spawn:printf "# literal"')
equal(parsed.bindings[2].action, 'spawn:echo C:\\temp')
equal(parsed.bindings[2].description, 'Backslash')
-- Verify the comment reaches the panel's rendered description.
snapshot({ ['/config.toml']='[keybinds]\n"Mod+W"="spawn:~/scripts/work.sh" # Open my work setup' })
local panel = require('./panel.luau')
panel.onOpen()
equal(panel.lifecycleState().bindingCount, 1)
local function containsText(node, expected)
  if type(node) ~= 'table' then return false end
  if node.props and node.props.text == expected then return true end
  for _, child in pairs(node.children or {}) do
    if containsText(child, expected) then return true end
  end
  return false
end
equal(containsText(host.renderedTree(), 'Open my work setup'), true)
equal(panel.formatKey('MouseMiddle'), 'MMB')
equal(panel.formatKey('WheelUp'), 'Wheel Up')
panel.onClose()
print('Umbriel: ' .. checks .. ' assertions passed')
