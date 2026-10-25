-- Blackthornes Tradeskills -- Core/Compat.lua
-- Runtime capability detection.
--
-- This is the only file in the addon permitted to care what shape the client's
-- API is. Blizzard has published nothing about how WoW: Forever's auction house
-- works -- retail commodity-style or legacy per-item -- so we ask the client at
-- load time instead of guessing, and everything downstream reads flags.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Compat = ns.NewModule("Compat")

local Util = ns.Util

--------------------------------------------------------------------------------
-- Namespace enumeration
--------------------------------------------------------------------------------

-- Namespaces worth capturing in full for the probe report. Enumerating what is
-- actually there beats checking a hand-written list against a client nobody has
-- documented yet.
local INTERESTING_NAMESPACES = {
    "C_AuctionHouse",
    "C_TradeSkillUI",
    "C_Item",
    "C_Container",
    "C_MerchantFrame",
    "C_Bank",
    "C_BankFrame",
    "C_TooltipInfo",
    "C_CraftingOrders",
    "C_Spell",
    "C_Secrets",
    "C_RestrictedActions",
}

-- Legacy globals. Their presence means Forever kept Classic's auction and
-- tradeskill model rather than inheriting retail's.
local LEGACY_GLOBALS = {
    "QueryAuctionItems",
    "GetNumAuctionItems",
    "GetAuctionItemInfo",
    "GetAuctionItemLink",
    "CanSendAuctionQuery",
    "CalculateAuctionDeposit",
    "PlaceAuctionBid",
    "PostAuction",
    "StartAuction",
    "SortAuctionItems",
    "GetTradeSkillInfo",
    "GetNumTradeSkills",
    "GetTradeSkillNumReagents",
    "GetTradeSkillReagentInfo",
    "DoTradeSkill",
    "GetItemInfo",
    "GetContainerItemInfo",
    "GetMerchantNumItems",
    "GetMerchantItemLink",
    "GetMerchantItemInfo",
    "BuyMerchantItem",
}

--- Sorted list of function names on a namespace, or nil if it is absent.
local function EnumerateNamespace(name)
    local namespace = _G[name]
    if type(namespace) ~= "table" then return nil end

    local functions = {}
    local ok = pcall(function()
        for key, value in pairs(namespace) do
            if type(value) == "function" then
                functions[#functions + 1] = key
            end
        end
    end)

    if not ok then
        -- Some namespaces refuse enumeration; that itself is worth reporting.
        return { "<not enumerable>" }
    end

    table.sort(functions)
    return functions
end

--------------------------------------------------------------------------------
-- Capability detection
--------------------------------------------------------------------------------

function Compat:Detect()
    if self.detected then return self.caps end

    local caps = {
        clientVersion = nil,
        clientBuild = nil,
        interfaceVersion = nil,
        namespaces = {},
        legacyGlobals = {},
        auction = {},
        tradeskill = {},
        cvars = {},
    }

    caps.checkedAt = time()

    local ok, version, build, _, tocVersion = pcall(GetBuildInfo)
    if ok then
        caps.clientVersion = version
        caps.clientBuild = build
        caps.interfaceVersion = tocVersion
    end

    for i = 1, #INTERESTING_NAMESPACES do
        local name = INTERESTING_NAMESPACES[i]
        caps.namespaces[name] = EnumerateNamespace(name)
    end

    for i = 1, #LEGACY_GLOBALS do
        local name = LEGACY_GLOBALS[i]
        caps.legacyGlobals[name] = type(_G[name]) == "function"
    end

    self:DetectAuction(caps)
    self:DetectTradeskill(caps)
    self:DetectCVars(caps)

    self.caps = caps
    self.detected = true
    return caps
end

function Compat:DetectAuction(caps)
    local auction = caps.auction

    auction.hasBrowseQuery      = Util.HasFunction("C_AuctionHouse.SendBrowseQuery")
    auction.hasSearchQuery      = Util.HasFunction("C_AuctionHouse.SendSearchQuery")
    auction.hasMoreBrowse       = Util.HasFunction("C_AuctionHouse.RequestMoreBrowseResults")
    auction.hasBrowseResults    = Util.HasFunction("C_AuctionHouse.GetBrowseResults")
    auction.hasMakeItemKey      = Util.HasFunction("C_AuctionHouse.MakeItemKey")
    auction.hasThrottleCheck    = Util.HasFunction("C_AuctionHouse.IsThrottledMessageSystemReady")

    -- Commodity support is the single biggest fork in the scanner design: it
    -- decides whether stackable reagents are one region-wide pool or thousands
    -- of individual listings.
    auction.hasCommodities =
        Util.HasFunction("C_AuctionHouse.GetCommoditySearchResultsQuantity") or
        Util.HasFunction("C_AuctionHouse.GetNumCommoditySearchResults")

    auction.hasCommodityInfo    = Util.HasFunction("C_AuctionHouse.GetCommoditySearchResultInfo")
    auction.hasItemResultInfo   = Util.HasFunction("C_AuctionHouse.GetItemSearchResultInfo")

    -- ReplicateItems is retail's bulk "give me everything" scan. If Forever kept
    -- it, a full sweep costs one request instead of hundreds of pages.
    auction.hasReplicate =
        Util.HasFunction("C_AuctionHouse.ReplicateItems") and
        Util.HasFunction("C_AuctionHouse.GetReplicateItemInfo")

    -- Whether a function is *protected* matters more than whether it exists:
    -- a secure value is callable-looking but can never be called from addon
    -- code. Recorded in the probe report so a client patch that changes it
    -- can be spotted by comparison rather than rediscovered by failing.
    auction.postItemSecure = Util.IsSecure(C_AuctionHouse, "PostItem")
    auction.postCommoditySecure = Util.IsSecure(C_AuctionHouse, "PostCommodity")

    auction.hasPostItem = Util.HasFunction("C_AuctionHouse.PostItem")
    auction.hasPostCommodity = Util.HasFunction("C_AuctionHouse.PostCommodity")
    auction.hasItemLocation = type(_G.ItemLocation) == "table"

    auction.hasDepositCalc =
        Util.HasFunction("C_AuctionHouse.CalculateCommodityDeposit") or
        Util.HasFunction("C_AuctionHouse.CalculateItemDeposit")

    -- Midnight can drop copper from auction prices entirely. If this returns
    -- false, prices are silver-granular and profit maths must round the same
    -- way the client does or every figure will be off by a few copper.
    if Util.HasFunction("C_AuctionHouse.SupportsCopperValues") then
        local ok, supports = pcall(C_AuctionHouse.SupportsCopperValues)
        auction.supportsCopperValues = ok and supports or false
    end

    -- Legacy page-scan path.
    auction.hasLegacyQuery =
        caps.legacyGlobals["QueryAuctionItems"] and
        caps.legacyGlobals["GetAuctionItemInfo"] and
        caps.legacyGlobals["GetNumAuctionItems"]

    if auction.hasBrowseQuery and auction.hasBrowseResults then
        auction.mode = "modern"
    elseif auction.hasLegacyQuery then
        auction.mode = "legacy"
    else
        auction.mode = "unknown"
    end
end

function Compat:DetectTradeskill(caps)
    local trade = caps.tradeskill

    trade.hasAllRecipeIDs    = Util.HasFunction("C_TradeSkillUI.GetAllRecipeIDs")
    trade.hasFilteredIDs     = Util.HasFunction("C_TradeSkillUI.GetFilteredRecipeIDs")
    trade.hasRecipeInfo      = Util.HasFunction("C_TradeSkillUI.GetRecipeInfo")
    trade.hasSchematic       = Util.HasFunction("C_TradeSkillUI.GetRecipeSchematic")
    trade.hasCraftRecipe     = Util.HasFunction("C_TradeSkillUI.CraftRecipe")
    trade.craftRecipeSecure  = Util.IsSecure(C_TradeSkillUI, "CraftRecipe")
    trade.hasOutputItemData  = Util.HasFunction("C_TradeSkillUI.GetRecipeOutputItemData")
    trade.hasChildProfession = Util.HasFunction("C_TradeSkillUI.GetChildProfessionInfos")
    trade.hasCraftableCount  = Util.HasFunction("C_TradeSkillUI.GetCraftableCount")

    -- Forever has no plain GetProfessionInfo; profession metadata comes from the
    -- skill-line functions instead.
    trade.hasProfessionInfo =
        Util.HasFunction("C_TradeSkillUI.GetProfessionInfoBySkillLineID") or
        Util.HasFunction("C_TradeSkillUI.GetBaseProfessionInfo")

    -- Enumerates the character's professions without a profession window open,
    -- which is what makes account-wide recipe caching possible.
    trade.hasAllProfessionLines = Util.HasFunction("C_TradeSkillUI.GetAllProfessionTradeSkillLines")

    trade.hasRecipeItemLink  = Util.HasFunction("C_TradeSkillUI.GetRecipeItemLink")

    -- Whether a recipe's difficulty -- the orange/yellow/green/grey that says
    -- if it will still skill you up -- can be read at all. Presence only; which
    -- of these actually answers is filled in by Logic/SkillUp.lua the first
    -- time one does, and reported by /bts skillup.
    trade.hasRecipeDifficulty = Util.HasFunction("C_TradeSkillUI.GetRecipeDifficulty")
    trade.hasLegacySkillList  = Util.HasFunction("GetNumTradeSkills")
        and Util.HasFunction("GetTradeSkillInfo")
    trade.hasDifficultyEnum   = type(Enum) == "table"
        and type(Enum.TradeskillRelativeDifficulty) == "table"
    trade.hasReagentSlotStatus = Util.HasFunction("C_TradeSkillUI.GetReagentSlotStatus")

    -- Reagent quality tiers are a Dragonflight-era retail concept. Forever is
    -- classic-flavoured content on a retail engine, so the functions may exist
    -- while no recipe actually uses them. Confirmed for real in Probe, by
    -- inspecting a live schematic rather than trusting the function's presence.
    trade.hasQualityFunctions =
        Util.HasFunction("C_TradeSkillUI.GetItemReagentQualityInfo") or
        Util.HasFunction("C_TradeSkillUI.GetRecipeItemQualityInfo")

    trade.hasQualitiesForRecipe = Util.HasFunction("C_TradeSkillUI.GetQualitiesForRecipe")

    trade.qualityTiersObserved = nil  -- set by Probe once a schematic is seen

    trade.hasLegacyTradeSkill =
        caps.legacyGlobals["GetTradeSkillInfo"] and
        caps.legacyGlobals["GetNumTradeSkills"]

    if trade.hasAllRecipeIDs and trade.hasSchematic then
        trade.mode = "modern"
    elseif trade.hasLegacyTradeSkill then
        trade.mode = "legacy"
    else
        trade.mode = "unknown"
    end
end

--------------------------------------------------------------------------------
-- Public accessors
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Console variables
--------------------------------------------------------------------------------

-- Worth probing because this client writes SavedVariables at logout but never
-- reads them back, while community reports say CVars *are* persisted. If that
-- holds, small settings can live in CVars instead. Large tables cannot: a CVar
-- is a single string.
--
-- Registration is what the client uses to decide an addon CVar is worth
-- keeping, and the exact spelling differs across builds, so both known names
-- are tried and the one that worked is recorded rather than assumed.
local CVAR_TEST = "BTS_probeRoundTrip"

function Compat:DetectCVars(caps)
    local cvars = caps.cvars

    cvars.hasNamespace = type(C_CVar) == "table"
    cvars.hasGet = Util.HasFunction("C_CVar.GetCVar")
    cvars.hasSet = Util.HasFunction("C_CVar.SetCVar")
    cvars.hasRegisterAddonCVar = Util.HasFunction("C_CVar.RegisterAddonCVar")
    cvars.hasRegisterCVar = Util.HasFunction("C_CVar.RegisterCVar")

    if not (cvars.hasGet and cvars.hasSet) then return end

    if cvars.hasRegisterAddonCVar then
        local ok = pcall(C_CVar.RegisterAddonCVar, CVAR_TEST)
        if ok then cvars.registerVia = "RegisterAddonCVar" end
    end

    if not cvars.registerVia and cvars.hasRegisterCVar then
        local ok = pcall(C_CVar.RegisterCVar, CVAR_TEST, "0")
        if ok then cvars.registerVia = "RegisterCVar" end
    end

    -- Writing and reading back inside one session. This does not prove the
    -- value survives a logout, only that the mechanism works at all; the
    -- canary in Config answers the persistence half.
    local stamp = tostring(time())

    local setOk = pcall(C_CVar.SetCVar, CVAR_TEST, stamp)
    local getOk, got = pcall(C_CVar.GetCVar, CVAR_TEST)

    cvars.roundTrip = setOk and getOk and tostring(got) == stamp
end

function Compat:Get()
    return self:Detect()
end

function Compat:AuctionMode()
    return self:Detect().auction.mode
end

function Compat:TradeskillMode()
    return self:Detect().tradeskill.mode
end

--- True when the client exposes enough of an API for the scanner to run at all.
function Compat:IsSupported()
    local caps = self:Detect()
    return caps.auction.mode ~= "unknown" and caps.tradeskill.mode ~= "unknown"
end

function Compat:OnInitialize()
    self:Detect()
end

function Compat:OnEnable()
    local caps = self:Detect()

    if not self:IsSupported() then
        ns.Warn(L["this version of the game has auction or profession functions this addon does not recognise."])
        ns.Warn(L["run |cffc8a44d/bts probe|r and report what it says."])
        return
    end

    ns.Debug(("auction=%s tradeskill=%s commodities=%s"):format(
        caps.auction.mode, caps.tradeskill.mode, tostring(caps.auction.hasCommodities)))
end
