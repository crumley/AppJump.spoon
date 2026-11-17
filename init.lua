--- === AppJump ===
---
--- Bind a hotkey per app: press it to bring that app's window forward, press
--- it again while there to bounce back to the window you came from.

local logger = require("hs.logger")
local fnutils = require("hs.fnutils")
local filter = require("hs.window.filter")
local window = require("hs.window")
local application = require("hs.application")
local spaces = require("hs.spaces")
local timer = require("hs.timer")
local inspect = require("hs.inspect")
local chooser = require("hs.chooser")
local eventtap = require("hs.eventtap")

local m = {}
m.__index = m

-- Metadata
m.name = "AppJump"
m.version = "0.2"
m.author = "crumley@gmail.com"
m.license = "MIT"
m.homepage = "https://github.com/Hammerspoon/Spoons"

m.logger = logger.new('AppJump', 'info')

m.previousWindow = nil
m.originalWindowSpace = {}
m.windows = {}

-- Settings

-- Optional: function(spaceId) -> string or nil, a label for the space a
-- window is on, shown under each row of the window picker. AppJump knows
-- nothing about space names; whoever loads it can wire one in.
m.spaceLabel = nil

function m:init()
  m.logger.d('init')

  m.windowFilter = filter.new()
  m.windowFilter:setDefaultFilter()
  m.windowFilter:setSortOrder(filter.sortByFocusedLast)

  -- Load windows in background so hammerspoon startup doesn't block
  timer.doAfter(0,
    function()
      for _, win in ipairs(m.windowFilter:getWindows()) do
        table.insert(m.windows, win)
      end
    end)

  local function addWindow(win, appName, event)
    table.insert(m.windows, 1, win)
  end

  local function removeWindow(win, appName, event)
    for i, w in ipairs(m.windows) do
      if w == win then
        table.remove(m.windows, i)
        return
      end
    end
  end

  m.windowFilter:subscribe(window.filter.windowCreated, addWindow)
  m.windowFilter:subscribe(window.filter.windowDestroyed, removeWindow)
  m.windowFilter:subscribe(window.filter.windowFocused, function(win, appName, event)
    removeWindow(win, appName, event)
    addWindow(win, appName, event)
  end)
end

-- Describe a window for the log: app, id, title, and the spaces it is on.
local function describe(win)
  if win == nil then
    return 'nil'
  end
  local app = win:application()
  local ok, winSpaces = pcall(spaces.windowSpaces, win)
  return string.format('%s#%s "%s" spaces=%s',
    app and app:name() or '?', tostring(win:id()), win:title() or '',
    ok and inspect(winSpaces) or '?')
end

local function debugging()
  return m.logger.getLogLevel() >= 4
end

-- The windows the filter's apps expose to accessibility right now, keyed by
-- id, plus each app's own focused window.
--
-- This matters for apps with native macOS tabs (Ghostty, Safari, Finder,
-- Terminal): only the selected tab of each tab group is an accessibility
-- window. A tab you switched away from is ordered out of the window server.
-- It still exists as an hs.window, hs.window:isVisible() is still true (the
-- app is not hidden, the window is not minimized), so a window filter still
-- allows it and the focus-ordered cache in m.windows still lists it. Focusing
-- it from another space makes AppKit order it back in on the *active* space,
-- and since a tab group lives on one space the whole group is dragged across
-- with it: the app "jumps" to your current space and lands on a different
-- tab. Restricting jumps to exposed windows removes that path entirely.
local function exposedWindows(f)
  local exposed, focused = {}, {}
  for appName, appFilter in pairs(f:getFilters()) do
    if appFilter and appName ~= 'default' and appName ~= 'override' then
      local apps = table.pack(application.find(appName, true))
      for i = 1, apps.n do
        local app = apps[i]
        if app then
          for _, w in ipairs(app:allWindows()) do
            local id = w:id()
            if id then
              exposed[id] = w
            end
          end
          local fw = app:focusedWindow()
          if fw and fw:id() then
            table.insert(focused, fw)
          end
        end
      end
    end
  end
  return exposed, focused
end

-- Whether a remembered window can be focused safely from any space: a window
-- the window server has ordered in sits on a space; the tabs a tabbed app has
-- switched away from (see exposedWindows) sit on none. A minimized window is
-- on none either, but focusing it just restores it.
local function focusable(win)
  local ok, winSpaces = pcall(spaces.windowSpaces, win)
  if ok and winSpaces and #winSpaces > 0 then
    return true, winSpaces
  end
  return win:isMinimized(), {}
end

-- Resolve the window a filter should jump to, in order of preference:
--   1. the app's own focused window, the one it would bring forward itself
--      (for a tabbed app: the tab you were last on);
--   2. the most recently focused window we know about, per the cache, that is
--      exposed or sits on a space (another space's windows are never exposed:
--      macOS lists only the current space's windows to accessibility);
--   3. any exposed window the filter allows.
-- Never an ordered-out tab (see exposedWindows and focusable).
--
-- The cache in m.windows exists because f:getWindows() is slow without an
-- active subscription. It is also the only way to know another space's
-- windows, so after a Hammerspoon reload a window there can be jumped to once
-- its space has been visited.
function m:findWindow(f)
  local exposed, focused = exposedWindows(f)

  for _, w in ipairs(focused) do
    if f:isWindowAllowed(w) then
      return w, 'app focused window'
    end
  end

  for _, cached in ipairs(m.windows) do
    local id = cached:id()
    local w = id and exposed[id]
    if w == nil and id and cached:isStandard() and focusable(cached) then
      w = cached
    end
    if w and f:isWindowAllowed(w) then
      return w, 'most recently focused'
    end
  end

  for _, w in pairs(exposed) do
    if f:isWindowAllowed(w) then
      return w, 'any exposed window'
    end
  end

  return nil
end

-- A remembered window may have become an ordered-out tab since we saw it
-- (the user switched tabs in that app without going through AppJump). Focus
-- it and its tab group gets dragged to the active space, so fall back to the
-- app's focused window when the app no longer exposes it and it sits on no
-- space (a window on another space is not exposed either, but is safe).
local function stillExposed(win)
  if win == nil then
    return nil
  end
  local app = win:application()
  if app == nil then
    return nil
  end
  for _, w in ipairs(app:allWindows()) do
    if w == win then
      return win
    end
  end
  if focusable(win) then
    return win
  end
  local fw = app:focusedWindow()
  if debugging() then
    m.logger.d(string.format('previous window %s is no longer exposed, using %s',
      describe(win), describe(fw)))
  end
  return fw
end

-- Log where a window ended up shortly after we focused it, so anything else
-- that moves it between spaces shows up next to our own trace.
local function traceAfterFocus(verb, win)
  if not debugging() then
    return
  end
  timer.doAfter(0.5, function()
    m.logger.d(string.format('%s settled: focused=%s, target now %s, focused space %s',
      verb, describe(window.focusedWindow()), describe(win), tostring(spaces.focusedSpace())))
  end)
end

-- A focus() return value is not an acknowledgement: it makes the window main
-- and activates its app, while a cross-Space transition is still asynchronous.
-- Repair only a verified, still-live target on its original desktop. In
-- particular, never refocus a tab that became ordered-out while waiting.
local function cancelFocus()
  local request = m.focusRequest
  m.focusRequest = nil
  if request then
    if request.timer then request.timer:stop() end
    if request.input then request.input:stop() end
  end
end

local function focusWithSettle(win, verb)
  cancelFocus()
  local safe, targetSpaces = focusable(win)
  local id = win:id()
  if not safe or not id then return end
  if eventtap.isSecureInputEnabled() then
    win:focus()
    traceAfterFocus(verb, win)
    return
  end

  local function clock() return timer.absoluteTime() / 1e9 end
  local request = {}
  m.focusRequest = request
  local deadline = clock() + 1.5
  local attempts, readySamples = 0, 0
  local readySince, lastAttempt
  local initialActive = spaces.activeSpaces() or {}
  local displays = {}
  for _, space in ipairs(targetSpaces) do
    local display = spaces.spaceDisplay(space)
    if display then displays[display] = true end
  end
  local arrived, crossSpace = false, true
  for display in pairs(displays) do
    if fnutils.contains(targetSpaces, initialActive[display]) then crossSpace = false end
  end

  local function onTop()
    local screen = win:screen()
    if not screen then return false end
    local uuid = screen:getUUID()
    local listed = window.list()
    if type(listed) ~= 'table' then return nil end
    local layers = {}
    for _, entry in ipairs(listed) do
      layers[entry.kCGWindowNumber] = entry.kCGWindowLayer
    end
    local targetLayer = layers[id]
    if targetLayer == nil then return nil end
    -- PiP can report AXStandardWindow yet live on a floating CG layer. Compare
    -- only our target's layer (normally 0); raising cannot beat floating layers.
    -- Unknown stacking data is not grounds for another raise.
    for _, candidate in ipairs(window.orderedWindows()) do
      local candidateScreen = candidate:screen()
      if candidate:isStandard() and candidate:isVisible() and candidateScreen and
          candidateScreen:getUUID() == uuid then
        local layer = layers[candidate:id()]
        if layer == nil then return nil end
        if layer == targetLayer then return candidate:id() == id end
      end
    end
    return nil
  end

  local types = eventtap.event.types
  -- Do not intercept input. In particular keyUp/flagsChanged (releasing the
  -- invoking Hyper chord) must not cancel the operation. Any *new* input wins.
  request.input = eventtap.new({ types.keyDown, types.leftMouseDown,
    types.rightMouseDown, types.otherMouseDown, types.scrollWheel, types.gesture }, function()
    if m.focusRequest == request then cancelFocus() end
    return false
  end):start()
  if not request.input:isEnabled() then
    cancelFocus()
    win:focus()
    traceAfterFocus(verb, win)
    return
  end

  local function poll()
    if m.focusRequest ~= request then return end
    request.timer = nil
    local function finish(reason)
      m.logger.d(verb .. ': focus settle ' .. reason)
      cancelFocus()
    end
    if clock() >= deadline then return finish('timed out') end
    if eventtap.isSecureInputEnabled() or not request.input:isEnabled() then
      return finish('input monitoring unavailable')
    end
    if win:id() ~= id or win:application() == nil then return finish('target closed') end
    local ok, nowSpaces = pcall(spaces.windowSpaces, win)
    -- An empty list may be a native tab that was ordered out; isVisible()
    -- alone cannot detect it. Even a minimized target gets no unsafe retry.
    if not ok or not nowSpaces or #nowSpaces == 0 then return finish('target has no space') end
    -- Minimized windows have no known destination before the initial focus.
    -- Preserve their one-shot restore, rather than guessing where to retry.
    if #targetSpaces == 0 then return finish('restore only') end
    for _, space in ipairs(nowSpaces) do
      if not fnutils.contains(targetSpaces, space) then return finish('target moved') end
    end

    local active = spaces.activeSpaces()
    local onTarget = false
    if active then
      for display in pairs(displays) do
        local current = active[display]
        if fnutils.contains(targetSpaces, current) then
          onTarget = true
        elseif current and (arrived or current ~= initialActive[display]) then
          return finish('user changed space')
        end
      end
    end
    arrived = arrived or onTarget
    local exposed = false
    if onTarget and win:isVisible() then
      for _, candidate in ipairs(win:application():allWindows()) do
        if candidate:id() == id then exposed = true; break end
      end
    end
    local focused = window.focusedWindow()
    readySamples = exposed and (readySamples + 1) or 0
    if exposed then
      readySince = readySince or clock()
    else
      readySince = nil
    end
    -- No public animation-completed signal exists. Allow a conservative .4s
    -- grace after cross-Space readiness (upstream focus has a .3s Finder-only
    -- workaround), and after a correction before declaring success. This is
    -- observation, not a delayed unconditional focus. Spread failed repairs
    -- out so they cannot all be spent during one transition.
    local now = clock()
    local grace = crossSpace and 0.4 or 0
    if readySamples >= 2 and now - readySince >= grace then
      local focusedTarget = focused and focused:id() == id
      local top = focusedTarget and onTop()
      if focusedTarget and top then
        if not lastAttempt or now - lastAttempt >= 0.4 then return finish('succeeded') end
      elseif (not focusedTarget or top == false) and
          (not lastAttempt or now - lastAttempt >= 0.3) then
        if attempts >= 3 then return finish('attempt limit') end
        attempts, lastAttempt = attempts + 1, now
        win:raise()
        win:focus()
      end
    end
    request.timer = timer.doAfter(0.05, poll)
  end

  win:focus() -- initiate normal app activation / Space switch exactly once
  traceAfterFocus(verb, win)
  request.timer = timer.doAfter(0.05, poll)
end

function m:jump(f)
  cancelFocus()
  local newWindow, how = m:findWindow(f)
  if newWindow == nil then
    m.logger.d('Filter had no windows to jump to', f)
    return
  end

  local currentWindow = window.focusedWindow()

  if debugging() then
    m.logger.d(string.format('jump: current=%s previous=%s -> new=%s (%s), focused space %s',
      describe(currentWindow), describe(m.previousWindow), describe(newWindow), how,
      tostring(spaces.focusedSpace())))
  end

  if m.previousWindow ~= nil and newWindow == currentWindow then
    m.logger.d('jump: already there, bouncing back to previous')
    local target = stillExposed(m.previousWindow)
    m.previousWindow = currentWindow
    if target then
      focusWithSettle(target, 'jump (back)')
    end
    return
  end

  m.previousWindow = currentWindow
  focusWithSettle(newWindow, 'jump')
end

function m:summon(f)
  cancelFocus()
  local currentWindow = window.focusedWindow()
  local newWindow, how = m:findWindow(f)

  if newWindow == nil then
    m.logger.d('Filter had no windows to summon', f)
    return
  end

  if debugging() then
    m.logger.d(string.format('summon: current=%s previous=%s -> new=%s (%s), focused space %s',
      describe(currentWindow), describe(m.previousWindow), describe(newWindow), how,
      tostring(spaces.focusedSpace())))
  end

  local newWindowId = newWindow:id()
  local currentSpaceId = spaces.focusedSpace()
  local windowSpaces = spaces.windowSpaces(newWindow)

  if fnutils.contains(windowSpaces, currentSpaceId) then
    -- The window is on the current space, send it back home
    local originalSpaces = m.originalWindowSpace[newWindowId]
    if originalSpaces ~= nil then
      m.logger.d('summon: sending window home to space', originalSpaces[1])
      spaces.moveWindowToSpace(newWindow, originalSpaces[1])
      m.originalWindowSpace[newWindowId] = nil
      local target = stillExposed(m.previousWindow)
      if target then
        target:focus()
      end
      return
    end
  else
    -- Move the window to the current space
    m.logger.d('summon: moving window to space', currentSpaceId)
    m.originalWindowSpace[newWindowId] = windowSpaces
    spaces.moveWindowToSpace(newWindow, currentSpaceId)
  end

  m.previousWindow = currentWindow
  newWindow:focus()
  traceAfterFocus('summon', newWindow)
end

-- Window picker ------------------------------------------------------------

-- The frontmost app's windows on every space, one per window (for a tabbed
-- app: its selected tab), most recently focused first, the window already
-- focused last -- so Return goes to the window you were in before.
--
-- Windows on other spaces are known only once AppJump has seen them: macOS
-- does not list another space's windows to accessibility, so after a
-- Hammerspoon reload a window shows up here once its space has been visited.
function m:frontmostAppWindows()
  local app = application.frontmostApplication()
  if app == nil then
    return {}
  end
  local pid = app:pid()
  local current = window.focusedWindow()
  local found, seen = {}, {}

  local function consider(win)
    local id = win and win:id()
    if id == nil or seen[id] then
      return
    end
    local winApp = win:application()
    if winApp == nil or winApp:pid() ~= pid or not win:isStandard() then
      return
    end
    local ok, winSpaces = focusable(win)
    if ok then
      seen[id] = true
      table.insert(found, { window = win, spaces = winSpaces })
    end
  end

  for _, win in ipairs(m.windows) do
    consider(win)
  end
  for _, win in ipairs(app:allWindows()) do
    consider(win)
  end

  if current then
    for i, entry in ipairs(found) do
      if entry.window:id() == current:id() then
        table.insert(found, table.remove(found, i))
        break
      end
    end
  end
  return found
end

-- Show a chooser of the frontmost app's windows across spaces; picking one
-- focuses it, switching to its space.
function m:chooseWindow()
  cancelFocus()
  local entries = m:frontmostAppWindows()
  if #entries == 0 then
    m.logger.d('chooseWindow: no windows for the frontmost app')
    return
  end

  local byId, choices = {}, {}
  for _, entry in ipairs(entries) do
    local win = entry.window
    local appName = win:application():name()
    local title = win:title()
    -- Every row is the same app: drop its name from the end of the title
    -- ("… - Google Chrome - Ryan" -> "…"), room the space label can use.
    local cut = title:find(' - ' .. appName, 1, true)
    if cut and cut > 1 then
      title = title:sub(1, cut - 1)
    end
    if title == '' then
      title = appName
    end
    local label
    if m.spaceLabel and entry.spaces[1] then
      local ok, result = pcall(m.spaceLabel, entry.spaces[1])
      label = ok and result or nil
    end
    -- The space is as much what tells windows apart as the title, so it leads
    -- the same line (and is searched with it) rather than sitting in the small
    -- print below. A window already named after its space (SpaceManager's
    -- Chrome names) shows its title alone.
    local text = title
    if label and title:sub(1, #label) ~= label then
      text = label .. ' · ' .. title
    end
    byId[win:id()] = win
    table.insert(choices, {
      text = text,
      subText = win:isMinimized() and 'minimized' or nil,
      id = win:id(),
    })
  end

  m.picker = m.picker or chooser.new(function(choice)
    cancelFocus()
    if choice == nil then
      return
    end
    local win = m.pickerWindows[choice.id]
    -- Re-check: a tab switch since the list was built must not drag a window
    -- across spaces.
    if win and focusable(win) then
      m.previousWindow = window.focusedWindow()
      focusWithSettle(win, 'choose')
    else
      m.logger.d('chooseWindow: window is no longer focusable', choice.id)
    end
  end)
  m.pickerWindows = byId
  m.picker:choices(choices)
  m.picker:query(nil)
  m.picker:show()
end

return m
