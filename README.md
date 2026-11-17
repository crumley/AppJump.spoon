# template.spoon

A template for a spoon project

# Installation

 - install [Hammerspoon](http://www.hammerspoon.org/) - a powerfull automation tool for OS X
   - Manually:

      Download the [latest release](https://github.com/Hammerspoon/hammerspoon/releases/latest), and drag Hammerspoon.app from your Downloads folder to Applications.
   - Homebrew:

      ```brew install hammerspoon --cask```

 - download [your.spoon](https://github.com/fork-my-spoons/your.spoon/releases/latest/download/your.spoon.zip), unzip and double click on a .spoon file. It will be installed under `~/.hammerspoon/Spoons` folder.
 
 - open ~/.hammerspoon/init.lua and add the following snippet, with your repositories:

```lua
paste here
```

This app uses icons, to properly display them, install a [feather-font](https://github.com/AT-UI/feather-font) by [downloading](https://github.com/AT-UI/feather-font/raw/master/src/fonts/feather.ttf) this .ttf font and installing it.

## Cross-Space focus

Jump, bounce-back, and picker selections initiate normal window focus, then
briefly verify the result. Hammerspoon's `hs.window:focus()` makes a window main
and activates its app; its return value does not acknowledge a completed Space
switch, and it does not explicitly raise the window.

AppJump only repairs focus when the original target Space is active on its
display and the exact window is visible and exposed by its application's
`allWindows()`. Success also requires the target to be the topmost visible
standard window on its display and CG window layer (normally layer 0). Floating
PiP windows are ignored even if they report `AXStandardWindow`; an explicitly
targeted floating window is compared with its own layer. If stacking data is
unavailable, no speculative raise is made for an already-focused target. After two ready
observations, a target that is unfocused or behind is raised and refocused.

Cross-Space requests have a conservative 0.4-second readiness grace before
accepting success or correcting focus; corrections are at least 0.3 seconds
apart, with 0.4 seconds of observation after a correction before accepting
success. This accounts for delayed macOS focus takeover without blindly
refocusing an already-correct window. Upstream Hammerspoon has a 0.3-second
Finder-specific workaround for this race; the slightly longer grace is still
only a heuristic, not a guarantee of animation completion. Same-Space success
does not need the initial grace. Polling is every 50 ms, with at most three
corrections and a 1.5-second monotonic deadline. Jumps never move windows or
call `gotoSpace()`.

A later jump, summon, or opening the picker cancels pending recovery. New key
presses, mouse clicks, scrolls, and trackpad gestures also cancel it without
consuming the event; releasing the initiating key or Hyper modifiers does not.
Cancellation deliberately favors user navigation over completing a jump.
If macOS Secure Input is enabled or the input event tap cannot run, AppJump
falls back to one-shot focus; losing input monitoring during recovery cancels
it. Changes between observations remain inherently best-effort.

Each retry revalidates the window ID and original Space membership. A closed,
moved, or ordered-out native tab is never retried. Minimized windows without a
known destination retain one-shot restoration rather than guessing a Space.
Summon keeps its existing move/return behavior and only cancels older recovery.

### Tests

Run deterministic timer/window/Space/input fakes with plain Lua (5.3+):

```sh
lua tests/focus_settle.lua
luac -p init.lua tests/focus_settle.lua
```

These tests do not automate macOS or prove its animation timing. Validate on a
live installation separately, including cross-Space Chrome/Ghostty jumps,
bounce-back, picker selection, and switching native Ghostty tabs mid-jump.
