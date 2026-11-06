--!nonstrict
-- Comment-preserving reader for Umbriel's documented TOML configuration forms.
-- Tokenize bounded chunks so large configs can use fresh Noctalia event budgets.
local M = {}
local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

function M.new(content, file)
  return { content = content, file = file, index = 1, line = 1, tokens = {},
    section = '', depth = 0, bindings = {}, includes = {}, category = '' }
end

local function value(tokens, i)
  local t = tokens[i]
  if not t then error('Missing TOML value') end
  if t.kind == 'string' then return t.value, i + 1 end
  if t.kind == '{' then
    local result = {}
    i = i + 1
    while tokens[i] and tokens[i].kind ~= '}' do
      local key = tokens[i].value
      if not tokens[i + 1] or tokens[i + 1].kind ~= '=' then error('Invalid inline table') end
      result[key], i = value(tokens, i + 2)
      if tokens[i] and tokens[i].kind == ',' then i = i + 1
      elseif tokens[i] and tokens[i].kind ~= '}' then error('Missing table comma') end
    end
    if not tokens[i] then error('Unclosed inline table') end
    return result, i + 1
  end
  if t.kind == '[' then
    local result = {}
    i = i + 1
    while tokens[i] and tokens[i].kind ~= ']' do
      local item
      item, i = value(tokens, i)
      table.insert(result, item)
      if tokens[i] and tokens[i].kind == ',' then i = i + 1
      elseif tokens[i] and tokens[i].kind ~= ']' then error('Missing array comma') end
    end
    if not tokens[i] then error('Unclosed array') end
    return result, i + 1
  end
  if t.value == 'true' then return true, i + 1 end
  if t.value == 'false' then return false, i + 1 end
  return tonumber(t.value) or t.value, i + 1
end

local function statement(s)
  local ts = s.tokens
  if #ts == 0 then return end
  if ts[1].kind == '[' then
    -- Recognize ordinary and quoted table components; ignore unrelated tables.
    local parts = {}
    for i = 2, #ts - 1 do
      if ts[i].kind ~= '.' then table.insert(parts, ts[i].value) end
    end
    s.section = table.concat(parts, '.')
    s.category = ''
  elseif ts[2] and ts[2].kind == '=' then
    local key = ts[1].value
    local relevant = s.section == 'keybinds' or
      ((s.section == 'include' or s.section == 'include.optional') and key == 'files') or
      (s.section == 'general' and key == 'mod_key')
    if relevant then
      local v, ending = value(ts, 3)
      if ending <= #ts then error('Unsupported TOML expression at line ' .. ts[1].line) end
      if s.section == 'keybinds' then
        local action = type(v) == 'table' and v.action or v
        if type(action) ~= 'string' then error('Binding action must be a string') end
        table.insert(s.bindings, { chord = key, action = action,
          description = trim(s.comment or ''), category = s.category,
          sourceFile = s.file, sourceLine = ts[1].line })
      elseif key == 'mod_key' then
        if type(v) ~= 'string' then error('mod_key must be a string') end
        s.modKey = v
      else
        if type(v) ~= 'table' then error('Include files must be an array') end
        for _, path in ipairs(v) do
          if type(path) ~= 'string' then error('Include path must be a string') end
          table.insert(s.includes, { path = path, optional = s.section == 'include.optional' })
        end
      end
    end
  end
  s.tokens, s.comment = {}, nil
end

function M.step(s, limit)
  local text = s.content
  for _ = 1, limit or 200 do
    local i = s.index
    if i > #text then
      if s.quote or s.depth ~= 0 then error('Unclosed TOML string or container') end
      statement(s)
      return true
    end
    local c = text:sub(i, i)
    if s.quote then
      local closing = s.triple and string.rep(s.quote, 3) or s.quote
      if text:sub(i, i + #closing - 1) == closing then
        table.insert(s.tokens, { kind = 'string', value = table.concat(s.string), line = s.stringLine })
        s.quote = nil
        s.index = i + #closing
      elseif c == '\\' and s.quote == '"' then
        local e = text:sub(i + 1, i + 1)
        local escapes = { b = '\b', t = '\t', n = '\n', f = '\f', r = '\r', ['"'] = '"', ['\\'] = '\\' }
        if e == 'u' or e == 'U' then
          local n = e == 'u' and 4 or 8
          local hex = text:sub(i + 2, i + 1 + n)
          if #hex ~= n or not hex:match('^%x+$') then error('Invalid Unicode escape') end
          local cp = tonumber(hex, 16)
          if cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff) then error('Invalid Unicode codepoint') end
          table.insert(s.string, utf8.char(cp))
          s.index = i + n + 2
        elseif s.triple and e:match('%s') then
          local whitespace = text:match('^%s+', i + 1)
          local _, count = whitespace:gsub('\n', '')
          s.line = s.line + count
          s.index = i + 1 + #whitespace
        else
          if not escapes[e] then error('Invalid TOML escape') end
          table.insert(s.string, escapes[e])
          s.index = i + 2
        end
      else
        -- Consume a whole plain string run per step, stopping at quote/escape.
        local ending = i
        while ending <= #text do
          local ch = text:sub(ending, ending)
          if ch == s.quote or (ch == '\\' and s.quote == '"') then break end
          ending = ending + 1
          if ending - i >= 256 then break end
        end
        if ending == i then ending = i + 1 end
        local run = text:sub(i, ending - 1)
        local _, count = run:gsub('\n', '')
        if count > 0 and not s.triple then error('Newline in single-line TOML string') end
        s.line = s.line + count
        table.insert(s.string, run)
        s.index = ending
      end
    elseif c == '"' or c == "'" then
      s.quote, s.string, s.stringLine = c, {}, s.line
      s.triple = text:sub(i, i + 2) == string.rep(c, 3)
      s.index = i + (s.triple and 3 or 1)
      if s.triple and text:sub(s.index, s.index) == '\n' then
        s.index, s.line = s.index + 1, s.line + 1
      end
    elseif c == '#' then
      local ending = text:find('\n', i, true) or (#text + 1)
      local comment = trim(text:sub(i + 1, ending - 1))
      if #s.tokens > 0 and s.depth == 0 then s.comment = comment end
      if #s.tokens == 0 then
        local heading = comment:match('^[Cc]ategory:%s*(.+)$')
        if heading then s.category = heading end
      end
      s.index = ending
    elseif c == '\n' then
      if s.depth == 0 then statement(s) end
      s.line, s.index = s.line + 1, i + 1
    elseif c:match('%s') then
      s.index = i + 1
    elseif c:match('[%[%]{}=,.]') then
      table.insert(s.tokens, { kind = c, value = c, line = s.line })
      if c == '[' or c == '{' then s.depth = s.depth + 1 end
      if c == ']' or c == '}' then s.depth = s.depth - 1 end
      if s.depth < 0 then error('Unexpected TOML closing delimiter') end
      s.index = i + 1
    else
      local word = text:match('^[^%s%[%]{}=,.#\"\']+', i)
      if not word then error('Unexpected TOML character') end
      table.insert(s.tokens, { kind = 'word', value = word, line = s.line })
      s.index = i + #word
    end
  end
  return false
end

function M.parse(content, file)
  local s = M.new(content, file)
  while not M.step(s, 200) do end
  return s
end

local labels = {
  ['window-close'] = 'Close the focused window',
  ['window-toggle-floating'] = 'Toggle floating for the focused window',
  ['window-toggle-fullscreen'] = 'Toggle fullscreen',
  ['window-toggle-pinned'] = 'Pin or unpin the focused window',
  ['window-toggle-maximize'] = 'Maximize or restore the focused window',
  ['window-toggle-maximize-to-edges'] = 'Maximize the window to the screen edges',
  ['window-cycle-primary-extent'] = 'Cycle window size',
  ['window-cycle-primary-extent-back'] = 'Cycle window size backwards',
  ['overview-toggle'] = 'Show or hide the workspace overview',
  ['cheatsheet-toggle'] = 'Show or hide keyboard shortcuts',
  ['shortcuts-inhibit-toggle'] = 'Toggle keyboard shortcut passthrough',
  ['workspace-next'] = 'Switch to the next workspace',
  ['workspace-previous'] = 'Switch to the previous workspace',
  ['quit'] = 'Exit Umbriel',
  ['reload'] = 'Reload configuration',
}
function M.describe(action)
  if labels[action] then return labels[action] end
  local n = action:match('^workspace%-switch:(.+)$')
  if n then return 'Switch to workspace ' .. n end
  n = action:match('^window%-move%-to%-workspace:(.+)$')
  if n then return 'Move the window to workspace ' .. n end
  local direction = action:match('^window%-focus%-(%a+)$')
  if direction then return 'Focus the window ' .. (({left='on the left',right='on the right',up='above',down='below'})[direction] or direction) end
  direction = action:match('^window%-move%-(%a+)$')
  if direction then return 'Move the window ' .. direction end
  direction = action:match('^window%-focus%-or%-workspace%-(%a+)$')
  if direction then return 'Focus the window or workspace ' .. direction end
  direction = action:match('^window%-move%-or%-workspace%-(%a+)$')
  if direction then return 'Move the window within or between workspaces ' .. direction end
  local command = action:match('^spawn:(.+)$')
  if command then
    local ipc = command:match('^noctalia msg (.+)$')
    local commands = { ['volume-up']='Increase volume', ['volume-down']='Decrease volume',
      ['volume-mute']='Mute or unmute speakers', ['mic-mute']='Mute or unmute the microphone',
      ['brightness-up']='Increase brightness', ['brightness-down']='Decrease brightness',
      ['session lock']='Lock the screen', ['settings-open']='Open settings',
      ['panel-toggle launcher']='Open the application launcher',
      ['panel-toggle session']='Open the power menu', ['screenshot-region']='Capture a screen region',
      ['window-switcher hold']='Switch between windows' }
    if ipc and commands[ipc] then return commands[ipc] end
    local program = command:match('^([^%s]+)') or command
    program = program:match('([^/]+)$') or program
    local apps = { kitty='terminal', foot='terminal', firefox='Firefox', ['zen-browser']='Zen browser' }
    return 'Open ' .. (apps[program] or program)
  end
  return 'Run ' .. action:gsub('%-', ' '):gsub(':', ': ')
end

function M.binding(raw, modKey, normalizeModifiers)
  local chord = raw.chord
  local submap, rest = chord:match('^submap%[([^%]]+)%],%s*(.+)$')
  chord = rest or chord
  local parts = {}
  for part in chord:gmatch('[^+]+') do table.insert(parts, trim(part)) end
  local key = table.remove(parts) or ''
  -- A lone modifier is a release binding; keep its key visible.
  local function resolve(v) return v:lower() == 'mod' and (modKey or 'Super') or v end
  key = resolve(key)
  for i, part in ipairs(parts) do parts[i] = resolve(part) end
  local category = raw.category
  if category == '' then
    category = submap and ('Submap: ' .. submap) or
      (raw.action:match('^spawn:') and 'Applications' or
      (raw.action:find('workspace', 1, true) and 'Workspaces' or 'Window Management'))
  elseif submap then
    category = 'Submap: ' .. submap .. ' / ' .. category
  end
  return { compositor='umbriel', bindingType='bind', key=key,
    modifiers=normalizeModifiers(table.concat(parts, '+')), action=raw.action,
    description=raw.description ~= '' and raw.description or M.describe(raw.action),
    category=category, submap=submap or '', sourceFile=raw.sourceFile, sourceLine=raw.sourceLine }
end
return M
