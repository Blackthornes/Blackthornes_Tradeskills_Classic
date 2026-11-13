-- Blackthornes Tradeskills -- Logic/PriceTransfer.lua
-- Export Prices and Import Prices: auction scan prices carried between two
-- computers or accounts by hand, as text.
--
-- A player asked how to merge scan data from another computer (2026-11-13,
-- the owner said build it). Copying the saved file over the other one throws
-- away everything else in it (recipes, queue, sales), so this is a code
-- instead. Nothing is ever replaced blindly:
--   * Only this realm and side's prices are in a code, and a code is refused
--     on any other (a faction's auction house prices differently).
--   * Only your own credible scans from the last PRUNE days go out: item,
--     market value, cheapest listing and when it was seen. Never the book's
--     own steps, your sales, settings or anything taken from others.
--   * Import takes a price only when it is newer than the one held, or when
--     there is none. The same code twice changes nothing.
--   * A record that is updated drops what described the old book (the rival
--     and own lowest, the ladder), since those are only true of the scan
--     they came from.
--   * The code is checked (a checksum) before anything changes, every field
--     is checked, and a code with too many records is refused.
--   * Long codes come in parts, each complete in itself.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local PriceTransfer = ns.NewModule("PriceTransfer")

-- Bump when the format changes so an old code is refused, not misread.
local FORMAT = "BTSP1"

-- Pipe is WoW's colour escape, so it is avoided entirely in the code.
local SECTION_SEP = "~"
local RECORD_SEP = ";"
local FIELD_SEP = ":"

PriceTransfer.PART_CHARS = 100000      -- about this much text a part
PriceTransfer.MAX_RECORDS = 60000      -- a code with more is refused
PriceTransfer.MAX_PARTS = 40
PriceTransfer.KEEP_DAYS = 21           -- older scans are not worth carrying

local function Comm() return ns.Comm end

local function Squash(text)
    return (tostring(text or ""):gsub("%s", ""))
end

local function RealmKey()
    return Squash(ns.Config:GetRealmKey())
end

--- The records a code would carry, as { { id, market, min, seen } } by item.
function PriceTransfer:Collect()
    local prices = ns.Prices:GetTable() or {}
    local oldest = time() - self.KEEP_DAYS * 86400
    local rows = {}

    for itemID, record in pairs(prices) do
        if type(itemID) == "number" and type(record) == "table"
            and type(record.market) == "number" and record.market > 0
            and ns.Prices.IsCredible(record.market)
            and type(record.seen) == "number" and record.seen >= oldest and record.seen <= time() + 86400 then
            local min = ns.Prices.IsCredible(record.min) and record.min or nil
            rows[#rows + 1] = { itemID, math.floor(record.market), min and math.floor(min) or nil,
                                math.floor(record.seen) }
        end
    end

    table.sort(rows, function(a, b) return a[1] < b[1] end)
    return rows
end

--- A code, as a list of parts (one string each). Nil and why when there is
--- nothing to carry.
function PriceTransfer:Export()
    local rows = self:Collect()
    if #rows == 0 then return nil, L["no recent prices to export yet, scan the auction house first"] end

    local realm = RealmKey()
    local toBase = Comm().ToBase36
    local chunks, current, size = {}, {}, 0

    for _, row in ipairs(rows) do
        local text = toBase(row[1]) .. FIELD_SEP .. toBase(row[2]) .. FIELD_SEP
            .. (row[3] and toBase(row[3]) or "") .. FIELD_SEP .. toBase(row[4]) .. RECORD_SEP
        current[#current + 1] = text
        size = size + #text
        if size >= self.PART_CHARS then
            chunks[#chunks + 1] = table.concat(current)
            current, size = {}, 0
        end
    end
    if #current > 0 then chunks[#chunks + 1] = table.concat(current) end

    local parts = {}
    for index, body in ipairs(chunks) do
        parts[index] = table.concat({
            FORMAT, realm, index .. "/" .. #chunks, Comm().Hash(realm .. body), body,
        }, SECTION_SEP)
    end
    return parts, #rows
end

--- What an export holds, for saying so before it is copied: how many items.
function PriceTransfer:Describe()
    return #self:Collect()
end

--- Read and check one part without changing anything.
-- @return table { realm, index, total, rows } or nil and why
function PriceTransfer:Parse(code)
    code = Squash(code)
    if code == "" then return nil, L["nothing to import"] end

    local fields = {}
    for field in (code .. SECTION_SEP):gmatch("([^" .. SECTION_SEP .. "]*)" .. SECTION_SEP) do
        fields[#fields + 1] = field
    end
    if fields[1] ~= FORMAT or #fields ~= 5 then
        return nil, L["that does not look like a Blackthornes Tradeskills prices code"]
    end

    local realm, partText, checksum, body = fields[2], fields[3], fields[4], fields[5]
    local index, total = partText:match("^(%d+)/(%d+)$")
    index, total = tonumber(index), tonumber(total)
    if not index or not total or index < 1 or index > total or total > self.MAX_PARTS then
        return nil, L["that prices code is damaged, copy it again"]
    end
    if Comm().Hash(realm .. body) ~= checksum then
        return nil, L["that prices code is damaged, copy it again"]
    end
    if realm ~= RealmKey() then
        return nil, L["that prices code is from another realm or side"]
    end

    local fromBase = Comm().FromBase36
    local rows = {}
    for record in body:gmatch("[^" .. RECORD_SEP .. "]+") do
        local id, market, min, seen = record:match("^(%w+):(%w+):(%w*):(%w+)$")
        id, market, seen = fromBase(id or ""), fromBase(market or ""), fromBase(seen or "")
        min = (min and min ~= "") and fromBase(min) or nil

        -- One bad record means the code is not trusted at all.
        if not id or not market or not seen or id < 1 or market < 1
            or not ns.Prices.IsCredible(market) or not ns.Prices.IsCredible(min)
            or seen > time() + 86400 then
            return nil, L["that prices code is damaged, copy it again"]
        end
        rows[#rows + 1] = { id, market, min, seen }
        if #rows > self.MAX_RECORDS then
            return nil, L["that prices code is too big"]
        end
    end

    if #rows == 0 then return nil, L["nothing to import"] end
    return { realm = realm, index = index, total = total, rows = rows }
end

--- Take the newer prices from a code.
-- @return ok, message
function PriceTransfer:Import(code)
    local parsed, why = self:Parse(code)
    if not parsed then return false, why end

    local prices = ns.Prices:GetTable()
    local added, updated, kept = 0, 0, 0

    for _, row in ipairs(parsed.rows) do
        local itemID, market, min, seen = row[1], row[2], row[3], row[4]
        local record = prices[itemID]

        if type(record) ~= "table" then
            prices[itemID] = { market = market, min = min, seen = seen, scans = 1, history = {} }
            added = added + 1
            ns.Prices:Touch(itemID)
        elseif (tonumber(record.seen) or 0) < seen then
            record.market = market
            record.min = min
            record.seen = seen
            -- What described the old book is not true of this scan.
            record.rivalMin, record.ownMin, record.ignoredLow = nil, nil, nil
            record.ladder, record.ladderAt, record.quantity, record.odd = nil, nil, nil, nil
            record.scans = math.max(1, tonumber(record.scans) or 0)
            if type(record.history) ~= "table" then record.history = {} end
            updated = updated + 1
            ns.Prices:Touch(itemID)
        else
            kept = kept + 1
        end
    end

    if ns.UI and ns.UI.RefreshActiveTab then pcall(ns.UI.RefreshActiveTab, ns.UI) end

    local summary = L.Format("took %d new price(s) and %d newer price(s), kept %d you already had newer",
        added, updated, kept)
    if parsed.total > 1 then
        summary = summary .. " " .. L.Format("(part %d of %d)", parsed.index, parsed.total)
    end
    return true, summary
end
