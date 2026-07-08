-- sui_quicksettings_bar.lua — Simple UI
-- Injects a Quick Settings panel tab into the KOReader touch menu,
-- identical in concept to the 2-quick-settings.lua userpatch but implemented
-- as a proper SimpleUI module.
--
-- PUBLIC API
--   QSBar.install(plugin)    — called from main.lua:onInit  (once per session)
--   QSBar.uninstall()        — called from main.lua:onTeardown
--   QSBar.makeMenuItems(ctx_menu) → KOReader item table for Bars → Quick Settings Bar
--
-- HOW IT WORKS
--   1. install() monkey-patches TouchMenu:updateItems and
--      TouchMenu:onTapCloseAllMenus so that when the panel tab is active the
--      normal item list is replaced by a row of action-button widgets.
--   2. A panel tab entry  { icon="...", remember=false, panel=<fn> }  is
--      inserted into tab_item_table by patching FileManagerMenu:setUpdateItemTable.
--   3. Action buttons are built from the user-configured slots stored under
--      "simpleui_qs_bar_slots".  Execution delegates to QA.execute().
--
-- SETTINGS KEY
--   "simpleui_qs_bar_slots"  → ordered array of action-id strings
--   "simpleui_qs_bar_enabled" → bool (default true)

local Device     = require("device")
local Screen     = Device.screen
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local UIManager  = require("ui/uimanager")
local logger     = require("logger")

local Blitbuffer        = require("ffi/blitbuffer")
local CenterContainer   = require("ui/widget/container/centercontainer")
local FrameContainer    = require("ui/widget/container/framecontainer")
local HorizontalGroup   = require("ui/widget/horizontalgroup")
local HorizontalSpan    = require("ui/widget/horizontalspan")
local ImageWidget       = require("ui/widget/imagewidget")
local LineWidget        = require("ui/widget/linewidget")
local TextWidget        = require("ui/widget/textwidget")
local VerticalGroup     = require("ui/widget/verticalgroup")
local VerticalSpan      = require("ui/widget/verticalspan")
local InputContainer    = require("ui/widget/container/inputcontainer")
local GestureRange      = require("ui/gesturerange")

local SUISettings = require("sui_store")
local _           = require("sui_i18n").translate
local N_          = require("sui_i18n").ngettext

-- Lazy references
local function _QA()
    return package.loaded["sui_quickactions"] or require("sui_quickactions")
end
local function _Config()
    return package.loaded["sui_config"] or require("sui_config")
end

local QSBar = {}
local _showQSBarSettingsWindow

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local SLOTS_KEY      = "simpleui_qs_bar_slots"
local ENABLED_KEY    = "simpleui_qs_bar_enabled"
local SHAPE_KEY      = "simpleui_qs_bar_shape"
local BG_KEY         = "simpleui_qs_bar_bg"
local FRONTLIGHT_KEY = "simpleui_qs_bar_frontlight"
local WARMTH_KEY     = "simpleui_qs_bar_warmth"
local LABELS_KEY     = "simpleui_qs_bar_labels"
local LABEL_SCALE_KEY= "simpleui_qs_bar_label_scale_pct"

-- Per-row capacity (buttons per row). Total capacity = rows * PER_ROW.
local PER_ROW = 10

local function getRowCount()
    local n = tonumber(SUISettings:readSetting("simpleui_qs_bar_rows"))
    if not n then return 1 end
    return math.max(1, math.min(10, math.floor(n)))
end

local function getMaxSlots()
    return getRowCount() * PER_ROW
end

local function getSlots()
    local raw = SUISettings:readSetting(SLOTS_KEY)
    return type(raw) == "table" and raw or {}
end

local function saveSlots(slots)
    SUISettings:saveSetting(SLOTS_KEY, slots)
end

local function isEnabled()
    return SUISettings:nilOrTrue(ENABLED_KEY)
end

local function getShape()
    return SUISettings:readSetting(SHAPE_KEY) or "rounded_square"
end

local function getBg()
    return SUISettings:readSetting(BG_KEY) or "solid"
end

local function showLabels()
    return SUISettings:nilOrTrue(LABELS_KEY)
end

local function getLabelScalePct()
    local n = tonumber(SUISettings:readSetting(LABEL_SCALE_KEY))
    if not n then return 100 end
    return math.max(50, math.min(200, math.floor(n)))
end

local function showFrontlight()
    return SUISettings:nilOrTrue(FRONTLIGHT_KEY)
end

local function showWarmth()
    return SUISettings:nilOrTrue(WARMTH_KEY)
end

-- ---------------------------------------------------------------------------
-- Label helper
-- ---------------------------------------------------------------------------

local function labelFor(id)
    local ok, entry = pcall(function() return _QA().getEntry(id) end)
    if ok and entry then return entry.label end
    return id
end

-- ---------------------------------------------------------------------------
-- Panel widget builder
-- Returns a VerticalGroup that fills the menu body, plus a refs table used
-- by the gesture handler to dispatch taps.
-- touch_menu is the live TouchMenu instance (for width / show_parent).
-- ---------------------------------------------------------------------------

local function buildPanel(touch_menu)
    local slots    = getSlots()
    local panel_w  = touch_menu.item_width
    local padding  = Screen:scaleBySize(28)
    local inner_w  = panel_w - padding * 2

    -- refs: { widget, callback } entries for action buttons +
    --       fl_progress / fl_state / setBrightness for the frontlight bar.
    local refs = { buttons = {} }

    -- ── Action-button row ────────────────────────────────────────────────────
    local btn_size  = Screen:scaleBySize(60)
    local icon_size = math.floor(btn_size * 0.52)
    local ok_style, SUIStyle = pcall(require, "sui_style")
    local lbl_fs    = math.max(6, math.floor((ok_style and SUIStyle.FS_DETAIL or 15) * (getLabelScalePct() / 100)))
    local lbl_face  = Font:getFace(ok_style and SUIStyle.FACE_REGULAR or "cfont", lbl_fs)
    local border_sz = ok_style and SUIStyle.BORDER_SZ or 1

    local function makeButton(action_id)
        local QA    = _QA()
        local entry = QA.getEntry(action_id)
        local label = entry.label or action_id

        local icon_widget
        local Config = _Config()
        local is_nerd = Config.isNerdIcon(entry.icon)
        local ok_style, SUIStyle = pcall(require, "sui_style")
        
        if is_nerd then
            local nerd_char = Config.nerdIconChar(entry.icon)
            icon_widget = TextWidget:new{
                text    = nerd_char,
                face    = Font:getFace(ok_style and SUIStyle.FACE_ICONS or "symbols", math.floor(icon_size * 0.75)),
                fgcolor = Blitbuffer.COLOR_BLACK,
                padding = 0,
            }
        else
            local icon_path = ok_style and SUIStyle and entry.icon
                and SUIStyle.safeIconPath and SUIStyle.safeIconPath(entry.icon, nil)
            if icon_path then
                local iw = ImageWidget:new{
                    file    = icon_path,
                    width   = icon_size,
                    height  = icon_size,
                    is_icon = true,
                    alpha   = true,
                }
                local ok_render = pcall(function() iw:_render() end)
                if ok_render then
                    icon_widget = iw
                else
                    iw:free()
                end
            end
            if not icon_widget then
                icon_widget = TextWidget:new{
                    text    = (label:sub(1, 1)):upper(),
                    face    = Font:getFace("cfont", math.floor(icon_size * 0.55)),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            end
        end

        local shape = getShape()
        local bg    = getBg()
        local is_bare = (shape == "bare")
        local corner_r = is_bare and 0 or ((shape == "round") and math.floor(btn_size / 2) or math.floor(btn_size / 4))
        local current_border = (not is_bare and (bg == "solid" or bg == "transparent")) and border_sz or 0

        local bg_color = nil
        if not is_bare then
            if bg == "flat" then bg_color = Blitbuffer.gray(0.08)
            elseif bg == "solid" then bg_color = Blitbuffer.COLOR_WHITE end
        end

        local btn_frame = FrameContainer:new{
            width      = btn_size,
            height     = btn_size,
            radius     = corner_r,
            bordersize = current_border,
            color      = current_border > 0 and Blitbuffer.gray(0.75) or nil,
            background = bg_color,
            padding    = 0,
            CenterContainer:new{
                dimen = Geom:new{
                    w = btn_size - current_border * 2,
                    h = btn_size - current_border * 2,
                },
                icon_widget,
            },
        }

        local vg = VerticalGroup:new{
            align = "center",
            btn_frame,
        }

        if showLabels() then
            local lbl_w = btn_size + Screen:scaleBySize(6)
            table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(2) })
            table.insert(vg, CenterContainer:new{
                dimen = Geom:new{ w = lbl_w, h = lbl_face.size },
                TextWidget:new{
                    text    = label,
                    face    = lbl_face,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    width   = lbl_w,
                },
            })
        end

        return vg, btn_frame
    end

    -- Build multiple rows: wrap slots every PER_ROW items across getRowCount() rows.
    local rows_container = VerticalGroup:new{ align = "center" }
    local total_slots = #slots
    if total_slots > 0 then
        local rows = getRowCount()
        for r = 1, rows do
            local row_start = (r - 1) * PER_ROW + 1
            local row_end = math.min(total_slots, r * PER_ROW)
            local n = math.max(0, row_end - row_start + 1)
            local row = HorizontalGroup:new{ align = "center" }
            if n > 0 then
                local gap = (n > 1)
                    and math.max(0, math.floor((inner_w - n * btn_size) / (n - 1)))
                    or 0
                for i = row_start, row_end do
                    local action_id = slots[i]
                    local vg, btn_frame = makeButton(action_id)
                    local _aid = action_id
                    table.insert(refs.buttons, {
                        widget = btn_frame,
                        callback = (function(aid)
                            return function()
                                local QA = _QA()
                                local is_in_place = QA.isInPlace(aid)
                                local stay_open = is_in_place
                                if aid:match("^custom_qa_%d+$") or aid == "sui_win_settings" then stay_open = false end

                                local FM  = package.loaded["apps/filemanager/filemanager"]
                                local fm  = FM and FM.instance
                                local plugin = fm and fm._simpleui_plugin

                                if not plugin then
                                    local ctx = { fm = fm }
                                    if not stay_open then
                                        UIManager:scheduleIn(0, function()
                                            local ok, err = pcall(QA.execute, aid, ctx)
                                            if not ok then logger.warn("simpleui QSBar: execute error", aid, tostring(err)) end
                                        end)
                                    else
                                        local ok, err = pcall(QA.execute, aid, ctx)
                                        if not ok then logger.warn("simpleui QSBar: execute error", aid, tostring(err)) end
                                        touch_menu:updateItems()
                                    end
                                    return stay_open
                                end

                                local RUI = package.loaded["apps/reader/readerui"]
                                local in_reader = RUI and RUI.instance
                                local plugin_resolved = plugin or (in_reader and in_reader.simpleui)

                                if stay_open then
                                    local ctx = { plugin = plugin_resolved, fm = fm }
                                    local ok, err = pcall(QA.execute, aid, ctx)
                                    if not ok then logger.warn("simpleui QSBar: execute error", aid, tostring(err)) end
                                    touch_menu:updateItems()
                                    return stay_open
                                end

                                UIManager:scheduleIn(0, function()
                                    local FM_live = package.loaded["apps/filemanager/filemanager"]
                                    local fm_live = FM_live and FM_live.instance
                                    local plugin_live = fm_live and fm_live._simpleui_plugin or plugin

                                    if in_reader and not is_in_place then
                                        if aid == "homescreen" then
                                            require("sui_patches").closeReaderToHomescreen(plugin_live)
                                        else
                                            local readerui = RUI.instance
                                            local file = readerui.document and readerui.document.file
                                            plugin_live._closing_via_gesture = true
{