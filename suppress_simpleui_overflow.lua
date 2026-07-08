-- suppress_simpleui_overflow.lua
-- Suppress the "Modules exceed the visible area" message from Simple UI homescreen
-- This patch intercepts and suppresses the info message when homescreen modules overflow
--
-- Installation:
--   1. Download this file
--   2. Place it in your KOReader patches directory:
--      - Linux/Most devices: ~/.config/koreader/patches/
--      - Kobo: /mnt/onboard/.kobo/koreader/patches/
--      - Kindle: /mnt/us/extensions/koreader/patches/
--      - PocketBook: /.adds/koreader/patches/
--   3. Restart KOReader
--
-- The patch works by intercepting UIManager.show() calls and silently dropping
-- any InfoMessage containing "Modules exceed the visible area" so you never see
-- it pop up. All homescreen modules continue to work normally.

local UIManager = require("ui/uimanager")
local original_show = UIManager.show

UIManager.show = function(um_self, widget, ...)
    -- Suppress InfoMessage with the specific overflow warning
    if widget and widget.text and type(widget.text) == "string" then
        if widget.text:find("Modules exceed the visible area") then
            -- Don't show this widget
            return
        end
    end
    
    return original_show(um_self, widget, ...)
end

return {}
