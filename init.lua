--- === AppJump ===
---
---

local logger = require("hs.logger")

local m = {}
m.__index = m

-- Metadata
m.name = "AppJump"
m.version = "0.1"
m.author = "crumley@gmail.com"
m.license = "MIT"
m.homepage = "https://github.com/Hammerspoon/Spoons"

m.logger = logger.new('AppJump', 'debug')
m.previousWindow = nil
m.originalWindowSpace = {}

-- Settings

function m:init()
  m.logger.d('init')
end

function m:jump(filter)
  local newWindow = filter:getWindows(filter.sortByFocused)[1]
  if newWindow == nil then
    m.logger.d('Filter had no windows to jump to', filter)
    return
  end

  local currentWindow = hs.window.focusedWindow()

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

function m:summon(filter)
  local currentWindow = hs.window.focusedWindow()
  local newWindow = filter:getWindows(filter.sortByFocused)[1]

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
  local currentSpaceId = hs.spaces.focusedSpace()
  local windowSpaces = hs.spaces.windowSpaces(newWindow)

  if hs.fnutils.contains(windowSpaces, currentSpaceId) then
    -- The window is on the current space, send it back home
    local originalSpaces = m.originalWindowSpace[newWindowId]
    if originalSpaces ~= nil then
      hs.spaces.moveWindowToSpace(newWindow, originalSpaces[1])
      m.originalWindowSpace[newWindowId] = nil
      if m.previousWindow then
        m.previousWindow:focus()
      end
      return
    end
  else
    -- Move the window to the current space
    m.originalWindowSpace[newWindowId] = windowSpaces
    hs.spaces.moveWindowToSpace(newWindow, currentSpaceId)
  end
  m.previousWindow = currentWindow
  newWindow:focus()
end

return m
