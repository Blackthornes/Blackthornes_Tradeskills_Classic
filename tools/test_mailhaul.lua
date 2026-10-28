-- The report after a mailbox visit (2026-09-28: "better mail tracking
-- and reporting after mails are collected ... keep with the dopamine hits").
--
-- Logic/MailHaul.lua works out what was collected from the difference between
-- one reading of the inbox and the next, because mail has no id. What matters
-- here is that the report never claims gold you did not take, and never misses
-- gold you did: new mail arriving, a sale's gold being released, a letter
-- emptied in two goes, and an attachment still loading are all the cases where
-- a naive "what went missing" gets it wrong.

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() return true end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

local printed = {}
ns.Print = function(text) printed[#printed + 1] = tostring(text) end
ns.PrintRaw = function(text) printed[#printed + 1] = tostring(text) end

-- Other suites leave a GetMoney behind. These first checks are about what the
-- mail alone says, so the purse is taken away until the section that uses it.
GetMoney = nil

local now = 1790000000
time = function() return now end
date = os.date
GetTime = function() return now end

--------------------------------------------------------------------------------
-- A mailbox
--------------------------------------------------------------------------------

local inbox = {}

ATTACHMENTS_MAX_RECEIVE = 16

GetInboxNumItems = function() return #inbox end

GetInboxHeaderInfo = function(index)
    local mail = inbox[index]
    if not mail then return nil end
    local declared = mail.declared or #(mail.items or {})
    return nil, nil, mail.sender, mail.subject, mail.money or 0, 0, 27.5, declared
end

GetInboxItem = function(index, slot)
    local item = inbox[index] and inbox[index].items and inbox[index].items[slot]
    if not item or item.unloaded then return nil end
    return "Some Item", item.itemID, 133633, item.count, 1, true
end

GetInboxItemLink = function(index, slot)
    local item = inbox[index] and inbox[index].items and inbox[index].items[slot]
    if not item or item.unloaded then return nil end
    return ("|cffffffff|Hitem:%d::::::::::|h[Some Item]|h|r"):format(item.itemID)
end

GetInboxInvoiceInfo = function(index)
    local mail = inbox[index]
    if not mail or not mail.invoice then return nil end
    local i = mail.invoice
    return "seller", i.itemName, "Buyer", i.bid, i.bid, i.deposit or 0, i.cut or 0, 0
end

AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"
AUCTION_WON_MAIL_SUBJECT = "Auction won: %s"
AUCTION_OUTBID_MAIL_SUBJECT = "Outbid on %s"

local LINEN_BAG, CLOTH, VIAL, WOOL = 4238, 2589, 3371, 2592
local names = { [LINEN_BAG] = "Linen Bag", [CLOTH] = "Linen Cloth", [VIAL] = "Crystal Vial", [WOOL] = "Wool Cloth" }

-- Name, link and quality, as the game hands them back for a loaded item.
C_Item = { GetItemInfo = function(itemID) return names[itemID], nil, names[itemID] and 1 or nil end }
C_Timer = { After = function() end }

--------------------------------------------------------------------------------
-- A screen, for the report
--------------------------------------------------------------------------------

local frames = {}

local function Region()
    local region = { shown = false, scripts = {}, alpha = 1, width = 200, height = 0 }
    region.Show = function(self) self.shown = true end
    region.Hide = function(self)
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    region.IsShown = function(self) return self.shown end
    region.SetShown = function(self, on) self.shown = on and true or false end
    region.SetText = function(self, text) self.text = text end
    region.GetText = function(self) return self.text end
    region.SetAlpha = function(self, a) self.alpha = a end
    region.SetHeight = function(self, h) self.height = h end
    region.GetWidth = function(self) return self.width end
    region.SetWidth = function(self, w) self.width = w end
    region.SetScript = function(self, name, fn) self.scripts[name] = fn end
    region.CreateTexture = function() return Region() end
    region.CreateFontString = function() return Region() end
    region.SetFont = function(self, _, size) self.size = size end
    return setmetatable(region, { __index = function() return function() end end })
end

CreateFrame = function()
    local frame = Region()
    frames[#frames + 1] = frame
    return frame
end
UIParent = Region()
UISpecialFrames = {}
tinsert = table.insert
GameTooltip = Region()

local played = {}
PlaySoundFile = function(path) played[#played + 1] = path; return true end
PlaySound = function(id) played[#played + 1] = id; return true end

--------------------------------------------------------------------------------
-- The addon around it
--------------------------------------------------------------------------------

local settings = { mailReport = true, countMailAsStock = true }
local record = {}

ns.db = { mailLedger = {} }
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetRealmKey = function() return "Testrealm-Alliance" end,
    GetCharacterKey = function() return "Tester Surname-Testrealm" end,
}
ns.Recipes = {
    GetCharacterRecord = function() return record end,
    GetAll = function() return {} end,
    GetAccountWide = function() return { [1] = { outputItemID = LINEN_BAG } } end,
}
ns.Prices = { GetValue = function(_, itemID) return ({ [CLOTH] = 10 })[itemID] end }

local function Load(path) assert(loadfile(lfs_cwd .. path))("Blackthornes_TS", ns) end

Load("/Core/Util.lua")
Load("/UI/Theme.lua")
Load("/UI/Widgets.lua")
Load("/UI/Titanforged.lua")
Load("/Logic/Banks.lua")
Load("/Data/Mail.lua")
Load("/Logic/MailHaul.lua")
Load("/UI/MailReport.lua")

local Mail, MailHaul, MailReport, Util = ns.Mail, ns.MailHaul, ns.MailReport, ns.Util

local shownReports = {}
local realShow = MailReport.Show
MailReport.Show = function(self, haul, opts)
    shownReports[#shownReports + 1] = haul
    return realShow(self, haul, opts)
end

--------------------------------------------------------------------------------

local failures = 0

local function check(label, got, expected)
    local ok = got == expected
    if not ok then failures = failures + 1 end
    print(("  %-56s %-12s %s"):format(label, tostring(got), ok and "ok" or
        ("FAILED, expected " .. tostring(expected))))
end

--- Walk up to the mailbox: what the MAIL_SHOW handlers do.
local function Open()
    Mail.isOpen = true
    Mail.inboxUpdatedThisVisit = true
    MailHaul:BeginVisit()
    MailReport:OnMailboxOpened()
    Mail:Read()
end

--- Walk away: what the MAIL_CLOSED handlers do.
local function Close()
    Mail.isOpen = false
    MailReport:OnMailboxClosed()
    if MailHaul.visit then return MailHaul:EndVisit() end
end

local function Take(index)
    table.remove(inbox, index)
    Mail:Read()
end

local function Sold(name, money)
    return { sender = "Auction House", subject = "Auction successful: " .. name, money = money,
        invoice = { itemName = name, bid = money } }
end

--- Run every animation to its end.
local function Settle()
    for _, frame in ipairs(frames) do
        local step = frame.scripts.OnUpdate
        if step and frame.shown then
            for _ = 1, 200 do step(frame, 0.05) end
        end
    end
end

--------------------------------------------------------------------------------
print("")
print("a mailbox visit is added up as mail is taken")
--------------------------------------------------------------------------------

inbox = {
    Sold("Linen Bag", 5000),
    Sold("Linen Bag", 3000),
    { sender = "Auction House", subject = "Auction expired: Linen Cloth",
      items = { { itemID = CLOTH, count = 20 } } },
    { sender = "Alt", subject = "some bits", money = 10000, items = { { itemID = VIAL, count = 1 } } },
    { sender = "Auction House", subject = "Outbid on Wool Cloth", money = 2500 },
}

Open()
check("opening the mailbox collects nothing",          MailHaul:Current().total, 0)

Take(1)
check("taking a sale adds its gold",                   MailHaul:Current().total, 5000)
check("and counts one sale",                           #MailHaul:Current().sales, 1)
check("the tally over the mailbox appears",            MailReport.tally and MailReport.tally.shown, true)

-- The letter from Alt: gold first, then the item, in two goes.
inbox[3].money = 0
Mail:Read()
check("gold taken off a letter counts",                MailHaul:Current().gold.other, 10000)

inbox[3].items = {}
Mail:Read()
check("its item counts once taken",                    MailHaul:Current().items.other[VIAL], 1)
check("still one letter, not two",                     MailHaul:Current().letters, 1)

-- The expired cloth: the mail goes when its item is taken.
Take(2)
check("an expired stack is collected",                 MailHaul:Current().items.expired[CLOTH], 20)

--------------------------------------------------------------------------------
print("")
print("what arrives or changes while you stand there is not collected")
--------------------------------------------------------------------------------

local before = MailHaul:Current().total

inbox[#inbox + 1] = Sold("Linen Bag", 8000)
Mail:Read()
check("a sale arriving is not gold you took",          MailHaul:Current().total, before)

-- A sale whose gold the auction house is still holding reads 0, then pays out.
inbox[#inbox + 1] = { sender = "Auction House", subject = "Auction successful: Linen Bag", money = 0,
    invoice = { itemName = "Linen Bag", bid = 4000 } }
Mail:Read()
inbox[#inbox].money = 4000
Mail:Read()
check("gold being released is not gold you took",      MailHaul:Current().total, before)

-- An attachment that stops being readable for a moment is not one you took.
inbox[#inbox + 1] = { sender = "Auction House", subject = "Auction won: Wool Cloth",
    items = { { itemID = WOOL, count = 40 } } }
Mail:Read()
inbox[#inbox].items[1].unloaded = true
Mail:Read()
check("an item still loading is not collected",        MailHaul:Current().items.won, nil)
inbox[#inbox].items[1].unloaded = nil
Mail:Read()
check("and it is not counted when it loads again",     MailHaul:Current().items.won, nil)

--------------------------------------------------------------------------------
print("")
print("then all of it is taken")
--------------------------------------------------------------------------------

while #inbox > 0 do Take(1) end

local visit = MailHaul:Current()
check("sales and refunds and the letter add up",       visit.total, 3000 + 5000 + 10000 + 2500 + 8000 + 4000)
check("the refunded bid is kept apart",                visit.gold.outbid, 2500)
check("four sales",                                    #visit.sales, 4)
check("the bought wool is collected",                  visit.items.won[WOOL], 40)
check("the tally counted up to it",                    MailReport.tally.amount.text ~= nil, true)

--------------------------------------------------------------------------------
print("")
print("walking away saves the visit and opens the report")
--------------------------------------------------------------------------------

played = {}
local haul = Close()

check("a haul was made",                               haul ~= nil, true)
check("its total",                                     haul.total, 32500)
check("sales from gold only",                          haul.gold.sold, 20000)
check("best sale first",                               haul.best.amount, 8000)
check("named from the sales record",                   haul.best.itemID, LINEN_BAG)
check("first visit is not a record",                   haul.recordHaul, false)
check("but it is the first",                           haul.first, true)
check("the returned cloth is valued",                  haul.returnedValue, 200)
check("saved to the realm's history",                  #MailHaul:GetHistory(), 1)
check("the report opened",                             #shownReports, 1)
check("the tally lingers after you leave",             MailReport.tally.shown, true)
check("the haul sound played",                         played[1], MailReport.SOUNDS.haul)

Settle()
check("the total counted all the way up",             MailReport.frame.amount.text, Util.FormatMoney(32500))
check("the report says where it came from",           MailReport.frame.sources.text,
    "from 4 sales, refunded bids and 1 letter")
check("a line in chat as well",                        printed[#printed]:find("Mail collected", 1, true) ~= nil, true)
check("closing the mailbox twice does nothing more",   Close(), nil)

--------------------------------------------------------------------------------
print("")
print("the red close gems")
--------------------------------------------------------------------------------

local gem = MailReport.frame.titan and MailReport.frame.titan.closeButton
check("the report wears the close gem",                 gem ~= nil, true)
MailReport.tally:Show()
gem.scripts.OnClick(gem)
check("which closes the report",                        MailReport.frame.shown, false)
local tallyGem = MailReport.tally.close
check("the tally has its own gem",                      tallyGem ~= gem and tallyGem.scripts.OnClick ~= nil, true)
tallyGem.scripts.OnClick(tallyGem)
check("which puts the tally away",                      MailReport.tally.shown, false)

--------------------------------------------------------------------------------
print("")
print("what the report lists")
--------------------------------------------------------------------------------

local lines = MailReport.Lines(haul)
local headings = {}
for _, line in ipairs(lines) do
    if line.type == "heading" then headings[#headings + 1] = line.text end
end
check("sections in order",                              table.concat(headings, " / "),
    "WHERE IT CAME FROM / BEST SALE / ALSO SOLD / ITEMS COLLECTED")
check("three sources of gold",                          lines[2].label .. "," .. lines[3].label .. "," .. lines[4].label,
    "Auction sales,Refunded bids,Other mail")
check("their shares add to the whole",                  lines[2].share + lines[3].share + lines[4].share, 1)
check("the best sale is lit",                           lines[6].best, true)

--------------------------------------------------------------------------------
print("")
print("a bigger visit beats the record, with a fanfare")
--------------------------------------------------------------------------------

now = now + 3600
inbox = { Sold("Linen Bag", 50000), Sold("Linen Bag", 1000) }
Open()
Take(1)
Take(1)
played = {}
local second = Close()

check("a new best haul",                               second.recordHaul, true)
check("the old best is named",                         second.previousBest, 32500)
check("and the best sale ever",                        second.recordSale, true)
check("today adds both visits",                        second.today, 32500 + 51000)
Settle()
check("the record fanfare played",                     played[#played], MailReport.SOUNDS.record)
check("the ribbon says so",                            MailReport.frame.ribbon.text.text:find("NEW BEST HAUL", 1, true) ~= nil, true)

--------------------------------------------------------------------------------
print("")
print("nothing collected, nothing saved; the setting stops the window only")
--------------------------------------------------------------------------------

inbox = { Sold("Linen Bag", 700) }
Open()
check("a visit that takes nothing makes no haul",      Close(), nil)
check("and nothing is saved",                          #MailHaul:GetHistory(), 2)

settings.mailReport = false
local reportsBefore = #shownReports
Open()
Take(1)
check("the tally stays hidden with the setting off",   MailReport.tally.shown, false)
local quiet = Close()
check("the visit is still saved",                      quiet ~= nil and #MailHaul:GetHistory(), 3)
check("but no window opens",                           #shownReports, reportsBefore)
settings.mailReport = true

--------------------------------------------------------------------------------
print("")
print("saved visits are trimmed, the report is not")
--------------------------------------------------------------------------------

inbox = {}
for index = 1, 14 do inbox[index] = Sold("Linen Bag", 100 * index) end
Open()
while #inbox > 0 do Take(1) end
local big = Close()
local saved = MailHaul:GetHistory()[#MailHaul:GetHistory()]

check("the report sees every sale",                    #big.sales, 14)
check("the saved copy keeps ten",                      #saved.sales, 10)
check("but still knows how many there were",           saved.salesCount, 14)

local capped = MailReport.Lines(big)
local saleRows = 0
for _, line in ipairs(capped) do if line.type == "sale" then saleRows = saleRows + 1 end end
check("the report shows the best and five more",       saleRows, 6)
check("and says how many it left out",                 capped[#capped].label, "and 8 more sales")

--------------------------------------------------------------------------------
print("")
print("the sample for /bts haul test and the Preview button")
--------------------------------------------------------------------------------

local sample = MailHaul:Sample()
check("a sample beats the real best",                  sample.total > MailHaul:Records(), true)
local historyBefore = #MailHaul:GetHistory()
MailReport:Show(sample)
Settle()
check("showing it saves nothing",                      #MailHaul:GetHistory(), historyBefore)

--------------------------------------------------------------------------------
print("")
print("a mail that drops out and comes back is not counted twice")
--------------------------------------------------------------------------------

-- Asked 2026-09-28: the tally read 12g 24s 44c where the game said he had
-- gained 6g 12s 22c. A take going through makes the mail vanish, reappear
-- when the inbox is refreshed, then vanish for good.

inbox = { Sold("Linen Bag", 5000), Sold("Linen Bag", 3000) }
Open()

local first = table.remove(inbox, 1)
Mail:Read()
check("gone once: counted",                            MailHaul:Current().total, 5000)
table.insert(inbox, 1, first)
Mail:Read()
check("back again: taken off",                         MailHaul:Current().total, 0)
check("and its sale with it",                          #MailHaul:Current().sales, 0)
table.remove(inbox, 1)
Mail:Read()
check("gone for good: counted once",                   MailHaul:Current().total, 5000)
Take(1)
check("the next sale adds normally",                   MailHaul:Current().total, 8000)
check("two sales, not three",                          #MailHaul:Current().sales, 2)
local logged = MailHaul:Current().log
check("the log says what happened",                    logged[3] ~= nil and logged[3]:find("came back", 1, true) ~= nil, true)
Close()
check("the log is kept for /bts haul log",             MailHaul.lastLog ~= nil, true)

--------------------------------------------------------------------------------
print("")
print("a new mail that looks like one coming back keeps the real sale")
--------------------------------------------------------------------------------

-- Over 50 mails the game shows 50. Take one and the next moves into view; if
-- it is the same item for the same amount it looks like the taken one coming
-- back. The sale taken was still real, so the best sale must not lose it.

inbox = { Sold("Runecloth Bag", 90000), Sold("Linen Bag", 1000) }
Open()
Take(1)
table.insert(inbox, Sold("Runecloth Bag", 90000))
Mail:Read()
Take(1)
local backlog = Close()
check("the best sale is the one taken",                backlog.best and backlog.best.amount, 90000)
check("both sales are counted",                        backlog.salesCount, 2)

--------------------------------------------------------------------------------
print("")
print("your purse is the truth for how much came in")
--------------------------------------------------------------------------------

local purse = 100000
GetMoney = function() return purse end

inbox = { Sold("Linen Bag", 5000), Sold("Wool Bag", 3000) }
Open()

-- Whatever the mail says, gold only counts once the purse shows it.
purse = purse + 5000
Take(1)
check("the tally follows the purse",                   MailHaul:Current().total, 5000)

-- A reading that somehow counts the other sale twice cannot push the
-- total past what actually arrived.
MailHaul:Current().gold.sold = MailHaul:Current().gold.sold + 3000
purse = purse + 3000
Take(1)
check("the total is what the purse gained",            MailHaul:Current().total, 8000)
local purseHaul = Close()
check("the report agrees",                             purseHaul.total, 8000)
check("and the split is scaled to fit",                purseHaul.gold.sold, 8000)

-- Sending mail or paying postage takes gold out; that is not collected, and
-- does not cancel what was.
inbox = { Sold("Linen Bag", 2000) }
Open()
purse = purse - 30
MailHaul:CheckMoney()
purse = purse + 2000
Take(1)
check("gold spent at the mailbox is left out",         MailHaul:Current().total, 2000)
Close()

-- A look-alike moving into view after the first sale's gold reached the
-- purse is a new mail. Taking it too is a second sale, not the first again.
inbox = { Sold("Runecloth Bag", 90000), Sold("Linen Bag", 1000) }
Open()
purse = purse + 90000
Take(1)
table.insert(inbox, 1, Sold("Runecloth Bag", 90000))
Mail:Read()
purse = purse + 90000
Take(1)
local twice = Close()
check("two look-alike sales taken are two sales",      twice.salesCount, 2)
check("and both count toward the total",               twice.total, 180000)

-- Without the gold arriving, the same shape is one mail coming back.
inbox = { Sold("Runecloth Bag", 90000) }
Open()
local bag = table.remove(inbox, 1)
Mail:Read()
table.insert(inbox, 1, bag)
Mail:Read()
purse = purse + 90000
Take(1)
local once = Close()
check("a sale whose gold never left the mail counts once", once.salesCount, 1)

GetMoney = nil

--------------------------------------------------------------------------------
print("")
print("however the mailbox closes, the visit ends once")
--------------------------------------------------------------------------------

inbox = { Sold("Linen Bag", 900) }
Open()
Take(1)
local reportsNow = #shownReports
MailHaul:Closed()
MailHaul:Closed()
check("one report for two close signals",              #shownReports, reportsNow + 1)
check("the mailbox counts as closed",                  Mail.isOpen, false)

--------------------------------------------------------------------------------
print("")
print("another addon hiding the mail window does not end the visit")
--------------------------------------------------------------------------------

local handlers, hooks = {}, {}
local realRegister = ns.RegisterEvent
ns.RegisterEvent = function(_, event, fn) handlers[event] = fn; return true end
MailFrame = { HookScript = function(_, script, fn) hooks[script] = fn end }
MailHaul:OnEnable()
ns.RegisterEvent = realRegister

inbox = { Sold("Linen Bag", 800), Sold("Linen Bag", 400) }
Open()
Take(1)
if hooks.OnHide then hooks.OnHide() end
check("still at the mailbox after the window hides",   MailHaul:InVisit(), true)
Take(1)
check("both sales in the same visit",                  #MailHaul:Current().sales, 2)
handlers.MAIL_CLOSED()
check("the game saying it closed ends it",             MailHaul:InVisit(), false)
MailFrame = nil

--------------------------------------------------------------------------------
print("")
print("the tally can be closed, and goes when the mailbox does")
--------------------------------------------------------------------------------

inbox = { Sold("Linen Bag", 500), Sold("Linen Bag", 600) }
Open()
Take(1)
local tally = MailReport.tally
check("the tally is up",                               tally.shown, true)
-- The stub answers every unknown field with a function, "disabled" too.
tally.close.disabled = false
tally.close.scripts.OnClick(tally.close, "LeftButton")
check("its X hides it",                                tally.shown, false)
Take(1)
check("and it stays hidden for this visit",            tally.shown, false)
Close()

inbox = { Sold("Linen Bag", 700) }
Open()
Take(1)
check("back on the next visit",                        tally.shown, true)
-- The game never says the mailbox closed; the once-a-second check notices,
-- and the tally stays for 30 seconds before it fades.
Mail.isOpen = false
tally.scripts.OnUpdate(tally, 1.1)
check("still up just after leaving",                   tally.shown, true)
local function Wait(seconds)
    for _, frame in ipairs(frames) do
        local step = frame.scripts.OnUpdate
        if step and frame.shown and frame ~= tally then
            for _ = 1, math.floor(seconds / 0.5) do step(frame, 0.5) end
        end
    end
end
Wait(29)
check("still up at 29 seconds",                        tally.shown, true)
Wait(3)
check("faded out after 30",                            tally.shown, false)
check("and ready to show fully next time",             tally.alpha, 1)
MailHaul:Closed()

MailHaul:InvalidateMatchers()

if failures > 0 then
    error(("%d mail report check(s) failed"):format(failures))
end

print("")
print("  mail report: all checks passed")
