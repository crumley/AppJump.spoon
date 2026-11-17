-- Plain Lua, no Hammerspoon or test framework required: lua tests/focus_settle.lua
local passed = 0
local function eq(actual, expected, message)
  assert(actual == expected, (message or 'unexpected value') .. ': expected ' ..
    tostring(expected) .. ', got ' .. tostring(actual))
end

local function setup()
  local s = { now = 0, timers = {}, taps = {}, active = { main = 1 }, focused = nil,
    moves = 0, windows = {}, apps = {} }
  local function contains(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
  end
  local modules = {}
  modules['hs.logger'] = { new = function() return {
    d = function() end, getLogLevel = function() return 3 end,
  } end }
  modules['hs.fnutils'] = { contains = contains }
  modules['hs.window.filter'] = {}
  modules['hs.window'] = {
    focusedWindow = function() return s.focused end,
    list = function()
      if s.listUnavailable then return nil end
      local out = {}
      for _, w in ipairs(s.windows) do
        if w.ident and not w.layerUnknown then
          table.insert(out, { kCGWindowNumber = w.ident, kCGWindowLayer = w.layer or 0 })
        end
      end
      return out
    end,
    orderedWindows = function()
      local out, order = {}, s.order or {}
      if not s.order then
        for i = #s.windows, 1, -1 do table.insert(order, s.windows[i]) end
      end
      for _, w in ipairs(order) do
        if w:isVisible() and (contains(w.spaces, s.active.main) or
            contains(w.spaces, s.active.second)) then table.insert(out, w) end
      end
      return out
    end,
  }
  modules['hs.application'] = {
    frontmostApplication = function() return s.focused and s.focused:application() end,
    find = function(name) return s.apps[name] end,
  }
  modules['hs.spaces'] = {
    windowSpaces = function(w)
      if w.spaceError then error('invalid window') end
      return w.spaces
    end,
    activeSpaces = function()
      local snapshot = {}
      for display, space in pairs(s.active) do snapshot[display] = space end
      return snapshot
    end,
    focusedSpace = function() return s.active.main end,
    spaceDisplay = function(id) return id < 10 and 'main' or 'second' end,
    moveWindowToSpace = function(w, id) s.moves = s.moves + 1; w.spaces = { id } end,
  }
  modules['hs.timer'] = {
    absoluteTime = function() return s.now * 1e9 end,
    doAfter = function(delay, callback)
      local t = { due = s.now + delay, callback = callback }
      function t:stop() self.stopped = true end
      table.insert(s.timers, t)
      return t
    end,
  }
  modules['hs.inspect'] = function() return '' end
  modules['hs.chooser'] = { new = function(callback)
    local c = { callback = callback }
    function c:choices(choices) self.rows = choices end
    function c:query() end
    function c:show() self.shown = true end
    return c
  end }
  modules['hs.eventtap'] = {
    isSecureInputEnabled = function() return s.secureInput or false end,
    event = { types = { keyDown = 'keyDown', leftMouseDown = 'leftMouseDown',
      rightMouseDown = 'rightMouseDown', otherMouseDown = 'otherMouseDown',
      scrollWheel = 'scrollWheel', gesture = 'gesture' } },
    new = function(types, callback)
      local tap = { types = types, callback = callback }
      function tap:start() self.running = true; return self end
      function tap:stop() self.running = false end
      function tap:isEnabled() return self.running and not s.tapDisabled end
      table.insert(s.taps, tap)
      return tap
    end,
  }
  for name, module in pairs(modules) do
    package.loaded[name] = module
  end
  s.m = dofile('init.lua')
  function s:advance(seconds)
    local untilTime = self.now + seconds
    while true do
      local nextTimer
      for _, t in ipairs(self.timers) do
        if not t.stopped and not t.fired and t.due <= untilTime and
          (not nextTimer or t.due < nextTimer.due) then nextTimer = t end
      end
      if not nextTimer then break end
      self.now = nextTimer.due
      nextTimer.fired = true
      nextTimer.callback()
    end
    self.now = untilTime
  end
  function s:input(kind)
    for _, tap in ipairs(self.taps) do
      if tap.running and contains(tap.types, kind) then eq(tap.callback(), false) end
    end
  end
  function s:window(id, space, name)
    local appName = name or ('App' .. id)
    local app = self.apps[appName]
    if not app then
      app = { name = function() return appName end, pid = function() return id end }
      function app:allWindows()
        local out = {}
        for _, w in ipairs(s.windows) do
          local active = contains(w.spaces or {}, s.active.main) or
            contains(w.spaces or {}, s.active.second)
          if w.app == self and w.exposed ~= false and active then table.insert(out, w) end
        end
        return out
      end
      function app:focusedWindow() return self.focused end
      self.apps[appName] = app
    end
    local w = { ident = id, spaces = space and { space } or {}, app = app,
      focuses = 0, raises = 0, visible = true, minimized = false }
    function w:id() return self.ident end
    function w:application() return self.app end
    function w:title() return appName end
    function w:isStandard() return self.standard ~= false end
    function w:screen()
      return { getUUID = function() return (self.spaces[1] or 1) < 10 and 'main' or 'second' end }
    end
    function w:isVisible() return self.visible end
    function w:isMinimized() return self.minimized end
    function w:focus()
      self.focuses = self.focuses + 1
      if self.onFocus then self:onFocus() end
      return self
    end
    function w:raise()
      self.raises = self.raises + 1
      if s.order then
        for i, candidate in ipairs(s.order) do
          if candidate == self then table.remove(s.order, i); break end
        end
        table.insert(s.order, 1, self)
      end
      return self
    end
    table.insert(self.windows, w)
    return w
  end
  function s:jumpTo(w)
    self.m.findWindow = function() return w, 'test' end
    self.m:jump({})
  end
  s.source = s:window(100, 1)
  s.focused = s.source
  s.target = s:window(200, 2)
  return s
end

local function test(name, run, expectedMoves)
  local s = setup()
  run(s)
  eq(s.moves, expectedMoves or 0, 'unexpected window move')
  passed = passed + 1
  print('ok ' .. passed .. ' - ' .. name)
end

test('wait for destination and exact target exposure, then repair focus once', function(s)
  s:jumpTo(s.target)
  s:advance(.3)
  eq(s.target.focuses, 1)
  s.active.main = 2
  s.target.exposed = false
  s:advance(.3)
  eq(s.target.raises, 0)
  s.target.exposed = true
  s.target.onFocus = function(w) s.focused = w end
  s:advance(.95)
  eq(s.target.focuses, 2)
  eq(s.target.raises, 1)
  eq(s.m.focusRequest, nil)
  s.focused = s.source -- later user navigation must not be stolen back
  s:advance(2)
  eq(s.focused, s.source)
  eq(s.target.focuses, 2)
end)

test('early AX focus on source is not success; delayed takeover is repaired', function(s)
  s.target.onFocus = function(w) s.focused = w end
  s:jumpTo(s.target)
  s:advance(.2)
  assert(s.m.focusRequest)
  eq(s.target.raises, 0)
  s.active.main = 2
  s:advance(.051) -- first ready sample must not stop the request
  assert(s.m.focusRequest)
  s.focused = s.source
  s:advance(.5)
  eq(s.target.raises, 1)
  eq(s.focused, s.target)
end)

test('normal successful focus needs no raise or extra focus', function(s)
  s.target.onFocus = function(w) s.active.main = 2; s.focused = w end
  s:jumpTo(s.target)
  s:advance(.95)
  eq(s.target.focuses, 1)
  eq(s.m.focusRequest, nil)
end)

test('ready but refused focus has bounded corrections', function(s)
  s.active.main = 2
  s:jumpTo(s.target)
  s:advance(3)
  eq(s.target.raises, 3)
  eq(s.target.focuses, 4)
  eq(s.m.focusRequest, nil)
end)

test('never arriving destination times out without extra focus', function(s)
  s:jumpTo(s.target)
  s:advance(3)
  eq(s.target.focuses, 1)
  eq(s.m.focusRequest, nil)
  eq(s.taps[1].running, false)
end)

for _, kind in ipairs({ 'keyDown', 'leftMouseDown', 'rightMouseDown', 'otherMouseDown', 'scrollWheel', 'gesture' }) do
  test('new user ' .. kind .. ' cancels without swallowing input', function(s)
    s:jumpTo(s.target)
    s:input(kind)
    s.active.main = 2
    s:advance(2)
    eq(s.target.focuses, 1)
    eq(s.m.focusRequest, nil)
  end)
end

test('Hyper key release and modifier changes do not cancel', function(s)
  s:jumpTo(s.target)
  s:input('keyUp'); s:input('flagsChanged')
  assert(s.m.focusRequest)
  s.active.main = 2
  s.target.onFocus = function(w) s.focused = w end
  s:advance(.95)
  eq(s.target.raises, 1)
end)

for _, mutate in ipairs({
  function(s) s.target.spaces = {} end, -- ordered-out Ghostty tab
  function(s) s.target.ident = nil end, -- destroyed window
  function(s) s.target.app = nil end, -- terminated app
  function(s) s.target.spaces = { 3 } end, -- externally moved
  function(s) s.target.spaceError = true end,
}) do
  test('target invalidation cancels before retry', function(s)
    s:jumpTo(s.target)
    mutate(s)
    s.active.main = 2
    s:advance(.2)
    eq(s.target.focuses, 1)
    eq(s.m.focusRequest, nil)
  end)
end

test('ordered-out tab is not focused even initially', function(s)
  s.target.spaces = {}
  s:jumpTo(s.target)
  s:advance(2)
  eq(s.target.focuses, 0)
end)

test('minimized target preserves one-shot restore', function(s)
  s.target.spaces = {}; s.target.minimized = true
  s.target.onFocus = function(w) w.minimized = false; w.spaces = { 2 }; s.active.main = 2 end
  s:jumpTo(s.target)
  s:advance(2)
  eq(s.target.focuses, 1)
  eq(s.target.raises, 0)
end)

test('a later jump supersedes old focus, even when filter has no match', function(s)
  s:jumpTo(s.target)
  s:jumpTo(nil)
  s.active.main = 2
  s:advance(2)
  eq(s.target.focuses, 1)
end)

test('a later summon cancels recovery even when no match', function(s)
  s:jumpTo(s.target)
  s.m.findWindow = function() return nil end
  s.m:summon({})
  s.active.main = 2
  s:advance(2)
  eq(s.target.focuses, 1)
end)

test('opening chooser cancels recovery even with no entries', function(s)
  s:jumpTo(s.target)
  s.m.frontmostAppWindows = function() return {} end
  s.m:chooseWindow()
  s.active.main = 2
  s:advance(2)
  eq(s.target.focuses, 1)
end)

test('bounce-back preserves original source and also settles', function(s)
  s.target.onFocus = function(w) s.focused = w; s.active.main = 2 end
  s:jumpTo(s.target)
  s:advance(.95)
  eq(s.m.previousWindow, s.source)
  s.source.onFocus = function(w)
    if w.raises > 0 then s.focused = w end
  end
  s:jumpTo(s.target)
  eq(s.m.previousWindow, s.target)
  s.active.main = 1
  s:advance(.95)
  eq(s.focused, s.source)
  eq(s.source.raises, 1)
end)

test('chooser selection uses settle and revalidates ordered-out rows', function(s)
  s.m.frontmostAppWindows = function() return { { window = s.target, spaces = { 2 } } } end
  s.m:chooseWindow()
  s.m.picker.callback({ id = 200 })
  s.active.main = 2
  s.target.onFocus = function(w) s.focused = w end
  s:advance(.95)
  eq(s.target.raises, 1)
  eq(s.m.previousWindow, s.source)
  s.target.spaces = {}
  s.m.picker.callback({ id = 200 })
  eq(s.target.focuses, 2)
end)

test('leaving destination cancels instead of switching back', function(s)
  s:jumpTo(s.target)
  s.active.main = 2
  s:advance(.051)
  s.active.main = 1
  s:advance(.1)
  eq(s.target.focuses, 1)
  eq(s.m.focusRequest, nil)
end)

test('a third space before arrival cancels instead of switching back', function(s)
  s:jumpTo(s.target)
  s.active.main = 3
  s:advance(.1)
  eq(s.target.focuses, 1)
  eq(s.m.focusRequest, nil)
end)

test('target display active space matters, not focusedSpace on another display', function(s)
  s.active.second = 10
  s.target.spaces = { 11 }
  s:jumpTo(s.target)
  s:advance(.1)
  eq(s.target.raises, 0)
  s.active.second = 11
  s.target.onFocus = function(w) s.focused = w end
  s:advance(.95)
  eq(s.target.raises, 1)
  eq(s.active.main, 1)
end)

test('sticky windows on multiple spaces are safe on any original space', function(s)
  s.target.spaces = { 1, 2, 3 }
  s.target.onFocus = function(w) s.focused = w end
  s:jumpTo(s.target)
  s:advance(.11)
  eq(s.target.focuses, 1)
  eq(s.m.focusRequest, nil)
end)

test('AX-focused target behind a standard window is raised', function(s)
  s.active.main = 2
  s.source.spaces = { 2 }
  s.order = { s.source, s.target }
  s.focused = s.target
  s:jumpTo(s.target)
  s:advance(.55)
  eq(s.target.raises, 1)
  eq(s.order[1], s.target)
  eq(s.m.focusRequest, nil)
end)

test('floating panels and windows on another display do not block success', function(s)
  s.active.main = 2
  s.source.spaces = { 2 }; s.source.standard = false
  local otherDisplay = s:window(300, 10)
  s.active.second = 10
  s.order = { otherDisplay, s.source, s.target }
  s.target.onFocus = function(w) s.focused = w end
  s:jumpTo(s.target)
  s:advance(.11)
  eq(s.target.raises, 0)
  eq(s.m.focusRequest, nil)
end)

test('AXStandardWindow floating-layer Meet PiP does not block success', function(s)
  s.active.main = 2
  s.source.spaces = { 2 }; s.source.layer = 8
  s.order = { s.source, s.target }
  s.target.onFocus = function(w) s.focused = w end
  s:jumpTo(s.target)
  s:advance(.11)
  eq(s.target.raises, 0)
  eq(s.m.focusRequest, nil)
end)

test('an explicitly targeted floating window compares its own layer', function(s)
  s.active.main = 2
  s.source.spaces = { 2 }; s.target.layer = 8
  s.order = { s.source, s.target }
  s.target.onFocus = function(w) s.focused = w end
  s:jumpTo(s.target)
  s:advance(.11)
  eq(s.target.raises, 0)
  eq(s.m.focusRequest, nil)
end)

for _, removeData in ipairs({
  function(s) s.listUnavailable = true end,
  function(s) s.target.layerUnknown = true end,
  function(s) s.source.layerUnknown = true end,
}) do
  test('unknown stacking data does not trigger speculative raises', function(s)
    s.active.main = 2
    s.source.spaces = { 2 }; s.order = { s.source, s.target }
    s.target.onFocus = function(w) s.focused = w end
    removeData(s)
    s:jumpTo(s.target)
    s:advance(2)
    eq(s.target.raises, 0)
    eq(s.m.focusRequest, nil)
  end)
end

test('takeover after the first two ready samples is still repaired', function(s)
  s.target.onFocus = function(w) s.focused = w; s.active.main = 2 end
  s:jumpTo(s.target)
  s:advance(.25)
  assert(s.m.focusRequest, 'early focus must remain under observation during grace')
  s.source.spaces = { 2 }
  s.order = { s.source, s.target }
  s.focused = s.source
  s:advance(.7)
  eq(s.target.raises, 1)
  eq(s.focused, s.target)
  eq(s.m.focusRequest, nil)
end)

test('asynchronous takeover after a correction gets a spaced second repair', function(s)
  local corrections = {}
  s.target.onFocus = function(w)
    if w.raises > 0 then
      table.insert(corrections, s.now)
      s.focused = w
    end
  end
  s:jumpTo(s.target)
  s.active.main = 2
  s:advance(.55)
  eq(s.target.raises, 1)
  assert(s.m.focusRequest, 'focus return cannot complete recovery immediately')
  s.source.spaces = { 2 }; s.order = { s.source, s.target }; s.focused = s.source
  s:advance(.7)
  eq(s.target.raises, 2)
  assert(corrections[2] - corrections[1] >= .3)
  eq(s.focused, s.target)
  eq(s.m.focusRequest, nil)
end)

test('Secure Input before the jump uses one-shot focus only', function(s)
  s.secureInput = true
  s:jumpTo(s.target)
  s.active.main = 2
  s:advance(2)
  eq(s.target.focuses, 1)
  eq(s.m.focusRequest, nil)
end)

test('disabled event tap before the jump uses one-shot focus only', function(s)
  s.tapDisabled = true
  s:jumpTo(s.target)
  s.active.main = 2
  s:advance(2)
  eq(s.target.focuses, 1)
  eq(s.m.focusRequest, nil)
end)

for _, disable in ipairs({
  function(s) s.secureInput = true end,
  function(s) s.tapDisabled = true end,
}) do
  test('losing user input monitoring cancels all recovery', function(s)
    s:jumpTo(s.target)
    disable(s)
    s.active.main = 2
    s:advance(2)
    eq(s.target.focuses, 1)
    eq(s.m.focusRequest, nil)
  end)
end

test('stale queued timer and input callbacks cannot cancel a later jump', function(s)
  s:jumpTo(s.target)
  local staleTimer, staleInput = s.timers[1].callback, s.taps[1].callback
  local newer = s:window(300, 3)
  s:jumpTo(newer)
  local request = s.m.focusRequest
  staleTimer(); staleInput()
  eq(s.m.focusRequest, request)
  s.active.main = 3
  newer.onFocus = function(w) s.focused = w end
  s:advance(.95)
  eq(s.target.focuses, 1)
  eq(newer.raises, 1)
end)

test('summon preserves move/return behavior while canceling older recovery', function(s)
  s:jumpTo(s.target)
  s.m:summon({})
  eq(s.m.focusRequest, nil)
  eq(s.target.spaces[1], 1)
  eq(s.m.originalWindowSpace[200][1], 2)
  eq(s.m.previousWindow, s.source)
  s.m:summon({})
  eq(s.target.spaces[1], 2)
  eq(s.m.originalWindowSpace[200], nil)
  eq(s.source.focuses, 1)
  s:advance(2)
  eq(s.target.raises, 0)
end, 2)

test('bounce-back substitutes selected native tab for ordered-out previous tab', function(s)
  s.target.onFocus = function(w) s.focused = w; s.active.main = 2 end
  s:jumpTo(s.target)
  s:advance(.95)
  local selected = s:window(300, 1, 'App100')
  s.source.spaces = {}; s.source.app.focused = selected
  s:jumpTo(s.target)
  eq(s.source.focuses, 0)
  eq(selected.focuses, 1)
  selected.onFocus = function(w) s.focused = w end
  s.active.main = 1
  s:advance(.95)
  eq(s.focused, selected)
end)

test('real resolver skips ordered-out cached Ghostty tabs', function(s)
  s.target.spaces = {}; s.target.exposed = false
  local selected = s:window(300, 2, 'Ghostty')
  s.m.windows = { s.target, selected }
  local f = { getFilters = function() return { Ghostty = {} } end,
    isWindowAllowed = function(_, w) return w == s.target or w == selected end }
  local resolved = s.m:findWindow(f)
  eq(resolved, selected)
end)

print(string.format('%d tests passed', passed))
