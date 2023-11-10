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
  m.logger.d('newWindow ~= currentWindow', newWindow ~= currentWindow)
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

return m
