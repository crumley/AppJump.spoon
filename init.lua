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

-- Resolve the window a filter should jump to, in order of preference:
--   1. the app's own focused window, the one it would bring forward itself
--      (for a tabbed app: the tab you were last on);
--   2. the most recently focused exposed window we know about, per the cache;
--   3. any exposed window the filter allows.
-- Never a window the app does not currently expose (see exposedWindows).
--
-- The cache in m.windows exists because f:getWindows() is slow without an
-- active subscription; it orders candidates but no longer decides them.
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
-- app's focused window when the app no longer exposes it.
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

function m:jump(f)
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
      target:focus()
      traceAfterFocus('jump (back)', target)
    end
    return
  end

  m.previousWindow = currentWindow
  newWindow:focus()
  traceAfterFocus('jump', newWindow)
end

function m:summon(f)
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

return m
