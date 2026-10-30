-- The searched item's price at the top of the auction house drawer
-- (UI/SearchedPrice.lua, a player asked 2026-10-30).
--
-- What must hold:
--   1. The item is the one the client names with the search's words, else
--      the result named that way, else the only item in the results.
--   2. Several items and no name match: no row.
--   3. Our own scans' lists for the same words keep the row; new words that
--      name nothing hide it; closing the auction house clears it.
--   4. The row says "Auction value" and the price, or "not scanned yet",
--      with the age when the price is old.

local function check(cond, message)
    if not cond then error(message, 2) end
end

local savedInstant = _G.GetItemInfoInstant
local known = { ["mithril bar"] = 3860 }
GetItemInfoInstant = function(name) return known[name] end

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.L = setmetatable({ Format = string.format }, { __index = function(_, key) return key end })
ns.Theme = {}
local prices = { [3860] = 12000, [2589] = 300 }
local stale = {}
ns.Prices = {
    GetValue = function(_, id) return prices[id] end,
    IsStale = function(_, id) return stale[id] end,
    GetAge = function() return 7200 end,
}
ns.Util = {
    GetItemName = function(id) return ({ [3860] = "Mithril Bar", [2589] = "Linen Cloth", [2592] = "Wool Cloth" })[id] end,
    FormatMoney = function(c) return tostring(c) .. "c" end,
    FormatAgeAgo = function() return "2 hours ago" end,
}

local chunk = assert(loadfile("UI/SearchedPrice.lua"))
chunk("Blackthornes_TS", ns)
local SP = ns.SearchedPrice

-- 1. By the client's name, by a result's name, by the only item.
check(SP.Resolve("Mithril Bar", {}) == 3860, "client name")
check(SP.Resolve("linen cloth", { { name = "Wool Cloth", itemID = 2592 }, { name = "Linen Cloth", itemID = 2589 } }) == 2589,
    "result name")
check(SP.Resolve("linen", { { name = "Linen Cloth", itemID = 2589 }, { name = "Linen Cloth", itemID = 2589 } }) == 2589,
    "only item")

-- 2. Several items, no match.
check(SP.Resolve("cloth", { { name = "Wool Cloth", itemID = 2592 }, { name = "Linen Cloth", itemID = 2589 } }) == nil,
    "several items give no row")
check(SP.Resolve("", {}) == nil and SP.Resolve(nil, {}) == nil, "no words, no row")

-- 3. Keep for the same words, hide for new ones, clear on close.
check(SP:Look("Mithril Bar", {}) == true and SP.current.itemID == 3860, "row shows")
check(SP:Look("mithril bar", { { name = "Wool Cloth", itemID = 2592 }, { name = "Linen Cloth", itemID = 2589 } }) == false
    and SP.current.itemID == 3860, "our scan's list keeps the row")
check(SP:Look("cloth", { { name = "Wool Cloth", itemID = 2592 }, { name = "Linen Cloth", itemID = 2589 } }) == true
    and SP.current == nil, "new words that name nothing hide it")
SP:Look("Mithril Bar", {})
check(SP:Clear() == true and SP.current == nil, "closing clears it")

-- 4. The words on the row.
SP:Look("Mithril Bar", {})
local texts = SP:Texts()
check(texts.name == "Mithril Bar" and texts.value == "12000c", "price shown")
stale[3860] = true
check(SP:Texts().value == "12000c  (2 hours ago)", "an old price shows its age")
prices[3860] = nil
check(SP:Texts().value == "not scanned yet", "never scanned")

GetItemInfoInstant = savedInstant
print("test_searchedprice: ok")
