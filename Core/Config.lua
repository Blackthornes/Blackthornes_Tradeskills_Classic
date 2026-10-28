-- Blackthornes Tradeskills -- Core/Config.lua
-- Saved-variable bootstrap, schema versioning, and the persistence canary.
--
-- A community report on the Forever beta claims the client writes SavedVariables
-- but never reads them back. The whole price database depends on that being
-- wrong, so every login stamps a canary and reports whether the previous one
-- survived. `/bts probe` reads the answer out.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Config = ns.NewModule("Config")

local Util = ns.Util

Config.SCHEMA_VERSION = 1

--------------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------------

local DEFAULTS = {
    schema = Config.SCHEMA_VERSION,
    debug = false,

    global = {
        debug = false,
    },

    settings = {
        -- Value reagents you already own at market price (opportunity cost) or
        -- at zero (cash-out-of-pocket). Market is the honest default.
        valueOwnedMaterials = true,

        -- Auction-house cut applied to sale price. Overwritten by Compat once
        -- the probe observes the real value; never trust this literal.
        auctionCut = 0.05,

        -- How many times we assume an item is relisted before it sells, so the
        -- deposit is not silently ignored in the profit maths.
        expectedRelists = 1,

        -- Posting undercuts the cheapest listing by this much, and profit is
        -- calculated at that price. This models what you will actually receive
        -- rather than a smoothed market average you would never get.
        --
        -- Commodities only. An item auction cannot be priced in copper at all,
        -- so it steps by a whole silver or matches; see minProfit below.
        undercutCopper = 1,

        -- What to list a craft at when nothing is competing with it: what
        -- its materials are worth, plus this much. Two cases reach it --
        -- no scan has ever priced the output, or every listing on the book
        -- is yours. Neither has a competitor's price to read, and holding at
        -- market value in the second means charging whatever you charged
        -- last time for as long as nobody turns up.
        --
        -- Only ever upwards: a market value above this is a real observation
        -- and keeps the price. It is labelled everywhere it appears, and is
        -- never written into the price database, because a number we worked
        -- out must not come back later looking like something the auction
        -- house said.
        unscannedMarkupPercent = 50,

        -- Turns the above off entirely: unscanned crafts go back to having
        -- no price at all, and an uncontested one back to market value.
        priceUnscannedCrafts = true,

        -- Stop recommending an item once this many are already listed.
        -- Zero means no limit. Per-item overrides live in db.postLimits,
        -- per-profession ones in db.professionStockLimits.
        maxPostedPerItem = 0,

        -- Wait until it runs low (asked 2026-10-10): off, a craft is
        -- suggested whenever you hold fewer than the above, as before. On,
        -- only once what you hold (queued included) is down to restockAt,
        -- then back up to the limit. 0 = only when you have none.
        restockWhenLow = false,
        restockAt = 0,
        -- When one of your auctions sells, queue another while there is
        -- room under Keep in stock, or what your sales taught (asked
        -- 2026-10-11, Queue:RestockSold).
        restockOnSale = true,
        -- When every copy of a craft you listed sells before its listings
        -- run out, Keep in stock for it goes up by 1 (the owner,
        -- 2026-10-13, Logic/SellOut.lua). After 3 unsold rounds in a row it
        -- comes back down by 1, never below where it started (2026-10-16).
        -- Off unless ticked (the owner, 2026-10-13). Never rename it.
        raiseStockOnSellOut = false,
        -- With Keep in stock at 0, Queue All and Restock what sells keep
        -- about two days of what sold for you this week
        -- (Auctions:GetLearnedLimit). Off, a craft with no number set is
        -- never queued by them. Never rename it.
        learnStockFromSales = true,

        -- Fast sellers keep more: an item your own sales show selling well
        -- (Logic/Demand.lua, "High" from your record) may be held this many
        -- more than the limit. Off by default.
        fastSellerBoost = false,
        fastSellerExtra = 2,

        -- Auction duration: 1 = 2h, 2 = 8h, 3 = 24h on this server. How long
        -- each listing stays up, and so what its deposit is.
        postDuration = 2,

        -- Whether the Post tab lists everything in the bags or only what
        -- one of this account's recipes makes. A view, not a safety rail:
        -- nothing is ever listed without a click on its own row, and the
        -- bar's Post Crafted button stays crafted-only either way.
        postShowAllItems = true,

        -- Search the auction house for the item immediately before listing
        -- it. A full scan is a snapshot and goes stale; undercutting a price
        -- that moved ten minutes ago is how you end up listed above a rival.
        verifyPriceBeforePosting = true,
        -- A fresh price lists on the click, no Yes/No box (2026-10-14).
        fastListing = true,
        -- Post just under the big stack rather than under a few cheap ones
        -- that sell first (2026-10-15). Off unless ticked; never rename it.
        overcutting = false,
        -- At the auction house, wheel up lists the next stack and wheel
        -- down cancels the next undercut auction (2026-10-16). Off unless
        -- ticked; never rename it.
        mouseWheelListing = false,

        -- Nothing reads this any more, and Settings no longer offers it: every
        -- listing is confirmed, as the confirmation's Yes is the click that
        -- posts (Logic/Posting.lua). Kept so a saved value is never dropped.
        confirmBeforePosting = true,

        -- Whether to recommend selling below material cost. Such items are
        -- always shown, just marked red and skipped when picking what is
        -- worth listing.
        allowPostingAtALoss = false,

        -- Refuse a listing that, after the auction house's cut, brings in
        -- less than what the last craft of it cost (asked 2026-10-05). Off
        -- by default. See Logic/CraftedCost.lua.
        neverBelowCraftedCost = false,

        -- Leave on the Sell list, dimmed, what Blackthornes Farmer, Equipment,
        -- Pets and Butler want kept, so List all never posts it
        -- (Logic/SisterKeeps.lua, 2026-10-16). Off unless ticked (the owner,
        -- the same day); Config:SisterKeepsOffOnce turns off the true the
        -- first default wrote.
        sellHoldsSisterKeeps = false,

        -- Of those, gear Equipment says another character could wear is
        -- held back only while this is ticked (the owner, 2026-10-16: off
        -- by default). Never rename it.
        sellHoldsAltUpgrades = false,

        -- "Show Equipment Upgrades" on Profit, Level Up and the Queue: a
        -- craft that is an upgrade for another character says so after its
        -- name (Upgrades:AltText). Off unless ticked (the owner,
        -- 2026-10-17). Never rename it.
        showAltUpgrades = false,

        -- Hide crafts that have hit their posted limit rather than showing
        -- them greyed out.
        hideAtPostLimit = true,

        -- The craft pane's "Ignore max on hand" box: list every craft and let
        -- Add queue past the Keep in stock limit, without changing the limit.
        craftPaneIgnoreLimit = false,

        -- Side panels folded down to their title strip by the small button at
        -- their top left (UI/Collapse.lua). Remembered between sessions.
        postPanelCollapsed = false,
        craftPaneCollapsed = false,

        -- Count what is sitting in the mailbox as stock you own.
        --
        -- An expired auction comes back as mail, and until it is collected it
        -- is in neither your auctions nor your bags -- so without this the
        -- addon will tell you to craft more of something already on its way
        -- home. Off only if the mailbox reading ever misbehaves.
        countMailAsStock = true,

        -- How hard already owning some of an item pushes it down the Profit
        -- list. The rank is profit divided by (1 + stock * this), so 1 means a
        -- single one already held roughly halves a craft's place and 0 turns
        -- the whole thing off. Stock covers listed, bags, bank, mailbox and
        -- the craft queue.
        --
        -- There is no cap to configure anywhere: a second copy only sells once
        -- the first has, so it is genuinely worth less right now, and that is
        -- something the addon can work out for itself.
        stockPenalty = 1,

        -- Rows whose price data is older than this are rendered as stale.
        staleAfterSeconds = 48 * 3600,

        -- Hides crafts earning less than this, and does a second job on item
        -- auctions: those only take whole silver, so the smallest undercut
        -- available is a whole silver rather than a copper. That silver is
        -- only given up when the sale would still clear this. At zero, any
        -- craft still in profit undercuts.
        minProfit = 0,
        minMarginPercent = 0,

        -- Deals, Merchant's Favor: leave bundles needing more than one stack
        -- of a material out of the cheapest, as Forever could not fill a
        -- crate from them when last reported (UI/DealsFavor.lua).
        favorSkipOverStack = true,

        -- Deals, Merchant's Favor: the favor goal (2026-10-20), typed on
        -- the tab as "favorGoal", nil until one is set. The auction house
        -- drawer's Favors switch shows only while there is one. Never
        -- rename it.

        -- Ready to sell at the auction house: leave out the rows at a loss
        -- (UI/PostPanel.lua, "Hide losses"). Off until ticked.
        postHideLosses = false,
        -- Profit by method's headings folded away, their keys comma apart
        -- (a player asked, the owner said yes from a mockup, 2026-10-22).
        -- Never rename it.
        salesMethodsFolded = "",

        -- Deals, Craftsman's Writs: the reputation goal the panel works
        -- towards (UI/DealsWrits.lua).
        writGoal = "honored",

        scanBudgetMs = 8,

        -- Scan automatically when the auction house opens and the price
        -- data is missing or stale. On a client that loses saved data
        -- between sessions this is what makes the addon self-sufficient.
        autoScan = true,

        -- Read prices out of the searches the player runs in Blizzard's own
        -- auction house UI, as well as the addon's scans. The client announces
        -- every search result the same way whoever asked for it, so this costs
        -- no request and no throttle budget -- it is purely reading answers
        -- that have already arrived. Off puts the addon back to learning only
        -- from its own scans.
        learnFromSearches = true,

        -- Write what one of each recipe sells for into Blizzard's own
        -- profession window, beside the recipe's name. Off leaves that window
        -- exactly as the client draws it. Off unless ticked since the owner
        -- asked (2026-10-20); a save that already has it on keeps it.
        showValueInProfessionWindow = false,

        -- Put what an item is worth on the auction house onto the item's
        -- own tooltip, wherever the game draws one. Off leaves every
        -- tooltip exactly as the client writes it.
        showValueOnItemTooltips = true,

        -- The sales lines under Demand on an item's tooltip (sold a day,
        -- listed now, the last seven days, what you sold this week) show
        -- only while Shift is held. Off shows them always. See
        -- UI/ItemTooltip.lua.
        tooltipSalesShift = false,

        -- The price trend (asked 2026-10-14): market value now against its
        -- average over the last 7 or 14 days, as the Prices tab's TREND
        -- column and a line on the item tooltip. Never rename either.
        priceTrendDays = 7,
        tooltipTrend = true,

        -- On a recipe item's tooltip (a Pattern, Plans, Formula...): what it
        -- teaches, what one craft costs, sells and disenchants for, and how
        -- many crafts pay the recipe back. See Logic/RecipeBook.lua.
        showRecipeValueOnTooltips = true,

        -- On an enchant's tooltip (asked 2026-10-14): what its materials
        -- cost, each one, what you're short and who knows it. See
        -- UI/EnchantTooltip.lua. Never rename it.
        tooltipEnchantCosts = true,

        -- On a Waylaid Crate's tooltip (2026-10-20): what fills it, what that
        -- costs, what it pays back and a favor's price. See
        -- UI/ItemTooltip.lua. Never rename it.
        tooltipCrateCosts = true,

        -- Off, Shift or Always for each tooltip line (asked 2026-10-18):
        -- true keeps that line for while Shift is held. Whether a line is on
        -- stays in its own setting above, and the sales lines' Shift is
        -- tooltipSalesShift. See UI/TooltipShift.lua. Never rename them.
        tooltipValueShift = false,
        tooltipTrendShift = false,
        tooltipRecipeShift = false,
        tooltipEnchantShift = false,
        tooltipCrateShift = false,

        -- A green arrow on the icon of any gear that is an upgrade for the
        -- character playing, as Blackthornes Equipment judges it. Does
        -- nothing without Equipment. See Logic/Upgrades.lua.
        showUpgradeArrows = true,

        -- How much the windows move, as Farmer's /farm effects: "full"
        -- (windows fade up and glow as they open, hovers ease, the tab line
        -- glides), "subtle" (shorter fades, nothing rises) or "off"
        -- (everything lands at once). See Motion in UI/Widgets.lua.
        windowEffects = "full",

        -- How big the main window is drawn, 1 being its normal size: a
        -- player on a 4K screen found it too big and wanted room for other
        -- windows beside it (2026-10-07). Set by dragging the corner below
        -- its bottom right, the Settings tab or /bts size. See UI/Main.lua.
        windowScale = 1,

        -- Text size: "normal", "large" (+1 point) or "larger" (+2), inside
        -- a window of the same size. Read at login, so a change waits for
        -- /reload. See Theme.TextStep in UI/Theme.lua.
        textSize = "normal",

        -- Window style: "titanforged" (the house look) or "blizzard" (the
        -- game's own frames, buttons and tabs, asked 2026-10-10). Read at
        -- login, so a change waits for /reload. See UI/BlizzardLook.lua.
        windowStyle = "titanforged",

        -- Whether each setting's description sits under it on the Settings
        -- tab rather than in its tooltip (2026-10-08). The page showing
        -- there is kept too (settingsPage), but is not a setting to reset.
        settingsDescriptions = false,

        -- Play a sound the moment the game says one of your auctions has
        -- sold, wherever you are. See Logic/SaleAlarm.lua.
        saleAlarm = true,
        -- Which sound it plays (asked 2026-10-11): "register" (an old cash
        -- register), "coins" (the game's loot coins) or "raid" (the raid
        -- warning it always played). Off is saleAlarm above.
        saleSound = "register",

        -- Say in chat when a profession cooldown (a transmute, Mooncloth,
        -- the Salt Shaker) comes ready on any character, and give Butler a
        -- step for it (asked 2026-10-12). See Logic/Cooldowns.lua.
        cooldownAlerts = true,
        -- The Stats tab cheers an item's best week of sales, once (UI/Tab_Stats.lua).
        statsCheer = true,

        -- Goblin Gold (asked 2026-10-17): a bar with the gold on every
        -- character of this realm and side, and a goal to cheer toward.
        -- Off unless ticked. Its sound, its size (percent) and where it
        -- sits. The goal is goldGoals in the saved data. Never rename these.
        -- See Logic/GoldGoal.lua and UI/GoldGoal.lua.
        goldTracker = false,
        goldTrackerSound = true,
        goldTrackerScale = 100,
        goldTrackerX = nil,
        goldTrackerY = nil,
        -- Transparent (asked 2026-10-19): 0 (off) to 3, Some, More or Most.
        goldTrackerSeeThrough = 0,
        -- Count Gold On (asked 2026-10-21): "all" characters of this realm
        -- and side, or only the "character" playing.
        goldTrackerCount = "all",

        -- Say in chat when someone in Trade asks for something one of the
        -- characters makes (asked 2026-10-12). See Logic/CraftRequests.lua.
        tradeRequests = false,

        -- Pins on the world map at vendors that sell what the queue needs
        -- for less than the auction house (asked 2026-10-18). See
        -- Logic/VendorPins.lua.
        vendorMapPins = false,

        -- Learn next on the Level Up tab (2026-10-12): recipes not learned
        -- yet that raise the skill now, under the ones known.
        levelUpLearnNext = true,
        -- Level Up's "Can afford" (2026-10-22): only crafts whose missing
        -- materials the gold carried can buy. Never rename it.
        levelUpCanAfford = false,

        -- Keep the game's "A buyer has been found for your auction" lines out
        -- of chat. The sale still goes into the Sales tab (Data/Mail.lua's
        -- heard sales), so nothing is lost. Off unless the player turns it on.
        hideSaleChat = false,

        -- After collecting mail, a report of what came in: the gold counting
        -- up, the best sale, what came back, and a fanfare on a new record.
        -- Also the running tally over the mailbox. See UI/MailReport.lua.
        mailReport = true,

        -- The sounds that play when an auction house scan finishes: the scan
        -- itself, and the Disenchanting and Vendor Flips finds after it. Off
        -- keeps the scan silent; the chat lines and the bar still show.
        scanSounds = true,

        -- Every other sound the addon makes has its own switch under SOUNDS
        -- in Settings, all on to start with (2026-10-02: "make sure
        -- all sound effects can be disabled in settings, on by default").
        -- The fanfare as the mail report counts up, and on a new record.
        mailReportSound = true,
        -- The chime when a disenchant turns up something new or lucky.
        disenchantSound = true,
        -- The cheer when Set goal makes a Farmer goal.
        goalSound = true,
        -- Farmer goals made with Set goal move with the queue, and go
        -- when nothing queued needs them (Logic/FarmerGoals.lua).
        farmerGoalsFollowQueue = true,
        -- The coin when another character can make a material for less.
        altCraftSound = true,
        -- Open the window when the auction house or a vendor opens, and close
        -- it again when they close. Off: the window stays as you left it.
        openWithShops = false,

        -- A chime when a run of crafts (two or more) finishes.
        craftDoneSound = true,
        -- A warning when your bags fill up. See Logic/BagsFull.lua.
        bagsFullSound = true,

        -- Slots Take next batch leaves free (2026-10-05). See
        -- Logic/BagsFull.lua. Vendor buys were batched the same way until
        -- 2026-10-06, when that was taken out; its saved fitBuysToBags is
        -- left in players' data, unread.
        bagSpareSlots = 5,
        -- A Take next batch button at the mailbox, taking the queue's
        -- materials a bagful at a time. Off by default (2026-10-05).
        mailBatchTake = false,
        -- Take sales/expired/cancelled/all and the Tradeskills mailbox
        -- shipped in 0.38.0 and were taken out on 2026-10-08 until they are
        -- tested more (they covered the game's Send Mail tab). Their saved
        -- mailTakeButtons and mailReplace are left in players' data, unread.

        -- Queue tab: a Disenchant next button aimed at the next item the
        -- queue made on DE (2026-10-07). Off until the player turns it on.
        queueDisenchantNext = false,

        -- The vendor window's Sell marked button, for items the queue made
        -- on Vendor (2026-10-07). It only shows when something is marked.
        sellMarkedButton = true,
        -- Picking a material the Buy list searched for fills the auction
        -- house's quantity box with what the queue still needs (2026-10-06).
        -- See UI/BuyQuantity.lua.
        fillBuyQuantity = true,
        -- Offer the auction house for a material a vendor sells without a
        -- stock limit when it is listed for less (2026-10-13). Off: the
        -- shopping list sends you to the vendor. See Vendor:KeepsInStock.
        vendorItemsOnAuction = false,
        -- A warning line on the auction house's buy window when buying a
        -- queue material costs this many percent more than the shopping list
        -- said (2026-10-11). 0 turns it off. See UI/BuyQuantity.lua.
        buyWarnPercent = 25,

        -- When a reagent is cheaper to craft than to buy, queue that craft
        -- too rather than only saying so.
        autoQueueSubCrafts = true,

        -- Craft next makes the ready craft that frees the most bag slots
        -- first, sub-crafts still before what they go into (2026-10-14).
        -- See Crafting:PickNext.
        craftFreesSpaceFirst = true,

        -- Point out a material another of your characters can make for less
        -- than it costs to buy. Only a suggestion; the queue still buys it, so
        -- it is on by default. Named anew when the default changed, so a false
        -- the old default wrote into saved settings does not keep it off.
        suggestOtherCharacters = true,

        -- Give a sub-craft to whichever of your characters makes it for
        -- less, and keep track of who makes what for whom across them all.
        -- Off by default (2026-10-03: "the cross character crafting
        -- needs to be optional. the addon just recommends crafting on the
        -- other character"): off, each character plans only its own and
        -- the shopping list recommends the other character. Named anew
        -- when the default changed, so the testing build's saved true for
        -- shareQueueWithAlts does not keep it on.
        queueAltCrafting = false,

        -- At the mailbox, list what to send your other characters for the
        -- queue, with a button that fills in the mail.
        queueMailPanel = true,

        -- The character gear goes to for disenchanting (2026-10-04),
        -- typed in Settings: any name, so a character on another account
        -- works too. Empty: the alt with the most Enchanting, picked for
        -- the player (QueueMail:GuessDisenchanter, 2026-10-11), unless
        -- disenchanterGuess is off; then nobody.
        disenchanterName = "",
        disenchanterGuess = true,
        -- The best quality mailed to them: 2 greens only, 3 greens and
        -- blues, 4 up to purples.
        disenchanterQuality = 2,

        -- The shopping list under the queued crafts beside the profession
        -- window. Hidden and shown with the button at its foot.
        craftPaneShoppingList = true,

        -- How the mark on a craft that both skills you up and pays is drawn:
        -- "star" is the addon's own art, "raid" the game's raid-target star,
        -- "pip" a plain gold square for a client that draws neither. Switched
        -- in game with /bts star, because whether a texture resolves is the
        -- one thing that cannot be checked outside it.
        skillUpMarker = "star",

        -- What the Profit tab's profit is for (2026-10-06): "best"
        -- for whichever of the auction house, a vendor and disenchanting
        -- pays most, or "auction", "vendor" or "disenchant" alone. Picked on
        -- the tab's option bar; /bts top and /bts why follow it.
        profitBy = "best",

        -- The Prices tab shows only starred items (2026-10-06).
        pricesFavouritesOnly = false,

        -- The price graph (2026-10-06): "day" for the last 24
        -- hours, "week" for 7 days, "fortnight" for 14 (2026-10-14). And whether the Profit tab's craft pane
        -- shows the graph where the materials list goes.
        priceGraphWindow = "day",
        profitShowsGraph = false,

        -- The Profit tab's TIME and GOLD/HR columns (asked 2026-10-09),
        -- from its "Per hour" tick box.
        profitShowsPerHour = false,

        -- The columns a player hid (asked 2026-10-09): "list.key" for each,
        -- separated by commas. Empty shows every column. Right-click a
        -- list's headings, or Settings, Look & sound. See UI/Columns.lua.
        hiddenColumns = "",

        -- Sharing (asked 2026-10-07 on Discord). Characters on
        -- another account of yours, by name and separated by commas; empty
        -- shares nothing. Both sides add each other. See Logic/AccountLink.lua.
        linkNames = "",
        -- What this account sends them. Each side chooses its own.
        linkShareRecipes = true,
        linkShareBags = true,
        linkShareGold = true,
        linkShareAuctions = true,
        -- Share scans with guildmates and fill gaps with theirs. On by
        -- default (the owner, 2026-10-07). See Logic/GuildPrices.lua.
        guildPrices = true,
        -- Tell the guild which recipes this character knows, and show who
        -- online can make a craft (a player asked, the owner said guild
        -- only, 2026-10-24). Off unless ticked; never rename it. See
        -- Logic/GuildCrafters.lua.
        guildCrafters = false,
        -- Friends' character names, with commas (the owner, 2026-10-25).
        -- Their data stays apart: never in your Characters list, only
        -- "Friends who can make it" on the Profit tab. Never rename it.
        -- See Logic/GuildCrafters.lua.
        friendNames = "",
        -- Share scans with players on your realm over a hidden channel, and
        -- fill what is still missing with theirs (2026-10-20). On unless
        -- unticked for new saves (the owner, 2026-10-28); a value already
        -- saved is kept. Never rename it. See Logic/RealmPrices.lua.
        realmPrices = true,
        -- Send your own disenchant results and recipe skills to the
        -- addon's maker (2026-10-18). Off unless ticked; never rename it.
        -- See Logic/Contribute.lua.
        shareData = false,
        -- Fill gaps with TradeSkillMaster's prices when it is loaded (asked
        -- 2026-10-12). See Logic/TSMPrices.lua.
        tsmPrices = true,
        -- Then Auctionator's (asked 2026-10-12). See Logic/AuctionatorPrices.lua.
        auctionatorPrices = true,
        -- Which of the two fills a gap first (the owner, 2026-10-25): "tsm"
        -- or "auctionator". Never rename it.
        priceOrder = "tsm",
    },

    -- realmKey -> itemID -> price record
    prices = {},

    -- characterKey -> { name, realm, faction, class, professions, inventory, gold }
    characters = {},

    -- Persisted craft queue.
    queue = {},

    -- characterKey -> "spell:N" or "item:N" -> { name, group, readyAt,
    -- recipeID or itemID, told }: profession cooldowns. Never rename it.
    -- See Logic/Cooldowns.lua.
    professionCooldowns = {},

    -- Things to buy rather than make, put on the shopping list by
    -- Blackthornes Equipment's Queue it button: { itemID, count, forItem,
    -- owner, addedAt }. Never rename it. See Queue:EnsureBuy.
    queueBuys = {},

    -- Auction deposits per item, learned at the auction house so profit can
    -- account for them anywhere.
    deposits = {},

    -- Per-item posted caps, and what is currently listed per realm.
    postLimits = {},
    postedAuctions = {},

    -- [a profession's English name] = Keep in stock for its crafts, between
    -- an item's own number and maxPostedPerItem (2026-10-13). Account wide;
    -- never rename it. See Auctions:GetLimit.
    professionStockLimits = {},

    -- recipeID -> the craft's name: crafts the player told the Profit tab to
    -- stop recommending. Account wide; the name is kept so Settings can list
    -- one the character playing does not know. See Profit:SetIgnored.
    ignoredCrafts = {},

    -- recipeID -> the craft's name: crafts never made to go into another
    -- craft, their item bought instead (2026-10-07). Account wide,
    -- the name kept for Settings. See Cost:SetNeverSubCraft.
    neverSubCrafts = {},

    -- recipeID -> the craft's name: crafts always made to go into another
    -- craft, whatever buying costs (2026-10-13, Make on the Level Up tab).
    -- Account wide. See Cost:SetSubCraftChoice.
    alwaysSubCrafts = {},

    -- itemID -> the item's name: items the player told Ready to sell to stop
    -- offering. Account wide; the name is kept so Settings can list one the
    -- client has not loaded. See Posting:SetIgnored.
    ignoredSellItems = {},

    -- itemID -> the item's name: items starred on the Prices tab to keep an
    -- eye on. Account wide. See Prices:SetFavourite.
    favouritePrices = {},

    -- realmKey -> itemID -> { price, mode, name }: prices the player set
    -- on the Prices tab, used instead of the auction price ("use") or as
    -- the least it can be ("floor"). See Prices:SetMine.
    myPrices = {},

    -- realmKey -> itemID -> { hour, copper, hour, copper, ... }: the cheapest
    -- price each hour a scan saw it, for fourteen days, for what the account
    -- crafts, its materials and starred items. Drawn as the price graph.
    -- See Data/PriceHistory.lua.
    priceHistory = {},

    -- realmKey -> itemID -> { hour, count, ... }: how many were listed each
    -- hour a scan saw it, same items and fourteen days as priceHistory. Drawn
    -- as the volume bars under the price line.
    priceListed = {},

    -- realmKey -> { entries, seen }: what sold and what came back, read out of
    -- the mailbox. See Data/Mail.lua.
    mailLedger = {},

    -- realmKey -> list of { t, name, itemID, who }: sales the game announced
    -- in chat while you were online, shown on the Sales tab until their mail
    -- is read and the ledger has the real entry. See Mail:NoteHeardSale.
    heardSales = {},

    -- realmKey -> itemID -> { cost, at }: what one cost to make the last time
    -- it was crafted, and when. See Logic/CraftedCost.lua.
    craftedCosts = {},

    -- realmKey -> itemID -> { price, at }: the price one last went up at.
    lastPosted = {},

    -- realmKey -> { hours = { [hourStart] = bucket }, days = { [YYYYMMDD] =
    -- bucket } }, a bucket being { [source] = { i, o } }: gold in and out by
    -- where it came from or went. No character names. See Logic/GoldLog.lua.
    goldLog = {},

    -- recipeID -> { name, outputItemID, quantityMin, quantityMax,
    -- skillLineID, profession, reagents, seenAt }: every recipe a profession
    -- window has shown on this account, learned or not. Overrides the
    -- shipped Classic recipe book where Forever differs. No character names.
    -- See Logic/RecipeBook.lua.
    seenRecipes = {},

    -- recipe item ID -> { skill, profession, teaches, at }: the skill a
    -- recipe item's own tooltip says it needs. Forever moved some from
    -- Classic's, and this wins over the shipped book. Game IDs and numbers
    -- only. See RecipeBook:LearnSkill.
    recipeSkills = {},

    -- realmKey -> when the history restored from macro storage was rolled up
    -- to. Ledger entries from before that moment are already inside it. See
    -- Mail:GetRestoredRollup.
    sellThroughRolledAt = {},

    -- itemID -> true when the auction house sells it by the unit. Learned from
    -- the client when one is held and from searches otherwise; it never
    -- changes for an item, so it is kept. See Scanner:GetCommodityStatus.
    commodity = {},

    -- characterKey -> itemID -> { action = "disenchant" | "vendor", count }:
    -- items the queue made for those actions, never more than are carried.
    -- See Logic/QueueActions.lua.
    queueMarks = {},

    -- What the selling test at a vendor found: { at, result }. See
    -- UI/SellMarked.lua.
    sellTest = {},

    -- What Waylaid Crates were seen to be and to pay in game: crate item IDs
    -- found by name, which sealed crate each kind fills into, and each
    -- sealed crate's Merchant's Favor and money. No character names. See
    -- Logic/MerchantsFavor.lua.
    -- Craftsman's Writs are kept here too: writ item IDs found by name, and
    -- the reputation each level of writ was seen to pay, per character GUID
    -- (a racial bonus can change it). See Logic/Writs.lua.
    merchantsFavor = {
        crateIDs = {},
        links = {},
        rewards = {},
        writIDs = {},
        writRewards = {},
    },

    -- Written by Core/Compat.lua and Probe/Probe.lua.
    probe = {
        loadCount = 0,
        canary = nil,
        lastReport = nil,
    },
}

Config.DEFAULTS = DEFAULTS

--------------------------------------------------------------------------------
-- Keys
--------------------------------------------------------------------------------

-- A plain, non-empty string, or nil. The test and the copy happen inside the
-- pcall: logging in or reloading inside a dungeon can hand back a name the
-- addon may not compare or join, and the character key would raise forever.
local function PlainString(fn, ...)
    local ok, value = pcall(function(...)
        local v = fn(...)
        if type(v) == "string" and v ~= "" then return v .. "" end
    end, ...)
    if ok then return value end
    return nil
end

local function SafeUnitName()
    return PlainString(UnitName, "player") or "Unknown"
end

local function SafeRealmName()
    if type(GetRealmName) == "function" then
        return PlainString(GetRealmName) or "UnknownRealm"
    end
    return "UnknownRealm"
end

local function SafeFaction()
    -- Copied inside the pcall like the name: a faction handed back as a
    -- secret value would raise at the join below on every call.
    local faction = PlainString(UnitFactionGroup, "player")
    return faction or "Neutral", faction == nil
end

--- Prices are per realm AND per faction: a neutral AH still prices differently
--- across factions on split-auction realms, and merging them would be wrong.
function Config:GetRealmKey()
    if self.realmKey then return self.realmKey end

    local faction, factionUnread = SafeFaction()
    local key = SafeRealmName() .. "-" .. faction

    -- Not remembered while the realm could not be read (a /reload inside a
    -- dungeon can do that): the whole session's prices and mail would have
    -- gone under "UnknownRealm", apart from everything saved before. The
    -- next call tries the real name again.
    -- Likewise a faction that could not be read: "Realm-Neutral" is an empty
    -- bucket for anyone who is not actually Neutral.
    if key:find("^UnknownRealm%-") or factionUnread then return key end

    self.realmKey = key
    return key
end

-- Checked and copied inside the pcall for the same dungeon reason as the name.
local function SafeGUID()
    local ok, guid = pcall(function()
        local v = UnitGUID("player")
        if type(v) == "string" and v ~= "" then return v .. "" end
    end)
    if ok then return guid end
    return nil
end

--- How characters used to be filed: first name and realm. Saved data from
--- then stays under this key until its character next logs in.
function Config:GetLegacyCharacterKey()
    return SafeUnitName() .. "-" .. SafeRealmName()
end

--- Forever lets any number of characters share a first name; only the first
--- and last name together are unique. Name and realm therefore filed
--- "Bob Ash" and "Bob Stone" as one character. The character's GUID is
--- unique and never changes, so it is the key now: the one way a character
--- is named in saved data (see "One key per character" in CLAUDE.md).
---
--- The game has always handed the GUID over by PLAYER_LOGIN. Asked any
--- earlier, or when it hands back a value that cannot be read (a /reload
--- inside a dungeon), the GUID this character's own file remembers from an
--- earlier session answers; only a character that never had one gets the old
--- key, and that is not remembered.
function Config:GetCharacterKey()
    if self.characterKey then return self.characterKey end

    local charDb = type(ns.charDb) == "table" and ns.charDb or nil
    local guid = SafeGUID()
    if guid and charDb then charDb.guid = guid end
    if not guid and charDb and type(charDb.guid) == "string" and charDb.guid ~= "" then
        guid = charDb.guid
    end
    if not guid or not ns.db then
        return self:GetLegacyCharacterKey()
    end

    self.characterKey = guid
    self:AdoptLegacyCharacter(guid)
    return guid
end

local function SameText(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return nil end
    return a:gsub("%s", ""):lower() == b:gsub("%s", ""):lower()
end

--- Could `old`, a record under the old name-realm key, be this character's?
--- One stamped with another GUID, from another account, or whose class,
--- faction or last name differs from this character's record is somebody
--- else's. `mine` is this character's record, or nil when it has none yet.
local function MightBeMine(old, mine, guid)
    if old.guid ~= nil then return old.guid == guid end
    if old.linkedFrom ~= nil then return false end
    if type(mine) ~= "table" then return true end
    for _, field in ipairs({ "class", "faction", "surname", "realm" }) do
        if SameText(old[field], mine[field]) == false then return false end
    end
    return true
end

--- Point every reference to `from` in the queue at `to`: who queued an
--- entry, who makes it and who it is for. A few dozen entries at most, once.
local function Repoint(from, to)
    for _, entry in ipairs(type(ns.db.queue) == "table" and ns.db.queue or {}) do
        if type(entry) == "table" then
            if entry.owner == from then entry.owner = to end
            if entry.crafter == from then entry.crafter = to end
            local forCharacters = entry.forCharacters
            if type(forCharacters) == "table" and forCharacters[from] ~= nil then
                forCharacters[to] = forCharacters[to] or forCharacters[from]
                forCharacters[from] = nil
            end
        end
    end
    for _, line in pairs(type(ns.db.queueBuys) == "table" and ns.db.queueBuys or {}) do
        if type(line) == "table" and line.owner == from then line.owner = to end
    end
end

local function FoldName(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if text == "" then return nil end
    return text:lower()
end

--- Is `old`, saved under `key`, an old record of this character? Records
--- were once keyed by first name and realm, and some carry the whole name
--- ("Ana Blackthorne") or sit under a key the legacy one no longer matches,
--- so the key alone cannot say. A GUID key is a character of its own; a
--- record already stamped is this one only with this GUID; otherwise the
--- name it carries (or its key's) must be this character's first name, or
--- first and last together, and MightBeMine must agree.
local function OldRecordOfMine(key, old, mine, guid, names, legacy)
    if key == guid or type(key) ~= "string" or type(old) ~= "table" then return false end
    if key:find("^Player%-") then return false end
    if old.guid ~= nil then return old.guid == guid end
    if old.linkedFrom ~= nil or old.retiredInto ~= nil then return false end
    local name = FoldName(old.name) or FoldName(key:match("^([^-]+)"))
    if key ~= legacy and not (name and names[name]) then return false end
    return MightBeMine(old, mine, guid)
end

--- Move `old` (saved under `from`) to `formerCharacters`, kept whole.
local function Retire(from, old, mine, guid)
    if type(ns.db.formerCharacters) ~= "table" then ns.db.formerCharacters = {} end
    local former = ns.db.formerCharacters
    local slot, n = from, 1
    while former[slot] ~= nil do
        n = n + 1
        slot = from .. "#" .. n
    end

    if old.guid == guid then
        for field, value in pairs(old) do
            if mine[field] == nil then mine[field] = value end
        end
    end
    old.retiredInto = guid
    old.retiredAt = type(time) == "function" and time() or nil
    former[slot] = old
    ns.db.characters[from] = nil
    Repoint(from, guid)
end

--- Bring this character's record under its GUID, the first time the key is
--- known each session and again once its name is stamped. Nothing is ever
--- deleted:
---
--- * Only an old record under the legacy key: it moves to the GUID, as it
---   always has.
--- * An old record beside the GUID one (the cause of a player being told to
---   mail Medium Leather to the character they were on, and of Butler
---   filling a mail to itself, 2026-10-11; and of a tooltip counting a
---   character's old bags as another character's, 2026-10-12): whatever key
---   it sits under, it moves to `formerCharacters[old key]` (never rename
---   it), kept whole and marked `retiredInto = guid`, so every list of
---   characters has this one once. When it was stamped with this GUID,
---   anything the GUID record lacks is filled from it, and the queue's
---   references to the old key follow.
---
--- An old record that is somebody else's (OldRecordOfMine) is left where it is.
function Config:AdoptLegacyCharacter(guid)
    local characters = ns.db and ns.db.characters
    if type(characters) ~= "table" or type(guid) ~= "string" then return end

    local legacy = self:GetLegacyCharacterKey()
    local mine = characters[guid]
    local old = legacy ~= guid and characters[legacy] or nil
    if mine == nil and type(old) == "table" and MightBeMine(old, nil, guid) then
        old.guid = guid
        characters[guid] = old
        characters[legacy] = nil
        Repoint(legacy, guid)
        self.adoptedFrom = legacy
        self:FoldOthersOldRecords()
        return
    end
    if type(mine) ~= "table" then
        self:FoldOthersOldRecords()
        return
    end

    local names = {}
    local first = FoldName(mine.name) or FoldName(SafeUnitName())
    if first then names[first] = true end
    local surname = FoldName(mine.surname)
    if first and surname then names[first .. " " .. surname] = true end

    local found = {}
    for key, record in pairs(characters) do
        if OldRecordOfMine(key, record, mine, guid, names, legacy) then found[#found + 1] = key end
    end
    table.sort(found)
    for _, key in ipairs(found) do
        Retire(key, characters[key], mine, guid)
        self.retiredFrom = self.retiredFrom and (self.retiredFrom .. ", " .. key) or key
    end

    self:FoldOthersOldRecords()
end

--- An old record saved under a whole name ("Ana Blackthorne") is another
--- character's, not this one's: until that character logs in, its old bags
--- would be counted beside its GUID record. When exactly one GUID record
--- has that first and last name (and no realm, side or class that differs),
--- the old record is set aside into it as well, kept whole. A first name
--- alone could be any of several characters, so it waits for its own login.
function Config:FoldOthersOldRecords()
    local characters = ns.db and ns.db.characters
    if type(characters) ~= "table" then return end

    local byName = {}
    for key, record in pairs(characters) do
        if type(key) == "string" and key:find("^Player%-") and type(record) == "table"
            and record.linkedFrom == nil then
            local first, surname = FoldName(record.name), FoldName(record.surname)
            if first and surname then
                local whole = first .. " " .. surname
                byName[whole] = byName[whole] or {}
                table.insert(byName[whole], key)
            end
        end
    end

    local found = {}
    for key, old in pairs(characters) do
        if type(key) == "string" and not key:find("^Player%-") and type(old) == "table"
            and old.guid == nil and old.linkedFrom == nil then
            local name = FoldName(old.name)
            local owners = name and name:find(" ", 1, true) and byName[name]
            if owners and #owners == 1 and MightBeMine(old, characters[owners[1]], owners[1]) then
                found[#found + 1] = { key = key, guid = owners[1] }
            end
        end
    end
    table.sort(found, function(a, b) return a.key < b.key end)
    for _, it in ipairs(found) do
        Retire(it.key, characters[it.key], characters[it.guid], it.guid)
        self.retiredFrom = self.retiredFrom and (self.retiredFrom .. ", " .. it.key) or it.key
    end
end

--- The last name, when the game will say what it is.
---
--- Nothing documents how Forever hands a last name to addons, so this looks
--- in the likely places: any name the unit functions return that starts with
--- the first name and a space, then any getter whose name mentions a last,
--- secondary or surname. `/bts whoami` shows what each of them said.
local SURNAME_PATTERNS = { "surname", "secondaryname", "lastname" }

function Config:FindSurnameFunctions()
    local found = {}

    local function Consider(label, name, fn)
        if type(fn) ~= "function" or type(name) ~= "string" then return end
        local lower = name:lower()
        if not (lower:find("^get") or lower:find("^unit")) then return end
        for _, pattern in ipairs(SURNAME_PATTERNS) do
            if lower:find(pattern, 1, true) then
                found[#found + 1] = { label = label, fn = fn }
                return
            end
        end
    end

    pcall(function()
        for name, value in pairs(_G) do
            Consider(name, name, value)
        end
        if type(C_PlayerInfo) == "table" then
            for name, value in pairs(C_PlayerInfo) do
                Consider("C_PlayerInfo." .. name, name, value)
            end
        end
    end)

    table.sort(found, function(a, b) return a.label < b.label end)
    return found
end

local function SurnameFrom(first, value)
    if type(value) ~= "string" or value == "" then return nil end
    local rest = value:match("^" .. first:gsub("%p", "%%%0") .. " (.+)$")
    if rest and rest ~= "" then return rest end
end

--- @return surname or nil, and a list of { label, values } describing what was asked
function Config:ReadSurname()
    local first = SafeUnitName()
    local asked, surname = {}, nil

    local function Ask(label, fn, ...)
        if type(fn) ~= "function" then
            asked[#asked + 1] = { label = label, missing = true }
            return
        end
        local results = { pcall(fn, ...) }
        local values = {}
        for i = 2, #results do
            -- Inside a dungeon a name can come back as a value that raises
            -- when read; such a one is noted as that and passed over.
            local readable, text = pcall(function() return tostring(results[i]) .. "" end)
            values[#values + 1] = readable and text or "(secret)"
        end
        asked[#asked + 1] = { label = label, ok = results[1], values = values }

        if not results[1] or surname then return end
        for i = 2, #results do
            local readable, found = pcall(SurnameFrom, first, results[i])
            if readable and found then surname = found return end
        end
    end

    Ask("UnitName", UnitName, "player")
    Ask("UnitFullName", UnitFullName, "player")
    Ask("GetUnitName", GetUnitName, "player", true)

    for _, candidate in ipairs(self:FindSurnameFunctions()) do
        local before = surname
        Ask(candidate.label, candidate.fn, "player")

        -- A getter named for the last name may return it bare.
        local last = asked[#asked]
        if not before and not surname and last.ok then
            local value = last.values[1]
            if value and value ~= "nil" and value ~= "(secret)" and value ~= first
                and not value:find("[%s%-]") then
                surname = value
            end
        end
    end

    return surname, asked
end

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------

--- Called from the ADDON_LOADED handler before any module initialises.
function Config:Bootstrap()
    -- First, before Compat's capability detection registers and writes CVars
    -- of its own: this records the client's state at login rather than the
    -- state we left it in on the way past.
    if ns.Persist then ns.Persist:Peek() end

    -- Recorded before anything is touched, so a failure to load can be told
    -- apart from a failure to save. Without this the two look identical
    -- from the outside.
    local existing = type(_G.BlackthornesTSDB)

    self.loadDiagnostics = {
        globalType = existing,
        hadProbe = existing == "table" and type(_G.BlackthornesTSDB.probe) == "table",
        loadCountSeen = existing == "table"
            and _G.BlackthornesTSDB.probe
            and _G.BlackthornesTSDB.probe.loadCount or nil,
    }

    if existing ~= "table" then
        -- The client handed back nothing: a first run, or a client that loses
        -- the saved file. Since build 1.60.1.70009 the game keeps it, so this
        -- is the rare case. The CVar store still covers a /reload on a client
        -- that does lose it.
        local stored = ns.Persist and ns.Persist:LoadAll()

        if stored then
            _G.BlackthornesTSDB = stored

            self.restoredFromCVars = true
            self.loadDiagnostics.restoredFromCVars = true
        else
            _G.BlackthornesTSDB = {}
            self.freshDatabase = true
        end
    end

    -- Per-character saved variables are a separate file and a separate code
    -- path in the client. The account-level one demonstrably does not load
    -- on this build; whether this one does is worth knowing, because the
    -- queue and settings could live here instead.
    local existingChar = type(_G.BlackthornesTSCharDB)

    self.loadDiagnostics.charGlobalType = existingChar
    self.loadDiagnostics.charCanarySeen =
        existingChar == "table" and _G.BlackthornesTSCharDB.canary or nil

    if existingChar ~= "table" then
        _G.BlackthornesTSCharDB = {}
    end

    -- Neither file came back and there was no backup: the addon has never
    -- saved anything here. Real loss looks different, because the
    -- per-character file remembers the account one (CheckAccountDataLost).
    self.loadDiagnostics.firstRun =
        self.freshDatabase == true and existingChar ~= "table" or nil

    -- Stamped every login so the next one can tell whether it survived.
    _G.BlackthornesTSCharDB.canary = (_G.BlackthornesTSCharDB.canary or 0) + 1

    local db = _G.BlackthornesTSDB

    self:Migrate(db)
    Util.ApplyDefaults(db, DEFAULTS)

    ns.db = db
    ns.charDb = _G.BlackthornesTSCharDB

    -- Kept so OnEnable can tell whether the client replaced the global after
    -- we installed ours. One report from another addon on this build has the
    -- saved table arriving late rather than never; if that happens here, this
    -- is what notices instead of quietly running on an empty database beside
    -- a full one.
    self.installedDB = db

    self:StampCanary(db)
    self:CheckAccountDataLost(db)
    self:StampCVarCanary()

    -- The CVar canary counts logins apart from both saved files. Found set,
    -- the addon has run here before, so this is lost data and not a first
    -- run: the welcome would be the wrong thing to say.
    if self.cvarResult and self.cvarResult.persisted then
        self.loadDiagnostics.firstRun = nil
    end

    -- After the defaults are in place, so a mirrored value wins over its
    -- default, and after the canary, which establishes whether CVars work.
    if ns.Persist then
        ns.Persist:RestoreSettings()
        ns.Persist:CheckSoak()
    end

    self:SisterKeepsOffOnce(db)
end

--- "Keep What Other Addons Need" was on by default for a day (2026-10-16)
--- before the owner asked for it off unless ticked. The default was copied
--- into the save, so it is turned off once, and the save says so
--- (`sisterKeepsOffOnce`, never rename it). A player who ticks it again
--- keeps it.
function Config:SisterKeepsOffOnce(db)
    if type(db) ~= "table" or db.sisterKeepsOffOnce then return end
    db.sisterKeepsOffOnce = true
    if type(db.settings) == "table" and db.settings.sellHoldsSisterKeeps ~= false then
        ns.db = ns.db or db
        self:Set("sellHoldsSisterKeeps", false)
    end
end

function Config:OnEnable()
    self:CheckLateSavedVariables()

    if self:IsFirstRun() and C_Timer and C_Timer.After then
        C_Timer.After(6, function() Config:Welcome() end)
    end

    -- A few seconds in, so it is not lost in the login chat.
    if self.accountDataLost and C_Timer and C_Timer.After then
        C_Timer.After(6, function() Config:WarnAccountDataLost() end)
    end
end

--- Is this the first time the addon has run here, with nothing ever saved?
function Config:IsFirstRun()
    local diagnostics = self.loadDiagnostics or {}
    return diagnostics.firstRun == true and not self.accountDataLost
end

--- A first run has no saved data because there never was any, which is not
--- something to warn about.
function Config:Welcome()
    ns.Print(L.Format("type |c%s/bts|r to open the window, or |c%s/bts help|r for the commands.",
        ns.COLORS.accent, ns.COLORS.accent))
    ns.Print(L["Open each profession once and visit the auction house to fill in recipes and prices."])
end

--- Did the account-wide saved file come back with fewer sessions in it than
--- this character remembers it having?
--
-- The account-wide file holds prices, recipes, the queue and the sales
-- history. The per-character file is separate, so it can remember how many
-- sessions the account-wide one had last time. If that file comes back empty
-- or older, the data did not load, and it is not a fresh install: a new
-- character remembers nothing, so it never warns.
--
-- The loss is kept until the data comes back or the player says to start
-- fresh, so it is not forgotten after the one session where the empty file
-- got saved over the old one.
function Config:CheckAccountDataLost(db)
    local charDb = _G.BlackthornesTSCharDB
    if type(charDb) ~= "table" then return end

    local loadsNow = (db.probe and db.probe.loadCount) or 0
    local remembered = tonumber(charDb.accountLoads)

    -- The player has started fresh (/bts db fresh) since this character last
    -- looked, so what it remembers is the data he already let go. Without
    -- this, every other character raised the warning again on its next login.
    -- Only a fresh start newer than the one this character took: an older
    -- copy of the file brought back still carries an older one, and it is
    -- as much a loss as any.
    local freshAt = tonumber(db.probe and db.probe.freshAt)
    local isNewer = freshAt ~= nil and freshAt > (tonumber(charDb.accountFreshAt) or 0)
    if isNewer then
        remembered = nil
    end

    if remembered and loadsNow <= remembered then
        self.accountDataLost = { remembered = remembered, now = loadsNow - 1 }
        return
    end

    charDb.accountLoads = loadsNow
    if isNewer then charDb.accountFreshAt = freshAt end
end

--- Loud on purpose: every logout or /reload saves the file, and the game
--- keeps only one older copy, so the second save after a loss overwrites the
--- last good copy.
function Config:WarnAccountDataLost()
    local lost = self.accountDataLost
    if not lost then return end

    ns.Warn(L["YOUR SAVED DATA DID NOT LOAD. Prices, recipes, your queue and sales history are missing this session."])
    ns.Warn(L.Format("This character remembers %d sessions of it; the game handed back %d.",
        lost.remembered, math.max(0, lost.now)))
    ns.Warn(L["To get it back: quit the game now, without a /reload first. Then open your World of Warcraft game folder, then WTF, Account, your account name and SavedVariables, and copy Blackthornes_TS.lua.bak over Blackthornes_TS.lua. Then start the game."])
    ns.Warn(L["Do this before you log out a second time: each save replaces the .bak with the newer, empty file."])
    ns.Warn(L["If you meant to start fresh, type /bts db fresh and this warning stops."])

    local frame = _G.UIErrorsFrame
    if type(frame) == "table" and type(frame.AddMessage) == "function" then
        pcall(frame.AddMessage, frame, L["Blackthornes Tradeskills: your saved data did not load. See chat."], 1, 0.3, 0.3, 1)
    end

    if type(PlaySound) == "function" then
        local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
        pcall(PlaySound, kits.RAID_WARNING or 8959, "Master")
    end
end

--- Did the client hand the saved table back after ADDON_LOADED?
--
-- Worth a look because it would change everything: if the saved variables are
-- late rather than absent, none of the rest of this is needed. It is reported
-- and never acted on -- swapping the live database out from under modules
-- that already hold a reference would be a worse bug than the one it fixes.
function Config:CheckLateSavedVariables()
    local current = _G.BlackthornesTSDB

    if type(current) == "table" and self.installedDB and current ~= self.installedDB then
        self.loadDiagnostics.lateSavedVariables = true

        -- The saved data did exist, it only arrived late, so this is no
        -- first run. Left set, the welcome printed beside this warning.
        self.loadDiagnostics.firstRun = nil

        ns.Warn(L["the game loaded your saved data late, after login instead of at load. Please report this, then run /bts persist."])
    end
end

--- Schema migrations. Each step upgrades one version to the next.
function Config:Migrate(db)
    local from = db.schema

    if from == nil then
        -- Either a brand new database or a pre-versioning one. Nothing to move.
        db.schema = Config.SCHEMA_VERSION
        return
    end

    if from > Config.SCHEMA_VERSION then
        ns.Warn(L.Format("your saved data is from a newer version of the addon (format %d, this version reads %d), so it's being left alone",
            from, Config.SCHEMA_VERSION))
        return
    end

    -- Future migrations land here as: if db.schema == 1 then ... db.schema = 2 end

    db.schema = Config.SCHEMA_VERSION
end

--------------------------------------------------------------------------------
-- Persistence canary
--------------------------------------------------------------------------------

--- Record whether the previous session's write survived, then stamp a new one.
function Config:StampCanary(db)
    local probe = db.probe or {}
    db.probe = probe

    local previous = probe.canary

    self.persistenceResult = {
        sawPrevious = previous ~= nil,
        previousStamp = previous and previous.stamp or nil,
        previousSession = previous and previous.session or nil,
        loadCountBefore = probe.loadCount or 0,
    }

    probe.loadCount = (probe.loadCount or 0) + 1
    probe.canary = {
        stamp = time(),
        session = probe.loadCount,
        version = ns.VERSION,
    }
end

--- The same canary again, but in a CVar rather than a saved variable.
--
-- Run because the two persist by different paths in the client: this build
-- writes SavedVariables and never reads them back, and if CVars survive a
-- logout they are somewhere to keep settings. Reading the old value before
-- writing the new one is what makes the answer meaningful.
local CVAR_CANARY = "BTS_sessionCount"

function Config:StampCVarCanary()
    local capable = ns.Compat and ns.Compat:Detect().cvars
    self.cvarResult = { supported = false }

    if not capable or not capable.roundTrip then return end

    self.cvarResult.supported = true

    -- Read before registering. Registering a name the client has not seen
    -- since launch can write the default over whatever it loaded, and this
    -- canary is precisely the thing that would then read as "never survived"
    -- when it had. See the note at the top of Core/Persist.lua.
    local raw = ns.Persist and ns.Persist.ReadRaw and ns.Persist.ReadRaw(CVAR_CANARY)
    local count = tonumber(raw or "") or 0

    if capable.registerVia == "RegisterAddonCVar" then
        pcall(C_CVar.RegisterAddonCVar, CVAR_CANARY)
    elseif capable.registerVia == "RegisterCVar" then
        pcall(C_CVar.RegisterCVar, CVAR_CANARY, "0")
    end

    if count == 0 then
        local ok, previous = pcall(C_CVar.GetCVar, CVAR_CANARY)
        count = (ok and tonumber(previous)) or 0
    end

    -- Zero means either a first run or a value that did not survive; those
    -- are the same observation from here, and the probe says so rather than
    -- claiming the mechanism is broken on the strength of one login.
    self.cvarResult.previousCount = count
    self.cvarResult.persisted = count > 0

    pcall(C_CVar.SetCVar, CVAR_CANARY, tostring(count + 1))
end

--- { supported, persisted, previousCount }
function Config:GetCVarResult()
    return self.cvarResult or { supported = false }
end

--- { sawPrevious, previousStamp, previousSession, loadCountBefore }
function Config:GetPersistenceResult()
    return self.persistenceResult
end

--- What the saved-variable global looked like at load time.
function Config:GetLoadDiagnostics()
    return self.loadDiagnostics or {}
end

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

function Config:Get(key)
    return ns.db and ns.db.settings and ns.db.settings[key]
end

function Config:Set(key, value)
    if not ns.db then return end
    ns.db.settings[key] = value
    -- Counted, so a list built from the settings can tell one changed.
    Config.changes = (Config.changes or 0) + 1

    -- Mirrored out immediately rather than at logout: this client loses the
    -- saved file, and a setting only survives if the CVar is already written
    -- by the time the session ends.
    if ns.Persist then ns.Persist:SaveSetting(key, value) end
end

function Config:GetPriceTable()
    local realmKey = self:GetRealmKey()

    local prices = ns.db.prices
    if not prices[realmKey] then
        prices[realmKey] = {}
    end
    return prices[realmKey]
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

ns.RegisterCommand("db", L["show what saved data loaded (/bts db fresh: stop the missing data warning)"], function(args)
    -- Starting over on purpose: this session's data is the data from now on.
    if (args or ""):lower():match("^%s*fresh") then
        local charDb = _G.BlackthornesTSCharDB
        if type(charDb) == "table" and ns.db and ns.db.probe then
            charDb.accountLoads = ns.db.probe.loadCount or 0

            -- Marked in the account-wide file as well, so the player's other
            -- characters take the fresh start too. A time rather than a
            -- flag: after another loss and another fresh start, characters
            -- that took the first one have to take this one as well.
            ns.db.probe.freshAt = time()
            charDb.accountFreshAt = ns.db.probe.freshAt
        end
        ns.Config.accountDataLost = nil
        ns.Print(L["starting fresh, so the missing saved data warning won't show again."])
        return
    end

    local diagnostics = ns.Config:GetLoadDiagnostics()

    ns.Print("saved data")
    local source = ""
    if diagnostics.restoredFromCVars then
        source = "  (recovered from CVars)"
    end

    ns.PrintRaw(("  saved data type: %s%s"):format(
        tostring(diagnostics.globalType), source))
    ns.PrintRaw(("  loads before:    %s"):format(tostring(diagnostics.loadCountSeen)))
    ns.PrintRaw(("  loads now:       %s"):format(tostring(ns.db.probe.loadCount)))
    ns.PrintRaw(("  prices:          %d item(s)"):format(ns.Prices:Count()))
    ns.PrintRaw(("  recipes:         %d"):format(ns.Recipes:Count()))
    ns.PrintRaw(("  queue:           %d craft(s)"):format(ns.Queue:Count()))
    ns.PrintRaw(("  characters:      %d"):format(ns.Util.Count(ns.db.characters)))

    ns.PrintRaw(("  per-character:   %s, test value %s"):format(
        tostring(diagnostics.charGlobalType),
        tostring(diagnostics.charCanarySeen or "none")))

    if ns.Config:IsFirstRun() then
        ns.Print("first time the addon has run here, so there was no saved data to load yet.")
    elseif diagnostics.globalType ~= "table" then
        -- This client loses saved variables every session, so saying so on its
        -- own reads as data loss when the fallback has in fact just done its
        -- job. Say which of the three sources the database came from, because
        -- "nothing was handed back" and "nothing was recovered" are very
        -- different situations and only the second one is a problem.
        if diagnostics.restoredFromCVars then
            ns.Print("the game lost your saved data; it was recovered from CVars.")
        else
            ns.Warn("the game did not load any saved data this session,")
            ns.Warn("and nothing was recovered. This session starts empty.")
        end

        if diagnostics.charCanarySeen then
            ns.Print("|cff4fd18bper-character saved data DID load|r, so the queue could be kept there.")
        end
    end
end)

ns.RegisterCommand("whoami", L["show what the game says this character is called"], function()
    local Config = ns.Config
    local key = Config:GetCharacterKey()
    local surname, asked = Config:ReadSurname()

    ns.Print("this character")
    ns.PrintRaw(("  saved as:        %s"):format(key))
    ns.PrintRaw(("  old style key:   %s"):format(Config:GetLegacyCharacterKey()))
    ns.PrintRaw(("  last name found: %s"):format(surname or "none"))

    if Config.adoptedFrom then
        ns.PrintRaw(("  moved saved data from %s this session"):format(Config.adoptedFrom))
    end
    if Config.retiredFrom then
        ns.PrintRaw(("  folded the old record %s into this one this session"):format(Config.retiredFrom))
    end

    local realmOk, realm = pcall(GetRealmName)
    ns.PrintRaw(("  GetRealmName:    %s"):format(realmOk and tostring(realm) or "error"))

    for _, entry in ipairs(asked) do
        local answer
        if entry.missing then
            answer = "not in this client"
        elseif not entry.ok then
            answer = "error"
        elseif #entry.values == 0 then
            answer = "nothing"
        else
            answer = table.concat(entry.values, ", ")
        end
        ns.PrintRaw(("  %s: %s"):format(entry.label, answer))
    end

    local sameName = 0
    local first = key and ns.db.characters[key] and ns.db.characters[key].name
    for _, record in pairs(ns.db.characters) do
        if first and record.name == first then sameName = sameName + 1 end
    end
    ns.PrintRaw(("  saved characters with this first name: %d"):format(sameName))
end)

ns.RegisterCommand("debug", L["turn extra chat detail on or off"], function()
    if not ns.db then return end

    ns.db.global.debug = not ns.db.global.debug
    ns.Print(ns.db.global.debug and L["extra chat detail on"] or L["extra chat detail off"])
end)
