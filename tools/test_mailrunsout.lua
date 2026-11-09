-- Mail running out: what the inbox says about mail that will soon be gone.
--
-- Two bugs motivate this file.
--
-- The first: an auction that expires comes back as mail, and until it is
-- collected the item is counted nowhere. It has dropped off your auctions and
-- it is not in your bags. So the Profit tab happily told you to craft more of
-- something already on its way home.
--
-- The second: nothing recorded whether a listing sold or came back. Owned
-- auctions are re-read from scratch each time, so both look identical -- the
-- listing is simply gone. The ledger here reads the mailbox and writes down
-- which it was.
--
-- The hard part of the ledger is identity. Mail has no id, indices shuffle as
-- mail is taken, and MAIL_INBOX_UPDATE fires repeatedly with a half-loaded
-- inbox. So it works by counting fingerprints rather than matching them, and
-- most of what follows is about that being right under re-reads, duplicates
-- and partial reads.

local ns = {}
ns.COLORS = setmetatable({}, {__index = function() return "ffffffff" end})
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() return true end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

local clock = 0
GetTime = function() return clock end
local function Tick() clock = clock + 10 end

time = time or os.time

--------------------------------------------------------------------------------
-- A client with a mailbox
--------------------------------------------------------------------------------

-- Each entry: { sender, subject, money, cod, items = { { itemID, count } },
--               invoice = { ... }, declared = n }
--
-- `declared` overrides the attachment count in the header, which is how a mail
-- whose attachments have not loaded yet is simulated: the header says two
-- items, the slots hand back nothing.
local inbox = {}

ATTACHMENTS_MAX_RECEIVE = 16

GetInboxNumItems = function() return #inbox end

GetInboxHeaderInfo = function(index)
    local mail = inbox[index]
    if not mail then return nil end

    local declared = mail.declared or #(mail.items or {})

    return nil, nil, mail.sender, mail.subject,
        mail.money or 0, mail.cod or 0, mail.days or 27.5, declared,
        false, mail.returned or false, false, mail.reply or false
end

-- The newer return shape: name, itemID, texture, count, quality, canUse.
GetInboxItem = function(index, slot)
    local mail = inbox[index]
    local item = mail and mail.items and mail.items[slot]
    if not item or item.unloaded then return nil end

    return "Some Item", item.itemID, 133633, item.count, 1, true
end

GetInboxItemLink = function(index, slot)
    local mail = inbox[index]
    local item = mail and mail.items and mail.items[slot]
    if not item or item.unloaded then return nil end

    return ("|cffffffff|Hitem:%d::::::::::|h[Some Item]|h|r"):format(item.itemID)
end

GetInboxInvoiceInfo = function(index)
    local mail = inbox[index]
    if not mail or not mail.invoice then return nil end

    local i = mail.invoice
    return i.invoiceType or "seller", i.itemName, i.buyer or "Someone",
        i.bid, i.buyout, i.deposit, i.cut, i.moneyDelay
end

-- The client's own subject formats, which is what the classifier matches
-- against rather than hardcoded English.
AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"

local LINEN_BAG, CLOTH, VIAL = 4238, 2589, 3371

local itemNames = {
    [LINEN_BAG] = "Linen Bag",
    [CLOTH] = "Linen Cloth",
    [VIAL] = "Crystal Vial",
}

C_Item = {
    GetItemCount = function() return 0 end,
    GetItemInfo = function(itemID) return itemNames[itemID] end,
}

C_Container = {
    GetContainerNumSlots = function() return 0 end,
    GetContainerItemInfo = function() return nil end,
}

C_Timer = {
    After = function() end,
    NewTimer = function() return { Cancel = function() end } end,
}

CreateFrame = function()
    local frame = {}
    for _, name in ipairs({ "SetScript", "Show", "Hide", "SetPoint", "SetSize" }) do
        frame[name] = function() end
    end
    return frame
end

GetInventoryItemID = function() return nil end

--------------------------------------------------------------------------------
-- The addon around it
--------------------------------------------------------------------------------

local characterRecord = { recipes = {}, inventory = {} }
local settings = { countMailAsStock = true, stockPenalty = 1 }

ns.db = { mailLedger = {} }

ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetRealmKey = function() return "Testrealm-Alliance" end,
    GetCharacterKey = function() return "Tester-Testrealm" end,
}

ns.Recipes = {
    GetCharacterRecord = function(_, create)
        if create then return characterRecord end
        return characterRecord
    end,
    GetAll = function() return {} end,
    GetAccountWide = function()
        return { [1] = { outputItemID = LINEN_BAG }, [2] = { outputItemID = VIAL } }
    end,
}

ns.Queue = { GetAll = function() return {} end }

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Inventory.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Mail.lua"))("Blackthornes_TS", ns)

local Inventory, Mail = ns.Inventory, ns.Mail

-- Inventory and Auctions lean on each other; Auctions is not under test here.
ns.Auctions = { GetPostedCount = function(_, itemID)
    return ({ [LINEN_BAG] = 3 })[itemID] or 0
end }

--------------------------------------------------------------------------------

local failures = 0

local function check(label, got, expected)
    local ok = got == expected
    if not ok then failures = failures + 1 end
    print(("  %-54s %-10s %s"):format(label, tostring(got), ok and "ok" or
        ("FAILED, expected " .. tostring(expected))))
end


Mail.inboxUpdatedThisVisit = true

print("")
print("mail that runs out soon")

inbox = {
    { sender = "Bob Wither", subject = "Cloth", reply = true, days = 2.4,
      items = { { itemID = CLOTH, count = 5 } } },
    { sender = "Auction House", subject = "Auction expired: Linen Bag", days = 1.2,
      items = { { itemID = LINEN_BAG, count = 1 } } },
    { sender = "Bob Wither", subject = "Hi", reply = true, days = 0.8 },
    { sender = "Bob Wither", subject = "Back", reply = true, returned = true, days = 2.9,
      money = 100 },
    { sender = "Ana Stone", subject = "Gold", reply = true, days = 20, money = 500 },
}
Mail:Read()
local e = characterRecord.mailExpiry
check("saved after a read", type(e), "table")
check("every mail counted", e.count, 5)
check("soonest days left", e.soonest, 0.8)
check("four run out within 3 days", e.soon, 4)
check("a player's mail with items goes back", e.returns, 1)
check("auction, empty and returned mail are gone", e.gone, 3)

print("")
print("the game's own answer wins")
InboxItemCanDelete = function() return false end
Mail:Read()
check("every soon mail goes back", characterRecord.mailExpiry.returns, 4)
InboxItemCanDelete = function() error("no") end
Mail:Read()
check("an error falls back to the rule", characterRecord.mailExpiry.returns, 1)
InboxItemCanDelete = nil

print("")
print("an empty box")
inbox = {}
Mail:Read()
check("nothing soonest", characterRecord.mailExpiry.soonest, nil)
check("nothing soon", characterRecord.mailExpiry.soon, 0)

print("")
if failures > 0 then
    error(("%d check(s) failed"):format(failures), 0)
end
print("all mail running out checks passed")
