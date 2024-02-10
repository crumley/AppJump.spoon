--- === AppJump ===
---
---

local logger = require("hs.logger")
local fnutils = require("hs.fnutils")
local filter = require("hs.window.filter")
local window = require("hs.window")
local spaces = require("hs.spaces")

local m = {}
m.__index = m

-- Metadata
m.name = "AppJump"
m.version = "0.1"
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
  hs.timer.doAfter(0,
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

-- Use the local window cache to resolve the matched window. For some reason the existance of m.windowFilter:subscribe
-- to build a local cache, even if it isn't used below and f:getWindows(...) is used directly its much faster than
-- if no subscription exists.
function m:findWindow(f)
  for _, w in ipairs(m.windows) do
    if f:isWindowAllowed(w) then
      return w
    end
  end
  return nil
end

function m:jump(f)
  -- local newWindow = f:getWindows(filter.sortByFocusedLast)[1]
  local newWindow = m:findWindow(f)
  if newWindow == nil then
    m.logger.d('Filter had no windows to jump to', filter)
    return
  end

  local currentWindow = window.focusedWindow()

  m.logger.d('AppJump:Jump', newWindow)
  m.logger.d('Current', currentWindow)
  m.logger.d('Previous', m.previousWindow)
  m.logger.d('newWindow == currentWindow', newWindow == currentWindow)
  m.logger.d('----')

  if m.previousWindow ~= nil and newWindow == currentWindow then
    m.previousWindow:focus()
    m.previousWindow = currentWindow
    return
  end

  m.previousWindow = currentWindow
  newWindow:focus()
end

function m:summon(f)
  local currentWindow = window.focusedWindow()
  local newWindow = m:findWindow(f)
  -- local newWindow = f:getWindows(filter.sortByFocusedLast)[1]

  if newWindow == nil then
    m.logger.d('Filter had no windows to jump to', filter)
    return
  end

  m.logger.d('AppJump:summon', newWindow)
  m.logger.d('Current', currentWindow)
  m.logger.d('Previous', m.previousWindow)
  m.logger.d('newWindow == currentWindow', newWindow == currentWindow)
  m.logger.d('----')

  local newWindowId = newWindow:id()
  local currentSpaceId = spaces.focusedSpace()
  local windowSpaces = spaces.windowSpaces(newWindow)

  if fnutils.contains(windowSpaces, currentSpaceId) then
    -- The window is on the current space, send it back home
    local originalSpaces = m.originalWindowSpace[newWindowId]
    if originalSpaces ~= nil then
      spaces.moveWindowToSpace(newWindow, originalSpaces[1])
      m.originalWindowSpace[newWindowId] = nil
      if m.previousWindow then
        m.previousWindow:focus()
      end
      return
    end
  else
    -- Move the window to the current space
    m.originalWindowSpace[newWindowId] = windowSpaces
    spaces.moveWindowToSpace(newWindow, currentSpaceId)
  end

  m.previousWindow = currentWindow
  newWindow:focus()
end

return m
