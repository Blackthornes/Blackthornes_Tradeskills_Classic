-- Blackthornes Tradeskills -- Probe/Probe.lua
-- Phase 0 diagnostics.
--
-- Answers the two questions the rest of the addon is built on top of, using the
-- live client rather than assumptions:
--   1. Do SavedVariables actually survive a logout on the Forever beta?
--   2. What shape are the auction house and profession APIs?
--
-- It also samples a real recipe schematic, because the presence of the retail
-- reagent-quality functions says nothing about whether Forever's recipes use
-- them. Results go to chat as a summary and to SavedVariables in full.

local _, ns = ...

local Probe = ns.NewModule("Probe")

local Util = ns.Util

-- Classic-era reagents, chosen because they are near-certain to exist in
-- Forever's original-Azeroth item space and to be auctioned in volume.
local SAMPLE_ITEM_IDS = {
    2589,   -- Linen Cloth
    2770,   -- Copper Ore
    2447,   -- Peacebloom
    2836,   -- Coarse Stone
    765,    -- Silverleaf
}

--------------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------------

--- Inspect live recipe data. Only meaningful with a profession window open,
--- which is why this is event-driven rather than done at load.
function Probe:SampleTradeskill()
    local caps = ns.Compat:Get()
    local trade = caps.tradeskill

    if trade.mode ~= "modern" then return nil end

    -- Profession lines are readable without a profession window open, so record
    -- them even when the recipe sample below comes up empty.
    local professionLines
    if trade.hasAllProfessionLines then
        local linesOk, lines = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
        if linesOk and type(lines) == "table" then
            professionLines = {}
            for i, skillLineID in ipairs(lines) do
                local entry = { skillLineID = skillLineID }

                if Util.HasFunction("C_TradeSkillUI.GetProfessionInfoBySkillLineID") then
                    local infoOk, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
                    if infoOk and info then
                        entry.name = info.professionName
                        entry.skillLevel = info.skillLevel
                        entry.maxSkillLevel = info.maxSkillLevel
                    end
                end

                professionLines[i] = entry
            end
        end
    end

    self.professionLines = professionLines

    local ok, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or type(recipeIDs) ~= "table" or #recipeIDs == 0 then
        -- Recipes are usually only enumerable with a profession window open.
        self.tradeskillMissReason = ok and "no recipes visible (open a profession window)"
            or "GetAllRecipeIDs failed"
        return nil
    end

    local sample = {
        recipeCount = #recipeIDs,
        capturedAt = time(),
        professionLines = professionLines,
        recipes = {},
    }

    -- A handful is enough to learn the schematic's shape.
    local limit = math.min(3, #recipeIDs)
    local sawQualityTiers = false

    for i = 1, limit do
        local recipeID = recipeIDs[i]

        local infoOk, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
        local schematicOk, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)

        local entry = {
            recipeID = recipeID,
            name = infoOk and info and info.name or nil,
            learned = infoOk and info and info.learned or nil,
            outputItemID = schematicOk and schematic and schematic.outputItemID or nil,
            quantityMin = schematicOk and schematic and schematic.quantityMin or nil,
            quantityMax = schematicOk and schematic and schematic.quantityMax or nil,
            reagentSlots = {},
        }

        if schematicOk and schematic and type(schematic.reagentSlotSchematics) == "table" then
            for slotIndex, slot in ipairs(schematic.reagentSlotSchematics) do
                local reagentCount = type(slot.reagents) == "table" and #slot.reagents or 0

                -- More than one reagent in a slot means quality tiers are real
                -- here, not merely supported by the API.
                if reagentCount > 1 then
                    sawQualityTiers = true
                end

                entry.reagentSlots[slotIndex] = {
                    reagentType = slot.reagentType,
                    required = slot.quantityRequired,
                    reagentChoices = reagentCount,
                    firstItemID = reagentCount > 0 and slot.reagents[1] and slot.reagents[1].itemID or nil,
                }
            end
        end

        sample.recipes[i] = entry
    end

    sample.qualityTiersObserved = sawQualityTiers
    ns.Compat:Get().tradeskill.qualityTiersObserved = sawQualityTiers

    self.tradeskillSample = sample
    return sample
end

--- Inspect live auction data. Requires an open auction house.
function Probe:SampleAuction()
    local caps = ns.Compat:Get()
    local auction = caps.auction

    local sample = {
        capturedAt = time(),
        mode = auction.mode,
        items = {},
    }

    if auction.mode == "modern" and auction.hasMakeItemKey then
        for i = 1, #SAMPLE_ITEM_IDS do
            local itemID = SAMPLE_ITEM_IDS[i]

            local keyOk, itemKey = pcall(C_AuctionHouse.MakeItemKey, itemID)
            local entry = { itemID = itemID, itemKeyOk = keyOk }

            if keyOk and itemKey and Util.HasFunction("C_AuctionHouse.GetItemKeyInfo") then
                local infoOk, keyInfo = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
                if infoOk and keyInfo then
                    entry.isCommodity = keyInfo.isCommodity
                    entry.itemName = keyInfo.itemName
                    entry.quality = keyInfo.quality
                end
            end

            -- Deposit maths feeds directly into the profit calculation, so find
            -- out what it really costs rather than hardcoding retail's numbers.
            if Util.HasFunction("C_AuctionHouse.CalculateCommodityDeposit") then
                local depositOk, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, 2, 1)
                if depositOk then
                    entry.commodityDeposit = deposit
                end
            end

            sample.items[#sample.items + 1] = entry
        end
    end

    if Util.HasFunction("C_AuctionHouse.IsThrottledMessageSystemReady") then
        local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
        sample.throttleReady = ok and ready or nil
    end

    -- Which auction window global actually exists, so the docked scan button
    -- can be anchored to something real rather than an assumed name.
    sample.frames = {}
    for _, name in ipairs({ "AuctionHouseFrame", "AuctionFrame", "AuctionHouseFrameBuyTab" }) do
        sample.frames[name] = type(_G[name]) == "table"
    end

    if ns.UI and ns.UI.FindAuctionFrame then
        local _, found = ns.UI:FindAuctionFrame()
        sample.dockedTo = found or "none"
    end

    self.auctionSample = sample
    return sample
end

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

function Probe:BuildReport()
    local caps = ns.Compat:Get()

    local report = {
        generatedAt = time(),
        addonVersion = ns.VERSION,
        client = {
            version = caps.clientVersion,
            build = caps.clientBuild,
            interface = caps.interfaceVersion,
        },
        persistence = ns.Config:GetPersistenceResult(),
        cvars = Util.CopyDeep(caps.cvars),
        cvarPersistence = Util.CopyDeep(ns.Config:GetCVarResult()),
        auction = Util.CopyDeep(caps.auction),
        tradeskill = Util.CopyDeep(caps.tradeskill),
        namespaces = Util.CopyDeep(caps.namespaces),
        legacyGlobals = Util.CopyDeep(caps.legacyGlobals),
        tradeskillSample = self.tradeskillSample and Util.CopyDeep(self.tradeskillSample) or nil,
        tradeskillMissReason = self.tradeskillMissReason,
        professionLines = self.professionLines and Util.CopyDeep(self.professionLines) or nil,
        auctionSample = self.auctionSample and Util.CopyDeep(self.auctionSample) or nil,
        unknownEvents = {},
    }

    for event in pairs(ns.GetUnknownEvents()) do
        report.unknownEvents[#report.unknownEvents + 1] = event
    end
    table.sort(report.unknownEvents)

    if ns.db then
        -- The namespace function lists are ~120KB of the saved file and serve
        -- no purpose once read. Keep the counts, drop the bulk: a saved-variable
        -- file that small is one less thing that can go wrong.
        local persisted = Util.CopyDeep(report)
        persisted.namespaces = {}

        for name, functions in pairs(report.namespaces) do
            persisted.namespaces[name] = functions and #functions or false
        end

        ns.db.probe.lastReport = persisted
    end
    return report
end

local function Yes(value)
    if value == true then
        return "|c" .. ns.COLORS.profit .. "yes|r"
    elseif value == false then
        return "|c" .. ns.COLORS.loss .. "no|r"
    end
    return "|c" .. ns.COLORS.muted .. "unknown|r"
end

local function Heading(text)
    ns.PrintRaw(("|c%s%s|r"):format(ns.COLORS.accent, text))
end

local function Line(label, value)
    ns.PrintRaw(("  |c%s%s|r %s"):format(ns.COLORS.muted, label, tostring(value)))
end

function Probe:PrintReport()
    local report = self:BuildReport()
    local caps = ns.Compat:Get()

    ns.Print(("game check, addon %s"):format(ns.VersionLabel()))

    Heading("Game")
    Line("version", ("%s (build %s, interface %s)"):format(
        tostring(report.client.version), tostring(report.client.build), tostring(report.client.interface)))

    -- The Blizzard window style draws with the game's own art; this says
    -- which pieces the client has (UI/BlizzardLook.lua).
    if ns.BlizzardLook then
        Heading("Window style")
        for _, text in ipairs(ns.BlizzardLook.ProbeLines()) do
            local name, value = text:match("^(.-): (.*)$")
            Line(name or "style", value or text)
        end
    end

    Heading("Saved data (SavedVariables)")
    local persistence = report.persistence
    if persistence.loadCountBefore == 0 then
        Line("status", "|c" .. ns.COLORS.warn .. "NOT YET TESTED|r: this is the first load")
        Line("next", "quit the game fully, start it again, then run this again")
        Line("note", "a /reload or character select does not test this; it needs a full quit")
    elseif persistence.sawPrevious then
        Line("status", "|c" .. ns.COLORS.profit .. "WORKING|r: last session's data loaded")
        Line("sessions", persistence.loadCountBefore)
        Line("last saved", date("%Y-%m-%d %H:%M", persistence.previousStamp or 0))
    else
        Line("status", "|c" .. ns.COLORS.loss .. "BROKEN|r: data was saved but did not load")
        Line("result", "price history cannot be kept; use export and import instead")
    end

    -- The fallback store, if there is one. SavedVariables are known broken on
    -- this build, so whether CVars survive a logout decides whether settings
    -- can persist at all without an out-of-game helper.
    Heading("Backup storage (CVars)")
    local cvars = report.cvars or {}
    local cvarResult = report.cvarPersistence or {}

    Line("C_CVar present", Yes(cvars.hasNamespace))
    Line("get / set", Yes(cvars.hasGet and cvars.hasSet))
    Line("set up with", cvars.registerVia or "|c" .. ns.COLORS.loss .. "none worked|r")
    Line("save and read back", Yes(cvars.roundTrip))

    if not cvars.roundTrip then
        Line("result", "|c" .. ns.COLORS.loss .. "UNAVAILABLE|r: settings cannot be kept on this version of the game")
    elseif cvarResult.persisted then
        Line("result", "|c" .. ns.COLORS.profit .. "KEPT|r: settings are copied here")
        Line("sessions seen", cvarResult.previousCount)

        local mirroring, restored = ns.Persist:GetStatus()
        if ns.Persist:GameKeepsSavedData() then
            Line("settings copy", "off, not needed: the game keeps your saved data")
        else
            Line("settings copy", mirroring and ("on, %d restored this login"):format(restored)
                or "|c" .. ns.COLORS.loss .. "off|r")
        end
    else
        Line("result", "|c" .. ns.COLORS.warn .. "NOT YET TESTED|r: no earlier value to compare")
        Line("next", "quit the game fully, start it again, then run this again")
    end

    Heading("Auction house")
    Line("mode", caps.auction.mode)
    Line("commodities", Yes(caps.auction.hasCommodities))
    Line("browse query", Yes(caps.auction.hasBrowseQuery))
    Line("quick full scan", Yes(caps.auction.hasReplicate))
    Line("busy check", Yes(caps.auction.hasThrottleCheck))
    Line("old-style page scan", Yes(caps.auction.hasLegacyQuery))
    Line("copper values", Yes(caps.auction.supportsCopperValues))

    -- Scanning depends on these arriving; a rejected registration is silent
    -- otherwise and looks exactly like a hung scan.
    local unknown = ns.GetUnknownEvents()
    for _, event in ipairs({
        "REPLICATE_ITEM_LIST_UPDATE",
        "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
        "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    }) do
        -- Bracketed: gsub also returns a count, which took the value's place.
        Line((event:lower():gsub("_", " ")), Yes(not unknown[event]))
    end
    Line("post commodity", Yes(caps.auction.hasPostCommodity))
    Line("post item", Yes(caps.auction.hasPostItem))
    Line("post item PROTECTED", Yes(caps.auction.postItemSecure))
    Line("item locations", Yes(caps.auction.hasItemLocation))
    if ns.BuyQuantity then Line("fill buy quantity", ns.BuyQuantity:ProbeText()) end
    -- The drawer's Auctions view (2026-10-14): whether cancelling works here.
    if ns.MyAuctions then Line("cancel auctions", ns.MyAuctions:ProbeText()) end

    Heading("Vendors")
    Line("merchant item info", Yes(Util.HasFunction("C_MerchantFrame.GetItemInfo")))
    Line("merchant count", Yes(Util.HasFunction("GetMerchantNumItems")))
    Line("merchant links", Yes(Util.HasFunction("GetMerchantItemLink")))
    Line("buy from vendor", Yes(Util.HasFunction("BuyMerchantItem")))
    Line("take from mail", Yes(Util.HasFunction("TakeInboxItem")))
    if ns.SellMarked then Line("sell from addon", ns.SellMarked:ProbeText()) end
    Line("item stack size", Yes(Util.HasFunction("C_Item.GetItemMaxStackSizeByID")))
    Line("prices learned", ns.Vendor and ns.Vendor:Count() or 0)

    if self.auctionSample and #self.auctionSample.items > 0 then
        local first = self.auctionSample.items[1]
        Line("sample item", ("%s -> commodity=%s deposit=%s"):format(
            tostring(first.itemName or first.itemID),
            tostring(first.isCommodity),
            first.commodityDeposit and Util.FormatMoney(first.commodityDeposit, { noColor = true }) or "n/a"))
        Line("scan button docked to", self.auctionSample.dockedTo or "unknown")
    else
        Line("sample", "|c" .. ns.COLORS.muted .. "open the auction house and run this again|r")
    end

    Heading("Professions")
    Line("mode", caps.tradeskill.mode)
    Line("schematics", Yes(caps.tradeskill.hasSchematic))
    Line("craft function", Yes(caps.tradeskill.hasCraftRecipe))
    Line("craft PROTECTED", Yes(caps.tradeskill.craftRecipeSecure))
    Line("quality functions", Yes(caps.tradeskill.hasQualityFunctions))
    Line("quality tiers in use", Yes(caps.tradeskill.qualityTiersObserved))
    -- Crafts that need a tool or station nearby (2026-11-14).
    if ns.Crafting and ns.Crafting.ProbeText then Line("tools needed nearby", ns.Crafting:ProbeText()) end
    -- Goblin Gold's all-time numbers (2026-10-20): what the game's
    -- Statistics give an addon.
    if ns.GoldGoal and ns.GoldGoal.STATISTICS then
        local parts = {}
        for _, key in ipairs({ "quests", "kills", "questGold", "looted" }) do
            local raw = "none"
            if type(GetStatistic) == "function" then
                local ok, value = pcall(GetStatistic, ns.GoldGoal.STATISTICS[key])
                raw = ok and tostring(value) or "error"
            end
            parts[#parts + 1] = key .. "=" .. raw .. " (" .. tostring(ns.GoldGoal.Statistic(ns.GoldGoal.STATISTICS[key])) .. ")"
        end
        Line("statistics", table.concat(parts, ", "))
    end
    -- Legacy perks (2026-10-22): what the game lets an addon read.
    if ns.Legacy then
        for _, line in ipairs(ns.Legacy:ProbeLines()) do Line(line[1], line[2]) end
    end
    -- Learn next's Show the way (2026-10-12).
    if ns.Waypoints then Line("show the way", ns.Waypoints:ProbeText()) end

    if self.professionLines then
        for _, entry in ipairs(self.professionLines) do
            Line("profession", ("%s (%s/%s, line %s)"):format(
                tostring(entry.name or "?"),
                tostring(entry.skillLevel or "?"),
                tostring(entry.maxSkillLevel or "?"),
                tostring(entry.skillLineID)))
        end
    end

    if self.tradeskillSample then
        Line("recipes visible", self.tradeskillSample.recipeCount)
        local first = self.tradeskillSample.recipes[1]
        if first then
            Line("sample recipe", ("%s (%d reagent slots)"):format(
                tostring(first.name or first.recipeID), #first.reagentSlots))
        end
    else
        Line("sample", "|c" .. ns.COLORS.warn ..
            (self.tradeskillMissReason or "open a profession and run this again") .. "|r")
    end

    Heading("Game functions found")
    for _, name in ipairs(Util.SortedKeys(caps.namespaces)) do
        local functions = caps.namespaces[name]
        if functions then
            Line(name, ("%d functions"):format(#functions))
        else
            Line(name, "|c" .. ns.COLORS.loss .. "missing|r")
        end
    end

    ns.PrintRaw(("|c%sFull report saved. Type |r|c%s/reload|r|c%s, then the report is in|r"):format(
        ns.COLORS.muted, ns.COLORS.accent, ns.COLORS.muted))
    ns.PrintRaw(("|c%sWTF\\Account\\<id>\\SavedVariables\\Blackthornes_TS.lua|r"):format(ns.COLORS.muted))
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Probe:OnEnable()
    -- Sample opportunistically: these windows may never open this session, and
    -- the report degrades gracefully when they do not.
    ns.RegisterEvent(self, "TRADE_SKILL_LIST_UPDATE", self.OnTradeSkillUpdate)
    ns.RegisterEvent(self, "TRADE_SKILL_SHOW", self.OnTradeSkillUpdate)
    ns.RegisterEvent(self, "AUCTION_HOUSE_SHOW", self.OnAuctionHouseShow)

    local persistence = ns.Config:GetPersistenceResult()
    if persistence and persistence.loadCountBefore > 0 and not persistence.sawPrevious then
        ns.Warn("your saved data (SavedVariables) did not load from last session.")
        ns.Warn("Run |cffc8a44d/bts probe|r for details.")
    end
end

function Probe:OnTradeSkillUpdate()
    if self.tradeskillSample then return end
    self:SampleTradeskill()
end

function Probe:OnAuctionHouseShow()
    self:SampleAuction()
end

ns.RegisterCommand("probe", "check what this version of the game supports, and whether your data is kept", function()
    ns.Probe:SampleTradeskill()
    ns.Probe:SampleAuction()
    ns.KeepCheck("probe", ns.Probe.PrintReport, ns.Probe)
end)
