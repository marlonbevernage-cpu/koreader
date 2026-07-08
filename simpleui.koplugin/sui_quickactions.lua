-- sui_quickactions.lua — Simple UI
-- Single source of truth for Quick Actions:
--   • Action Registry: built-in descriptors + external plugin registrations
--   • Storage: custom QA CRUD, default-action label/icon overrides
--   • Resolution: getEntry(id), isInPlace(id), execute(id, ctx)
--   • Menus: icon picker, rename dialog, create/edit/delete flows
--
-- CONSUMERS:
--   sui_bottombar      — QA.isInPlace(id), QA.execute(id, ctx)
--   module_quick_actions / module_action_list — QA.getEntry, QA.isBuiltin,
--                         QA.iterBuiltin, QA.getCustomQAValid
--   sui_menu           — QA.makeMenuItems, QA.makeIconsMenuItems
--
-- EXTERNAL PLUGIN API:
--   QA.register(descriptor)   — add an action to the registry
--   QA.unregister(id)         — remove an action (call on plugin unload)
--   QA.performResetAllQAIcons(plugin)
--   QA.sui_build_qa_icons(plugin, ctx_menu, ctx)
--
--   descriptor = {
--     id          = "myplugin_action",   -- unique, stable string
--     label       = _("My Action"),      -- base label (user can override)
--     icon        = "/path/to/icon.svg", -- base icon (user can override)
--     -- optional dynamic icon/label (called every render):
--     get_icon    = function(id) ... end,
--     get_label   = function(id) ... end,
--     -- execution:
--     is_in_place = true,  -- bool OR function(id)->bool
--     execute     = function(ctx) ... end,
--     -- ctx = { plugin, fm, show_unavailable }
--     -- optional metadata:
--     browsemeta_mode = nil,  -- "author"|"series"|"tags"
--   }

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan  = require("ui/widget/verticalspan")
local Device    = require("device")
local Screen    = Device.screen
local lfs       = require("libs/libkoreader-lfs")
local logger    = require("logger")
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext

local Config      = require("sui_config")
local SUISettings = require("sui_store")
local UI          = require("sui_core")

-- Landscape-aware scaling for the raw pixel/font sizes below that build
-- SUIWindow modal content directly in this file (icon picker previews, the
-- Quick Actions "Group" folder dialog, the Recent grid): every screen
-- builder here uses the ctx.SZ(n) handed to it by SUIWindow itself (single
-- source of truth, see sui_window.lua) instead of a locally-redeclared
-- wrapper. QA.buildQARowIcon is the one exception — it's a plain helper, not
-- a screen builder, so it takes its scale function as an explicit param
-- (falling back to UI.SZ if ever called without one). Not used by this
-- file's homescreen-facing helpers (those are scaled via sui_homescreen.lua's
-- own Config-patch mechanism instead).

local QA = {}

-- ---------------------------------------------------------------------------
-- Icon path guard — picker-time validation
-- ---------------------------------------------------------------------------
-- Called in every on_select callback that receives a filesystem path.
-- nil paths (user chose "Default") are always passed through unchanged.
-- Invalid paths show an InfoMessage and call on_invalid() so the caller
-- can reopen the picker or simply do nothing — the bad path is never saved.

local function _guardedSetIcon(path, on_valid, on_invalid)
    -- nil = "reset to default" — always valid, no file to check.
    if path == nil then
        on_valid(nil)
        return
    end
    if Config.isNerdIcon(path) then
        on_valid(path)
        return
    end
    local ok_ss, SUIStyle = pcall(require, "sui_style")
    local safe = ok_ss and SUIStyle and SUIStyle.safeIconPath(path, nil)
    if safe then
        on_valid(safe)
    else
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = _("Unsupported icon format.\nPlease use a PNG or SVG file."),
            timeout = 3,
        })
        if on_invalid then on_invalid() end
    end
end

-- ---------------------------------------------------------------------------
-- Icon directory
-- ---------------------------------------------------------------------------

local _icons_dir_cache
function QA.getIconsDir()
    if not _icons_dir_cache then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        if ok_ds and DataStorage then
            _icons_dir_cache = DataStorage:getSettingsDir() .. "/simpleui/sui_icons"
        else
            local _qa_plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
            _icons_dir_cache = _qa_plugin_dir .. "icons/custom"
        end
    end
    return _icons_dir_cache
end
setmetatable(QA, {
    __index = function(t, k)
        if k == "ICONS_DIR" then
            local dir = QA.getIconsDir()
            rawset(t, "ICONS_DIR", dir)
            return dir
        end
    end,
})

-- ---------------------------------------------------------------------------
-- Action Registry
-- Built-in descriptors are defined here and mirror Config.ALL_ACTIONS.
-- External plugins may call QA.register(descriptor) to add their own.
-- ---------------------------------------------------------------------------

-- The ordered list of built-in action descriptors.
-- Each entry is self-contained: it knows how to execute itself and whether
-- it is in-place, so sui_bottombar needs no action-specific knowledge.
local _builtin_descriptors = {}
local _registry = {}        -- id → descriptor (built-ins + externals)
local _registry_order = {}  -- ordered list of all registered ids

-- Lazy references — loaded on first use to avoid circular requires at boot.
local function _BM()
    return package.loaded["sui_browsemeta"] or require("sui_browsemeta")
end
local function _Bottombar()
    return package.loaded["sui_bottombar"] or require("sui_bottombar")
end

-- showUnavailable helper used inside execute closures.
local function _unavailToast(msg)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
end

-- Helper: resolve the live FileManager instance.
local function _liveFM()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance
end

-- Helper: resolve the live SimpleUIPlugin instance. Tries the given fm first
-- (set as fm._simpleui_plugin during plugin init), then the live FM, then
-- ReaderUI (where the plugin is registered as readerui.simpleui).
local function _resolveSimpleUIPlugin(fm)
    if fm and fm._simpleui_plugin then return fm._simpleui_plugin end
    local live_fm = _liveFM()
    if live_fm and live_fm._simpleui_plugin then return live_fm._simpleui_plugin end
    local RUI = package.loaded["apps/reader/readerui"]
    local rui = RUI and RUI.instance
    return rui and rui.simpleui
end

-- _goHome: replicates FileChooser:goHome() used in navigate().
-- Extracted here so the "home" execute closure is self-contained.
local function _goHome(target_fm)
    local fc = target_fm and target_fm.file_chooser
    if not fc then return false end
    local home = G_reader_settings:readSetting("home_dir")
    if not home or lfs.attributes(home, "mode") ~= "directory" then
        home = Device.home_dir
    end
    if not home then return false end
    local ok_fc_mod, FC_mod = pcall(require, "sui_foldercovers")
    local in_virtual = ok_fc_mod and FC_mod.isInSeriesView and FC_mod.isInSeriesView(fc)
    if in_virtual then FC_mod.exitSeriesView(fc) end
    if fc.path == home and not in_virtual then
        target_fm._navbar_suppress_path_change = true
        pcall(function() fc:onGotoPage(1) end)
        target_fm._navbar_suppress_path_change = nil
    else
        -- Set _sui_show_folder_pending before changeToPath: the FileChooser
        -- teardown that changeToPath triggers internally is seen by
        -- patchUIManagerClose as a fullscreen-widget close, which would
        -- schedule a spurious _doShowHS. The flag tells _doShowHS to abort.
        target_fm._sui_show_folder_pending = true
        target_fm._navbar_suppress_path_change = true
        fc:changeToPath(home)
        target_fm._navbar_suppress_path_change = nil
        -- _doShowHS clears the flag; clear it here too in case it was
        -- never consumed (e.g. _doShowHS was skipped for another reason).
        target_fm._sui_show_folder_pending = nil
    end
    if target_fm.updateTitleBarPath then
        pcall(function() target_fm:updateTitleBarPath(home, true) end)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Action implementations — self-contained, no bottombar dependency
-- ---------------------------------------------------------------------------

-- doWifiToggle: toggle Wi-Fi and immediately refresh all indicators with the
-- optimistic state before broadcastEvent clears it.
local function _doWifiToggle(plugin)
    local ok_hw, has_wifi = pcall(function() return Device:hasWifiToggle() end)
    if not (ok_hw and has_wifi) then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("WiFi not available on this device."), timeout = 2 })
        return
    end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Network manager unavailable."), timeout = 2 })
        return
    end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if not ok_state then wifi_on = false end
    if wifi_on then
        Config.wifi_optimistic = false
        pcall(function() NetworkMgr:turnOffWifi() end)
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Wi-Fi off"), timeout = 1 })
    else
        Config.wifi_optimistic = true
        local ok_on, err = pcall(function() NetworkMgr:turnOnWifi() end)
        if not ok_on then
            logger.warn("simpleui: Wi-Fi turn-on error:", tostring(err))
            Config.wifi_optimistic = nil
        end
    end
    -- Refresh all indicators with the optimistic state BEFORE broadcastEvent,
    -- which triggers onNetworkConnected/Disconnected and clears wifi_optimistic.
    if plugin then
        -- 1. Bottom bar tabs.
        plugin:_rebuildAllNavbars()
        -- 2. Topbar wifi icon — synchronous so it fires before wifi_optimistic is nil.
        local ok_tb, Topbar = pcall(require, "sui_topbar")
        if ok_tb and Topbar then
            local cfg = Config.getTopbarConfig()
            if (cfg.side["wifi"] or "hidden") ~= "hidden" then
                pcall(function() Topbar.refresh(plugin) end)
            end
        end
        -- 3. Homescreen quick-action icons — baked into ImageWidgets, need a full rebuild.
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance then
            pcall(function() HS.refreshImmediate(false) end)
        end
    end
    -- Broadcast network events so other KOReader listeners are notified.
    -- Set wifi_broadcast_self first so onNetworkConnected/Disconnected knows
    -- the optimistic state was already applied.
    Config.wifi_broadcast_self = true
    if wifi_on then
        pcall(function() UIManager:broadcastEvent(require("ui/event"):new("NetworkDisconnected")) end)
    else
        pcall(function() UIManager:broadcastEvent(require("ui/event"):new("NetworkConnected")) end)
    end
    Config.wifi_broadcast_self = nil
end

-- refreshWifiIcon: called by onNetworkConnected/Disconnected in main.lua.
-- Clears the optimistic flag (unless we set the broadcast ourselves) and
-- rebuilds all navbars + homescreen.
local function _refreshWifiIcon(plugin)
    if not Config.wifi_broadcast_self then
        Config.wifi_optimistic = nil
    end
    plugin:_rebuildAllNavbars()
    local HS = package.loaded["sui_homescreen"]
    if HS and HS.refreshImmediate then
        pcall(function() HS.refreshImmediate(false) end)
    end
end

-- ---------------------------------------------------------------------------
-- ... (rest of original file) ...

-- ---------------------------------------------------------------------------
-- Register KOReader plugins as quick-action descriptors so they appear in the
-- "Add Action" pool. This is defensive: if PluginLoader or plugin discovery is
-- unavailable it does nothing.
-- ---------------------------------------------------------------------------
local function _registerPluginActions()
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if not ok_pl or not PluginLoader then
        ok_pl, PluginLoader = pcall(require, "frontend/pluginloader")
    end
    if not ok_pl or not PluginLoader then return end

    local enabled, disabled = pcall(function() return PluginLoader:loadPlugins() end)
    if type(enabled) ~= "table" then return end

    for _, p in ipairs(enabled) do
        local pid = "plugin_" .. (p.name or p.path or "unknown")
        -- Avoid clobbering any existing ids.
        if _registry[pid] then goto continue end

        local label = p.fullname or p.name or p.path or pid
        local icon = Config.CUSTOM_PLUGIN_ICON or Config.ICON.plugin

        _registerDescriptor({
            id = pid,
            label = label,
            icon  = icon,
            is_in_place = false,
            execute = function(_ctx)
                -- Try to resolve a live plugin instance, prefer PluginLoader instances
                local instance = nil
                local ok_get, pl = pcall(function() return PluginLoader end)
                if ok_get and PluginLoader and type(PluginLoader.getPluginInstance) == "function" then
                    instance = PluginLoader:getPluginInstance(p.name)
                end
                -- Fallback: plugin may be registered on app modules (FM / ReaderUI)
                if not instance then
                    local FM = package.loaded["apps/filemanager/filemanager"]
                    local fm_inst = FM and FM.instance
                    instance = (fm_inst and fm_inst[p.name]) or (package.loaded[p.name] and package.loaded[p.name])
                end

                local function _unavail(msg)
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
                end

                if not instance then
                    _unavail(string.format(_("Plugin not available: %s"), tostring(p.name)))
                    return
                end

                -- If plugin exposes a normal method we can call it by convention:
                if type(instance._sui_launch) == "function" then
                    pcall(instance._sui_launch, instance)
                    return
                end

                -- Probe the plugin_menu to see if it exposes menu callback:
                local probe = {}
                local ok_probe = pcall(function() if type(instance.addToMainMenu) == "function" then instance:addToMainMenu(probe) end end)
                local entry = probe[p.name] or probe[instance.name]
                if entry and type(entry.callback) == "function" then
                    -- call callback defensively
                    local okcb, err = pcall(entry.callback)
                    if not okcb then _unavail(string.format(_("Plugin action failed: %s"), tostring(err))) end
                    return
                end

                -- Last resort: try any "show" method common convention (open a dialog)
                for _, mn in ipairs({ "show", "open", "start" }) do
                    if type(instance[mn]) == "function" then
                        local ok2, err2 = pcall(instance[mn], instance)
                        if not ok2 then
                            _unavail(string.format(_("Plugin method %s failed: %s"), mn, tostring(err2)))
                        end
                        return
                    end
                end

                _unavail(string.format(_("No callable entrypoint found for plugin: %s"), tostring(p.name)))
            end,
        })
        ::continue::
    end
end

-- Attempt a best-effort registration now.
pcall(_registerPluginActions)


return QA
