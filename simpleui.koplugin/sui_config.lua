-- sui_config.lua — Simple UI
-- sui_config.lua — Simple UI
-- Central configuration, state caching, and core helpers.

local G_reader_settings = G_reader_settings
local math_max          = math.max
local math_min          = math.min
local math_floor        = math.floor
local Blitbuffer        = require("ffi/blitbuffer")
local DataStorage       = require("datastorage")
local SUISettings       = require("sui_store")
local logger            = require("logger")
local _ = require("sui_i18n").translate

local M = {}

-- ===========================================================================
-- 1. Paths & Icons
-- ===========================================================================

-- Resolve absolute plugin directory for cross-platform compatibility.
local _plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
local _P  = _plugin_dir .. "icons/"
local _ko_root = ""
if DataStorage and type(DataStorage.getDataDir) == "function" then
    local _d = DataStorage.getDataDir():gsub("/$", "")
    local lfs_ok, lfs_m = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs_m then
        local function _is_root(dir)
            return lfs_m.attributes(dir .. "/resources/icons/mdlight", "mode") == "directory"
        end
        if _is_root(_d) then
            _ko_root = _d .. "/"
        else
            local parent = _d:match("^(.+)/[^/]+$")
            if parent and _is_root(parent) then
                _ko_root = parent .. "/"
            end
        end
    end
end
if _ko_root == "" then
    local lfs_ok, lfs_m = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs_m then
        local p = (_plugin_dir:gsub("/$", ""))
        for _i = 1, 8 do
            if lfs_m.attributes(p .. "/resources/icons/mdlight", "mode") == "directory" then
                _ko_root = p .. "/"
                break
            end
            local parent = p:match("^(.+)/[^/]+$")
            if not parent or parent == p then break end
            p = parent
        end
    end
end
local _KO = _ko_root .. "resources/icons/mdlight/"

-- Icon path registry.
M.ICON = {
    library        = _P .. "library.svg",
    collections    = _P .. "collections.svg",
    history        = _P .. "history.svg",
    recent         = _P .. "recent.svg",
    continue_      = _P .. "continue.svg",       -- trailing _ avoids clash with Lua keyword
    frontlight     = _P .. "frontlight.svg",
    night          = _P .. "night.svg",
    stats          = _P .. "stats.svg",
    power          = _P .. "power.svg",
    plus_alt       = _P .. "plus_alt.svg",
    custom         = _P .. "custom.svg",
    custom_dir     = _P .. "custom",
    group          = _P .. "group.svg",
    plugin         = _P .. "plugin.svg",
    author         = _P .. "author.svg",
    series         = _P .. "series.svg",
    tags           = _P .. "tags.svg",
    nav_prev       = _KO .. "chevron.left.svg",
    nav_next       = _KO .. "chevron.right.svg",
    ko_home        = _KO .. "home.svg",
    ko_star        = _KO .. "star.empty.svg",
    ko_wifi_on     = _KO .. "wifi.open.100.svg",
    ko_wifi_off    = _KO .. "wifi.open.0.svg",
    ko_menu        = _KO .. "appbar.menu.svg",
    ko_settings    = _KO .. "appbar.settings.svg",
    ko_search      = _KO .. "appbar.search.svg",
    ko_bookmark    = _KO .. "bookmark.svg",
}

M.CUSTOM_ICON            = M.ICON.custom
M.CUSTOM_PLUGIN_ICON     = M.ICON.plugin
M.CUSTOM_DISPATCHER_ICON = M.ICON.ko_settings
M.CUSTOM_GROUP_ICON      = M.ICON.group

-- ===========================================================================
-- 2. Core Constants & Action Registry
-- ===========================================================================

M.DEFAULT_NUM_TABS       = 5
M.MAX_TABS               = 6
M.MAX_TABS_NAVPAGER      = 4
M.MAX_LABEL_LEN          = 20
M.MAX_CUSTOM_QA          = 24
M.NAVPAGER_CENTER_TABS   = 4

M.DEFAULT_TABS = { "home", "sui_settings", "homescreen", "history", "power" }

M.NON_HOME_DEFAULTS = {}
for _i, id in ipairs(M.DEFAULT_TABS) do
    if id ~= "home" then M.NON_HOME_DEFAULTS[#M.NON_HOME_DEFAULTS + 1] = id end
end

-- Action catalogue.
M.ALL_ACTIONS = {
    { id = "home",             label = _("Library"),          icon = M.ICON.library     },
    { id = "homescreen",       label = _("Home"),             icon = M.ICON.ko_home     },
    { id = "collections",      label = _("Collections"),      icon = M.ICON.collections },
    { id = "history",          label = _("History"),          icon = M.ICON.history     },
    { id = "recent",           label = _("Recent"),           icon = M.ICON.recent      },
    { id = "continue",         label = _("Continue"),         icon = M.ICON.continue_   },
    { id = "favorites",        label = _("Favorites"),        icon = M.ICON.ko_star     },
    { id = "bookmark_browser", label = _("Bookmarks"),        icon = M.ICON.ko_bookmark },
    { id = "wifi_toggle",      label = _("Wi-Fi"),            icon = M.ICON.ko_wifi_on  },
    { id = "frontlight",       label = _("Brightness"),       icon = M.ICON.frontlight  },
    { id = "night_mode",       label = _("Night Mode"),       icon = M.ICON.night       },
    { id = "stats_calendar",   label = _("Stats"),            icon = M.ICON.stats       },
    { id = "power",            label = _("Power"),            icon = M.ICON.power       },
    { id = "sui_settings",     label = _("Settings"),         icon = M.ICON.ko_settings },
    { id = "browse_authors",   label = _("Authors"),          icon = M.ICON.author,
      browsemeta_mode = "author" },
    { id = "browse_series",    label = _("Series"),           icon = M.ICON.series,
      browsemeta_mode = "series" },
    { id = "browse_tags",      label = _("Tags"),             icon = M.ICON.tags,
      browsemeta_mode = "tags" },
}

M.ACTION_BY_ID = {}
for _i, a in ipairs(M.ALL_ACTIONS) do M.ACTION_BY_ID[a.id] = a end

-- Custom Quick Actions wrappers (delegates to sui_quickactions to avoid circular require).
local function _QA_lazy() return package.loaded["sui_quickactions"] or require("sui_quickactions") end
function M.getCustomQAList()         return _QA_lazy().getCustomQAList()                                                              end
function M.saveCustomQAList(list)    return _QA_lazy().saveCustomQAList(list)                                                         end
function M.getCustomQAConfig(id)     return _QA_lazy().getCustomQAConfig(id)                                                          end
function M.saveCustomQAConfig(id, label, path, coll, icon, pk, pm, da, is_folder) return _QA_lazy().saveCustomQAConfig(id, label, path, coll, icon, pk, pm, da, is_folder) end
function M.getQAFolderItems(id)      return _QA_lazy().getQAFolderItems(id)                                                            end
function M.saveQAFolderItems(id, items) return _QA_lazy().saveQAFolderItems(id, items)                                                 end
function M.deleteCustomQA(id)        return _QA_lazy().deleteCustomQA(id)                                                             end
function M.purgeQACollection(coll)   return _QA_lazy().purgeQACollection(coll)                                                        end
function M.renameQACollection(o, n)  return _QA_lazy().renameQACollection(o, n)                                                       end
function M.sanitizeQASlots()         return _QA_lazy().sanitizeQASlots()                                                              end
function M.nextCustomQAId()          return _QA_lazy().nextCustomQAId()                                                               end

-- ===========================================================================
-- 3. Topbar & Tab Configurations
-- ===========================================================================

M.TOPBAR_ITEMS = { "clock", "wifi", "brightness", "battery", "disk", "ram", "custom_text" }

local _topbar_item_labels = nil
function M.TOPBAR_ITEM_LABEL(k)
    if not _topbar_item_labels then
        _topbar_item_labels = {
            clock       = _("Clock"),
            wifi        = _("WiFi"),
            brightness  = _("Brightness"),
            battery     = _("Battery"),
            disk        = _("Disk Usage"),
            ram         = _("RAM Usage"),
            custom_text = _("Custom Text"),
        }
    end
    return _topbar_item_labels[k] or k
end

-- Custom text item for the topbar.
-- Stored as a plain string; empty string = item produces no output.
local TOPBAR_CUSTOM_TEXT_MAX = 32

M.TOPBAR_CUSTOM_TEXT_MAX = TOPBAR_CUSTOM_TEXT_MAX

function M.getTopbarCustomText()
    return SUISettings:get("simpleui_topbar_custom_text") or ""
end

function M.setTopbarCustomText(s)
    if type(s) == "string" then
        local count, i, out = 0, 1, {}
        while i <= #s do
            local byte = s:byte(i)
            local clen = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
            count = count + 1
            if count > TOPBAR_CUSTOM_TEXT_MAX then break end
            out[#out + 1] = s:sub(i, i + clen - 1)
            i = i + clen
        end
        s = table.concat(out)
    else
        s = ""
    end
    SUISettings:set("simpleui_topbar_custom_text", s)
end

function M.getTopbarConfig()
    local raw = SUISettings:get("simpleui_topbar_config")
    local cfg = { side = {}, order_left = {}, order_right = {}, order_center = {}, show = {}, order = {} }
    if type(raw) == "table" then
        if type(raw.side) == "table" then
            for k, v in pairs(raw.side) do cfg.side[k] = v end
        end
        if type(raw.order_left) == "table" then
            for _i, v in ipairs(raw.order_left) do cfg.order_left[#cfg.order_left + 1] = v end
        end
        if type(raw.order_right) == "table" then
            for _i, v in ipairs(raw.order_right) do cfg.order_right[#cfg.order_right + 1] = v end
        end
        if type(raw.order_center) == "table" then
            for _i, v in ipairs(raw.order_center) do cfg.order_center[#cfg.order_center + 1] = v end
        end
        if not next(cfg.side) and type(raw.show) == "table" then
            for k, v in pairs(raw.show) do
                cfg.side[k] = v and "right" or "hidden"
            end
            if type(raw.order) == "table" then
                for _i, v in ipairs(raw.order) do
                    if v ~= "clock" and cfg.side[v] == "right" then
                        cfg.order_right[#cfg.order_right + 1] = v
                    end
                end
            end
        end
    end
    if not next(cfg.side) then
        cfg.side        = { clock = "left", battery = "right", wifi = "right" }
        cfg.order_left  = { "clock" }
        cfg.order_right = { "wifi", "battery" }
    end
    if #cfg.order_left == 0 then
        for k, s in pairs(cfg.side) do
            if s == "left" and k ~= "clock" then cfg.order_left[#cfg.order_left + 1] = k end
        end
        if config.side["clock"] == "left" then
            table.insert(cfg.order_left, 1, "clock")
        end
    end
    if #cfg.order_right == 0 then
        for k, s in pairs(cfg.side) do
            if s == "right" then cfg.order_right[#cfg.order_right + 1] = k end
        end
    end
    if #cfg.order_center == 0 then
        for k, s in pairs(cfg.side) do
            if s == "center" then cfg.order_center[#cfg.order_center + 1] = k end
        end
    end
    return cfg
end

function M.saveTopbarConfig(cfg)
    SUISettings:set("simpleui_topbar_config", cfg)
    M.invalidateTopbarConfigCache()
    local tb = package.loaded["sui_topbar"]
    if tb and tb.invalidateConfigCache then tb.invalidateConfigCache() end
end