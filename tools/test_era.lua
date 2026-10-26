-- The Classic Era copy.
--
-- This repo is Tradeskills for WoW Classic Era. What Forever's client gave
-- (its own recipes, Data/ForeverRecipes.lua, and the vendor and trainer
-- spots seen there, Data/ForeverVendorSpots.lua) does not fit Era, so the
-- TOC leaves both out, and so do Forever's own features (Legacy perks,
-- Merchant's Favor, the Craftsman's Writs, sending data to Forever
-- characters). It must never point a tag at the Forever project on
-- CurseForge. Then every file the TOC lists has to load, and
-- the addon has to log in, with no sister addon loaded, since Era may have
-- none of them.
--
-- There is no shared client stand-in here, so this one is loose on
-- purpose: every file runs in its own sandbox, where anything the client
-- would give that the test does not name answers as an empty stand-in.
-- It proves the files load and the start-up runs without Forever's data,
-- not that each window works; the other suites check those.

local failures = 0
local function check(label, ok, detail)
    if ok then
        print("  ok    " .. label)
    else
        failures = failures + 1
        print(("  FAIL  era: %s  -> %s"):format(label, tostring(detail)))
    end
end

local handle = assert(io.open(lfs_cwd .. "/Blackthornes_TS.toc", "r"))
local toc = handle:read("*a")
handle:close()

local files = {}
for line in toc:gmatch("[^\r\n]+") do
    if not line:match("^#") and line:match("%.lua$") then
        files[#files + 1] = (line:gsub("\\", "/"):gsub("%s+$", ""))
    end
end

check("the TOC is not Forever's", not toc:find("## Interface: 16001", 1, true))
check("the TOC names Era's interface", toc:find("## Interface: 11509", 1, true) ~= nil)
check("the TOC never names Forever's CurseForge project",
    not toc:find("^## X%-Curse%-Project%-ID:%s*1710638") and not toc:find("\n## X%-Curse%-Project%-ID:%s*1710638"))
check("the TOC names the Tradeskills Classic CurseForge project",
    toc:find("\n## X%-Curse%-Project%-ID: 1763353%s") ~= nil)
check("the TOC leaves out Forever's recipes", not toc:find("ForeverRecipes.lua", 1, true))
check("the TOC leaves out Forever's vendor spots", not toc:find("ForeverVendorSpots.lua", 1, true))
check("the TOC keeps Classic's recipe book", toc:find("\nData\\RecipeBook.lua", 1, true) ~= nil)
check("the TOC keeps Classic's vendor spots", toc:find("\nData\\VendorSpots.lua", 1, true) ~= nil)
check("the TOC reads Era's profession windows", toc:find("\nData\\EraRecipes.lua", 1, true) ~= nil)
check("the TOC scans Era's auction house", toc:find("\nData\\LegacyScan.lua", 1, true) ~= nil)
check("the files stay in the repo", io.open(lfs_cwd .. "/Data/ForeverRecipes.lua") ~= nil
    and io.open(lfs_cwd .. "/Data/ForeverVendorSpots.lua") ~= nil)

-- Forever's own features (step 2): Legacy perks, Merchant's Favor and its
-- Waylaid Crates and the Craftsman's Writs. Out of the TOC, kept in the
-- repo. Sending data to Blackthornes is back, to the owner's Era characters.
local FOREVER_FEATURES = {
    "Data\\WaylaidCrates.lua", "Data\\CraftsmansWrits.lua", "Logic\\Legacy.lua",
    "Logic\\MerchantsFavor.lua", "Logic\\Writs.lua",
    "UI\\FavorsView.lua", "UI\\DealsFavor.lua", "UI\\DealsWrits.lua",
}
for _, path in ipairs(FOREVER_FEATURES) do
    check("the TOC leaves out " .. path, not toc:find(path, 1, true))
    check(path .. " stays in the repo", io.open(lfs_cwd .. "/" .. (path:gsub("\\", "/"))) ~= nil)
end

--------------------------------------------------------------------------------
-- A loose client: anything not named below is an empty stand-in whose
-- methods answer nothing, and whose fields are nil until set.
--------------------------------------------------------------------------------

local Stub, Frame
local stubMeta, held = {}, setmetatable({}, { __mode = "k" })
local function Numeric(name)
    return name == "Value" or name:match("Width$") or name:match("Height$") or name:match("Scale$")
        or name:match("Alpha$") or name:match("Size$") or name:match("Left$") or name:match("Right$")
        or name:match("Top$") or name:match("Bottom$") or name:match("Level$")
end
stubMeta.__index = function(self, key)
    if type(key) ~= "string" or not key:match("^[A-Z]") then
        return nil   -- a field the addon never set is nil
    end
    if key:match("^Create") or key:match("^Get.*Region") or key == "GetParent"
        or key:match("^Get.*Frame$") or key:match("^Get.*Texture$") or key:match("^Get.*Button$") then
        return function() return Frame() end
    end
    -- What a widget is told, it tells back: SetValue, then GetValue.
    local name = key:match("^Set(.+)")
    if name then
        return function(me, ...)
            held[me] = held[me] or {}
            held[me][name] = { ... }
        end
    end
    name = key:match("^Get(.+)")
    if name then
        return function(me)
            local kept = held[me] and held[me][name]
            if kept then return unpack(kept) end
            if Numeric(name) then return name == "Value" and 0 or 1 end
            return nil
        end
    end
    -- Any other method answers nothing.
    return function() return nil end
end
stubMeta.__call = function() return nil end
function Stub() return setmetatable({}, stubMeta) end

function Frame()
    local frame = Stub()
    rawset(frame, "scripts", {})
    rawset(frame, "events", {})
    rawset(frame, "SetScript", function(self, name, fn) self.scripts[name] = fn end)
    rawset(frame, "GetScript", function(self, name) return self.scripts[name] end)
    rawset(frame, "HookScript", function() end)
    rawset(frame, "RegisterEvent", function(self, event) self.events[event] = true end)
    rawset(frame, "UnregisterEvent", function(self, event) self.events[event] = nil end)
    rawset(frame, "IsShown", function() return false end)
    rawset(frame, "IsVisible", function() return false end)
    rawset(frame, "GetWidth", function() return 100 end)
    rawset(frame, "GetHeight", function() return 20 end)
    rawset(frame, "GetStringWidth", function() return 50 end)
    rawset(frame, "GetNumPoints", function() return 0 end)
    return frame
end

local frames = {}
local known = {
    CreateFrame = function(...)
        local frame = Frame()
        frames[#frames + 1] = frame
        return frame
    end,
    GetLocale = function() return "enUS" end,
    GetTime = function() return 1000 end,
    time = os.time,
    date = os.date,
    GetServerTime = function() return os.time() end,
    GetRealmName = function() return "Era Realm" end,
    GetNormalizedRealmName = function() return "EraRealm" end,
    UnitName = function() return "Ana Thorn" end,
    UnitFullName = function() return "Ana Thorn", "EraRealm" end,
    UnitGUID = function() return "Player-1-0000AAAA" end,
    UnitFactionGroup = function() return "Alliance", "Alliance" end,
    UnitClass = function() return "Mage", "MAGE", 8 end,
    UnitRace = function() return "Human", "Human", 1 end,
    UnitLevel = function() return 20 end,
    GetMoney = function() return 12345 end,
    GetCurrentRegion = function() return 1 end,
    GetCurrentRegionName = function() return "US" end,
    InCombatLockdown = function() return false end,
    IsInGuild = function() return false end,
    GetBuildInfo = function() return "1.15.7", "60000", "Oct 1 2026", 11507 end,
    issecretvalue = function() return false end,
    geterrorhandler = function() return function(err) error(err, 0) end end,
    hooksecurefunc = function() end,
    SlashCmdList = {},
    DEFAULT_CHAT_FRAME = { AddMessage = function() end },
    UIParent = Frame(),
    WorldFrame = Frame(),
    Minimap = Frame(),
    GameTooltip = Frame(),
    ItemRefTooltip = Frame(),
    C_Timer = { After = function() end, NewTimer = function() return Stub() end,
                NewTicker = function() return Stub() end },
    C_AddOns = {
        GetAddOnMetadata = function(_, field) if field == "Version" then return "@project-version@" end end,
        IsAddOnLoaded = function() return false end,
        DoesAddOnExist = function() return false end,
        GetAddOnInfo = function() return nil, nil, nil, false, "MISSING" end,
    },
    -- The client's own Lua helpers.
    tinsert = table.insert, tremove = table.remove, format = string.format,
    strfind = string.find, strmatch = string.match, strlower = string.lower,
    strupper = string.upper, strsub = string.sub, gsub = string.gsub, floor = math.floor,
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
    strtrim = function(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end,
    strsplit = function(sep, text)
        local out = {}
        for piece in (tostring(text) .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
        return unpack(out)
    end,
    Enum = {},
    NUM_BAG_SLOTS = 4,
    -- A new install: no saved variables yet.
    BlackthornesTSDB = false, BlackthornesTSCharDB = false,
    -- Era's auction house is the old one.
    C_AuctionHouse = false,
    -- No sister addon is loaded.
    BlackthornesFarmer = false, BlackthornesEquipment = false,
    BlackthornesButler = false, BlackthornesPets = false,
}

local env = setmetatable({}, { __index = function(self, key)
    local value = known[key]
    if value == false then return nil end
    if value ~= nil then return value end
    value = _G[key]
    if value ~= nil then return value end
    if type(key) == "string" and key:match("^[A-Z_]") then
        local stub = Stub()
        rawset(self, key, stub)
        return stub
    end
    return nil
end })
env._G = env

local ns = {}
local loaded, broken = 0, {}
for _, path in ipairs(files) do
    local chunk, err = loadfile(lfs_cwd .. "/" .. path)
    if not chunk then
        broken[#broken + 1] = path .. ": " .. tostring(err)
    else
        setfenv(chunk, env)
        local ok, why = pcall(chunk, "Blackthornes_TS", ns)
        if ok then loaded = loaded + 1 else broken[#broken + 1] = path .. ": " .. tostring(why) end
    end
end
for _, line in ipairs(broken) do print("  FAIL  " .. line) end
check("every file the TOC lists loads", #broken == 0 and loaded == #files, #broken .. " broken")

check("no Forever recipes in the book", (function()
    for _, row in pairs(ns.RECIPE_BOOK and ns.RECIPE_BOOK.RECIPES or {}) do
        if row.f == 1 then return false end
    end
    return ns.RECIPE_BOOK ~= nil
end)())
check("no Forever vendor spots", ns.FOREVER_VENDOR_SPOTS == nil)
check("no Forever trainer spots", ns.FOREVER_TRAINER_SPOTS == nil)
check("the TOC sends data to Blackthornes", toc:find("\nLogic\\Contribute.lua", 1, true) ~= nil)
check("only to the owner's Era characters", ns.Contribute ~= nil and (function()
    for _, name in ipairs(ns.Contribute.RECIPIENTS) do
        if name:find(" ", 1, true) or not name:find("-Ashkandi$") then return false end
    end
    return #ns.Contribute.RECIPIENTS > 0
end)())
for _, name in ipairs({ "Legacy", "MerchantsFavor", "Writs", "FavorsView",
    "DealsFavor", "DealsWrits", "WAYLAID_CRATES", "CRAFTSMANS_WRITS" }) do
    check("no " .. name, ns[name] == nil)
end
check("no Favors and Writs tab", ns.UI ~= nil and ns.UI.tabs ~= nil and ns.UI.tabs.characters ~= nil
    and ns.UI.tabs.deals == nil)

-- Log in, as the client would: the saved variables are empty on a new
-- install, then ADDON_LOADED and PLAYER_LOGIN.
local errors = {}
env.geterrorhandler = function() return function(err) errors[#errors + 1] = tostring(err) end end
local boot = ns.modules and ns.modules.Bootstrap
local ok, err = pcall(function()
    boot:ADDON_LOADED("ADDON_LOADED", "Blackthornes_TS")
    boot:PLAYER_LOGIN()
end)
for _, line in ipairs(errors) do print("  FAIL  " .. line) end
check("it loads and logs in", ok and #errors == 0, err or (#errors .. " module error(s)"))

-- What reads the left-out data still answers.
if ns.VendorPins then
    local fine, known_ = pcall(ns.VendorPins.Known, ns.VendorPins)
    check("vendor pins know no shipped vendors", fine and next(known_) == nil, known_)
    local fineT, trainers = pcall(ns.VendorPins.Known, ns.VendorPins, "trainer")
    check("and no shipped trainers", fineT and next(trainers) == nil, trainers)
end
if ns.RecipeBook and ns.RecipeBook.GetAll then
    local fine, all = pcall(ns.RecipeBook.GetAll, ns.RecipeBook)
    local any, forever = false, false
    if fine and type(all) == "table" then
        for _, record in pairs(all) do
            any = true
            if record.forever then forever = true end
        end
    end
    check("the recipe book is Classic's alone", fine and any and not forever, fine and "forever recipe found" or all)
end

assert(failures == 0, failures .. " era check(s) failed")
