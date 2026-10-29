-- Blackthornes Tradeskills -- UI/CraftPanel.lua
-- The craft queue pane, docked beside Blizzard's profession window.
--
-- Queueing already worked from the Profit tab, but that means leaving the
-- window you are actually crafting in, finding the recipe again in a table of
-- several hundred, and coming back. This pane puts the same queue beside the
-- profession window instead: the recipes that window is showing, what each one
-- is worth, a number, and a button.
--
-- It is a second view of the one queue in Logic/Queue.lua, not a queue of its
-- own. Anything added here appears on the Queue tab, feeds the shopping list
-- and is crafted by the same Craft next button.
--
-- Deliberately beside Blizzard's window rather than inside ours, for the same
-- reason the sell list sits beside the auction house: the decision to make
-- something is taken while looking at the profession, and a list behind
-- another frame may as well not exist.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local CraftPanel = ns.NewModule("CraftPanel")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

-- Wide enough for a recipe name beside a quantity box and a button. Recipe
-- names on this client run long ("Heavy Scorpid Bracers"), so the name gets
-- its own line and the numbers sit under it. The - and + buttons and the
-- quantity box between them sit on the name's line, so the line under it can run the full width of the
-- row: at 322 wide with the buttons beside it, that line was cut off on
-- almost every recipe.
local PANEL_WIDTH = 350
local ROW_HEIGHT = 30

-- Four digits fit (2026-10-05): at 34 an amount of 100 or more lost a digit.
local QUANTITY_WIDTH = 42

-- The - and + buttons either side of the quantity box, and the gap between
-- each button and the box.
local STEP_WIDTH = 18
local STEP_GAP = 3

-- Both step buttons and their gaps: everything beside the box.
local BUTTON_WIDTH = STEP_WIDTH * 2 + STEP_GAP * 2

-- The Craft button left of the -, shown only on rows with something queued.
local CRAFT_WIDTH = 36
local CRAFT_GAP = 5
local CRAFT_INSET = CRAFT_WIDTH + CRAFT_GAP

-- Right margin, the buttons and box, gap before the text.
local TEXT_INSET = 8 + BUTTON_WIDTH + QUANTITY_WIDTH + 14

-- Clear of the profession window's bevelled edge without opening a gap you
-- could see the world through.
local PANEL_GAP = 6

-- The two buttons at the bottom right, and how long Clear queue waits for its
-- second click.
local QUEUE_TAB_WIDTH = 64
local CLEAR_WIDTH = 84
local CLEAR_CONFIRM_SECONDS = 4

-- Only used when Blizzard's profession window cannot be found at all.
local PANEL_FALLBACK_HEIGHT = 460

-- Short enough to still show a few rows, for a profession window smaller than
-- the pane wants to be.
local PANEL_MIN_HEIGHT = 220

-- Remembers whether the pane is folded down to its title (UI/Collapse.lua).
local COLLAPSE_KEY = "craftPaneCollapsed"

-- Candidate globals for Blizzard's profession window. This client's
-- C_TradeSkillUI is the modern one, so ProfessionsFrame is expected, but the
-- name is not worth assuming -- and both frames are load-on-demand, so the
-- global can be absent on the first open of a session.
local TRADE_SKILL_FRAME_NAMES = { "ProfessionsFrame", "TradeSkillFrame" }

-- Exposed so a test can hold the row geometry to its own promise: the text
-- must stop clear of every control standing to its right.
CraftPanel.TEXT_INSET = TEXT_INSET
CraftPanel.QUANTITY_WIDTH = QUANTITY_WIDTH
CraftPanel.BUTTON_WIDTH = BUTTON_WIDTH
CraftPanel.CRAFT_INSET = CRAFT_INSET
CraftPanel.PANEL_GAP = PANEL_GAP

--------------------------------------------------------------------------------
-- Blizzard's window
--------------------------------------------------------------------------------

--- Locate Blizzard's profession window, whatever it is called on this client.
--
-- Read only, and never assigned to: taking a reference to a Blizzard frame to
-- anchor against is fine, writing one back is what taints the UI.
function CraftPanel:FindTradeSkillFrame()
    for _, name in ipairs(TRADE_SKILL_FRAME_NAMES) do
        local frame = _G[name]

        -- Guard against a global that exists but is not a frame.
        if type(frame) == "table" and frame.GetObjectType then
            local ok = pcall(frame.GetObjectType, frame)
            if ok then return frame, name end
        end
    end
end

--- How far past its own right edge a frame's visible children reach.
--
-- Blizzard hangs the profession tabs off the right-hand side of the profession
-- window, as child frames anchored outside their parent's rectangle. GetRight()
-- reports the window, not the tabs, so docking at TOPRIGHT + a small gap parks
-- this pane straight on top of them -- which is what it did.
--
-- Measured rather than guessed at with a bigger fixed gap: the tabs are only
-- there for a character with more than one profession, and a constant wide
-- enough to clear them would strand the pane in open space for everyone else.
--
-- Only visible children count, and the result is capped: one stray child
-- anchored far away should not push the pane off the side of the screen.
local MAX_OVERHANG = 120

-- How deep to look for them. Asked 2026-10-04: the pane still covered the
-- tabs to pick a profession. A window can hold its tabs in a container of
-- their own, whose rectangle sits inside the window while the tabs in it
-- hang out, so the window's own children said nothing stood out. Their
-- children are looked at too, and theirs, but only frames that start at the
-- window's right edge: something wider than a scroll area inside the window
-- is not a tab.
local OVERHANG_DEPTH = 3
local EDGE_SLACK = 60
local MAX_FRAMES_LOOKED_AT = 400

-- Guarded: GetChildren is not worth assuming on a client with API gaps,
-- and a pane that fails to dock is worse than one docked a little close.
local function Children(frame)
    if type(frame) ~= "table" or type(frame.GetChildren) ~= "function" then return {} end
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if ok and type(children) == "table" then return children end
    return {}
end

local function Number(frame, method)
    if type(frame[method]) ~= "function" then return nil end
    local ok, value = pcall(frame[method], frame)
    if ok and type(value) == "number" then return value end
end

function CraftPanel:RightOverhang(tradeSkillFrame)
    local right = tradeSkillFrame:GetRight()
    if not right then return 0 end

    local top, bottom = Number(tradeSkillFrame, "GetTop"), Number(tradeSkillFrame, "GetBottom")

    local overhang, looked = 0, 0

    local function Visit(frame, depth)
        for _, child in ipairs(Children(frame)) do
            looked = looked + 1
            if looked > MAX_FRAMES_LOOKED_AT then return end

            if type(child) == "table" and child.GetRight and child.IsShown then
                local shownOk, shown = pcall(child.IsShown, child)
                local childRight = Number(child, "GetRight")

                if shownOk and shown then
                    -- The window's own children count as they always have;
                    -- deeper ones only when they start at its edge and sit
                    -- beside it, not above or below.
                    local counts = depth == 1
                    if not counts and childRight then
                        local left = Number(child, "GetLeft")
                        local childTop, childBottom = Number(child, "GetTop"), Number(child, "GetBottom")
                        counts = left ~= nil and left >= right - EDGE_SLACK
                            and (not top or not childBottom or childBottom < top)
                            and (not bottom or not childTop or childTop > bottom)
                    end

                    if counts and childRight then
                        overhang = math.max(overhang, childRight - right)
                    end

                    if depth < OVERHANG_DEPTH then Visit(child, depth + 1) end
                end
            end
        end
    end

    Visit(tradeSkillFrame, 1)

    return math.min(math.max(overhang, 0), MAX_OVERHANG)
end

--- As tall as the profession window it is docked to.
--
-- Returns nil while the frame has no screen coordinates yet, which is what a
-- frame that has never been laid out reports -- an attach that early has to
-- fall back rather than set a height of nil.
function CraftPanel:DesiredHeight(tradeSkillFrame)
    local top, bottom = tradeSkillFrame:GetTop(), tradeSkillFrame:GetBottom()

    if not top or not bottom then return nil end

    return math.max(top - bottom, PANEL_MIN_HEIGHT)
end

--------------------------------------------------------------------------------
-- What to show
--------------------------------------------------------------------------------

--- The recipe IDs the open profession window is showing, as a set.
--
-- Returns nil when the client will not answer, which means "no opinion" rather
-- than "nothing": the caller then falls back to every cached recipe instead of
-- showing an empty pane. GetAllRecipeIDs only answers while a profession
-- window is open, which is exactly when this pane exists.
function CraftPanel:GetOpenRecipeIDs()
    -- Era: what the open old windows' professions can make, and nothing for
    -- a window that is no profession (Beast Training).
    local era = ns.Crafting and ns.Crafting.EraWindows and ns.Crafting.EraWindows()
    if era then
        if not ns.Crafting.isTradeSkillOpen then return nil end
        return era:OpenRecipeIDs() or {}
    end

    local api = _G.C_TradeSkillUI
    if not api or type(api.GetAllRecipeIDs) ~= "function" then return nil end

    local ok, ids = pcall(api.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" or #ids == 0 then return nil end

    local set = {}
    for _, recipeID in ipairs(ids) do
        set[recipeID] = true
    end

    return set
end

--- Sort comparators, kept total so two runs over the same data agree.
--
-- `pairs` hands recipes back in whatever order the table feels like, so a
-- comparator that can call two different rows equal produces a list that
-- reshuffles itself every refresh. Every tie falls through to the recipe ID.
local SORTS = {
    profit = function(a, b)
        -- Priced crafts first: an unpriced one has no position in a profit
        -- order, and burying them under a zero would be a lie about the money.
        if a.priceable ~= b.priceable then return a.priceable end

        -- By the profit each the row shows. It went by RankOf's stock-weighted
        -- number, so a row saying 2g each could sit above one saying 5g each
        -- and the list read as not sorted at all (a player's report,
        -- 2026-10-18). Crafts at their Keep in stock limit are left out of the
        -- list already, which is what the weighting was mostly there for.
        if a.priceable and a.profit ~= b.profit then
            return a.profit > b.profit
        end

        -- Two that pay the same: the one you hold fewer of first.
        if a.priceable and a.rank ~= b.rank then
            return a.rank > b.rank
        end

        if a.name ~= b.name then return a.name < b.name end
        return a.recipeID < b.recipeID
    end,

    name = function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.recipeID < b.recipeID
    end,

    -- The Level Up tab's order, so the two agree: orange, yellow, green,
    -- then cheapest materials first. Its comparator reads `tier` and `cost`.
    levelup = function(a, b)
        local compare = ns.LevelUp and ns.LevelUp.Compare
        if compare then
            return compare(
                { tier = a.skillUpTier, cost = a.materialCost, name = a.name, recipeID = a.recipeID },
                { tier = b.skillUpTier, cost = b.materialCost, name = b.name, recipeID = b.recipeID })
        end

        if a.name ~= b.name then return a.name < b.name end
        return a.recipeID < b.recipeID
    end,
}

-- What the sort button steps through, and what it says for each.
local SORT_ORDER = { "profit", "levelup", "name" }
local SORT_LABEL = { profit = L["Profit"], levelup = L["Level Up"], name = L["A-Z"] }

CraftPanel.SORT_ORDER = SORT_ORDER

--- What a craft is worth *right now*, as against what one sells for.
--
-- The pane was sorting on raw profit, so a craft with nine already sitting on
-- the auction house ranked level with an identical one you hold none of. It is
-- not: the tenth only sells once the other nine have, so the gold comes back
-- roughly ten times slower. The Profit tab has ranked this way since the stock
-- penalty landed, and two lists answering "what should I make next" in
-- different orders is worse than either order on its own.
--
-- Guarded rather than called outright so the pane still draws if the profit
-- engine is ever loaded without it.
local function RankOf(analysis)
    if not analysis then return -math.huge end

    local rank = ns.Profit and ns.Profit._RankValue
    if rank then return rank(analysis, "profit") end

    return analysis.profit or -math.huge
end

--- How much room the limit leaves, counted in crafts rather than in units.
--
-- The limit is a number of items, but this pane queues crafts, and one craft
-- can produce several items. Clamping a craft count against a unit count is how
-- a limit of ten turns into fifty Rough Sharpening Stones.
--
-- Rounded down, with a floor of one: a limit with any room left in it should
-- never refuse the smallest thing you can actually make.
--
-- Profit works the same figure out, and the two panes have to agree about the
-- same recipe, so its answer is preferred and this is the fallback for a
-- caller holding a recipe but no analysis.
local function RoomInCrafts(room, recipe)
    if ns.Profit and ns.Profit.RoomInCrafts then
        return ns.Profit.RoomInCrafts(room, recipe)
    end

    if room == nil then return nil end
    if room <= 0 then return 0 end

    local perCraft = math.max(1, (recipe and recipe.quantityMin) or 1)

    return math.max(1, math.floor(room / perCraft))
end

--- How the pane counts profit: the Profit tab's "Profit:" choice, one
--- setting for both (a player asked, the owner said build it, 2026-10-24).
--- Auction stays the sale it always counted (Profit:Analyse with no
--- method), so picking it puts the pane back as it was.
-- @return "best", "vendor", "disenchant", or nil for the sale alone
local function PaneMethod()
    local Profit = ns.Profit
    local method = Profit and Profit.GetMethod and Profit:GetMethod() or nil
    if method == "auction" then return nil end
    return method
end

CraftPanel.PaneMethod = PaneMethod

--- What the rows are read from: the search, the recipes the open window
--- shows, and what is cached for them.
local function RowSources(self, opts)
    local search = (opts.search or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local open = self:GetOpenRecipeIDs()

    local list = {}
    for recipeID, recipe in pairs(ns.Recipes:GetAll()) do
        -- Only what this profession window is showing, when it will say. The
        -- cache spans every profession the character has opened this session,
        -- and a tailoring list beside the blacksmithing window is noise.
        if not open or open[recipeID] then
            list[#list + 1] = { recipeID = recipeID, recipe = recipe }
        end
    end
    return list, search
end

--- One recipe's row, or nil when it is left out. `tally` counts what the
--- Keep in stock limit and the ignored crafts hid.
local function RowFor(recipeID, recipe, opts, search, tally)
    local name = recipe.name or L.Format("recipe %s", tostring(recipeID))

    -- A craft the player ignored (here or on the Profit tab, one list) is
    -- not suggested. A search still finds it, as it finds a craft at its
    -- Keep in stock limit: someone typing its name wants that one.
    if search == "" and ns.Profit.IsIgnored and ns.Profit:IsIgnored(recipeID) then
        tally.ignored = (tally.ignored or 0) + 1
        return nil
    end

    -- Plain substring, not a pattern: a recipe name with a hyphen in
    -- it would otherwise be a malformed pattern and match nothing.
    if search == "" or name:lower():find(search, 1, true) then
        local method = opts.method
        if method == nil and opts.methodRead == nil then method = PaneMethod() end
        local analysis = ns.Profit:Analyse(recipeID, nil, method)
        local _, queued = ns.Queue:Find(recipeID, true)

        local atLimit = (analysis and analysis.atPostLimit) == true

        -- Already holding as many as the limit in Settings allows.
        -- Suppressed here by the same setting as on the Profit tab,
        -- because the pane's whole job is answering "what should I
        -- make next" and a craft you have enough of is not an answer.
        --
        -- A search is not a suggestion, though: someone typing a name
        -- is looking for that one recipe, and hiding the thing they
        -- just named would read as the pane having lost it.
        --
        -- Nor is a row already on screen: queueing up to the limit
        -- would otherwise make the row vanish under the cursor.
        local suppressed = atLimit
            and search == ""
            and not opts.ignoreLimit
            and not (opts.keepOrder and opts.keepOrder[recipeID])
            and ns.Config:Get("hideAtPostLimit") ~= false

        if suppressed then
            tally.hiddenAtLimit = tally.hiddenAtLimit + 1
        else
            return {
                recipeID = recipeID,
                name = name,
                outputItemID = recipe.outputItemID,
                priceable = (analysis and analysis.priceable) == true,
                profit = (analysis and analysis.profit) or 0,

                -- Which way the profit is for, and what each way makes,
                -- once the pane counts more than the sale.
                via = method and analysis and analysis.via or nil,
                ways = method and analysis and ns.Profit.DescribeWays
                    and ns.Profit:DescribeWays(analysis) or nil,

                -- Does it still skill you up, and is it worth a star.
                skillUpTier = analysis and analysis.skillUp
                    and analysis.skillUp.tier or nil,
                skillUpStale = analysis and analysis.skillUp
                    and analysis.skillUp.stale or nil,
                recommended = (analysis and analysis.recommended) == true,
                materialCost = analysis and analysis.cost
                    and analysis.cost.priceable and analysis.cost.total or nil,
                rank = RankOf(analysis),
                reason = analysis and analysis.reason or nil,
                soulbound = (analysis and analysis.soulbound) == true,
                craftable = ns.Profit:GetCraftableCount(recipeID) or 0,
                queued = (queued and queued.quantity) or 0,

                -- What you already hold of it, which is the number
                -- that was missing from this pane entirely.
                posted = (analysis and analysis.posted) or 0,
                stock = (analysis and analysis.stock) or 0,
                postLimit = (analysis and analysis.postLimit) or 0,
                atPostLimit = atLimit,
                waitingForLow = (analysis and analysis.waitingForLow) == true,
                restockAt = analysis and analysis.restockAt or nil,
                queuedElsewhere = (analysis and analysis.queuedElsewhere) or 0,
                roomInCrafts = RoomInCrafts(
                    analysis and analysis.postRoom, recipe),
            }
        end
    end
    return nil
end

--- The rows in the order chosen. Rows already on screen keep their places.
local function SortRows(rows, opts)
    local sort = SORTS[opts.sortBy] or SORTS.profit
    local keep = opts.keepOrder

    if keep then
        -- Rows already on screen keep their places; anything new goes after
        -- them, in the chosen order.
        table.sort(rows, function(a, b)
            local ka, kb = keep[a.recipeID], keep[b.recipeID]
            if ka and kb then return ka < kb end
            if ka or kb then return ka ~= nil end
            return sort(a, b)
        end)
    else
        table.sort(rows, sort)
    end

    return rows
end

--- The rows to draw: one per recipe, with what it is worth and what is queued.
--
-- @param opts { search, sortBy = "profit"|"levelup"|"name", ignoreLimit }
function CraftPanel:GetRows(opts)
    opts = opts or {}

    local list, search = RowSources(self, opts)
    local rows = {}
    -- How many were left out for being at the Keep in stock limit, so an
    -- empty pane can say that rather than blame the recipes not being read.
    local tally = { hiddenAtLimit = 0, ignored = 0 }

    for _, item in ipairs(list) do
        rows[#rows + 1] = RowFor(item.recipeID, item.recipe, opts, search, tally)
    end
    self.hiddenAtLimit = tally.hiddenAtLimit
    self.hiddenIgnored = tally.ignored

    return SortRows(rows, opts)
end

--- What the list's order was worked out for. While this stays the same, rows
--- keep their places.
--
-- Queueing a craft counts it as stock you will have, and the profit order
-- ranks a craft lower the more of it you have coming (see RankOf). So adding
-- a row to the queue used to drop it down the list the moment it was clicked.
-- The order is now worked out once and held until the sort, the search, the
-- Ignore max on hand box or the profession changes, or the pane closes.
function CraftPanel:OrderKey(opts)
    local open = self:GetOpenRecipeIDs()
    local count, sum = 0, 0
    for recipeID in pairs(open or {}) do
        count, sum = count + 1, sum + recipeID
    end

    return table.concat({ tostring(opts.sortBy), opts.search or "",
        tostring(opts.ignoreLimit), tostring(opts.method), count, sum }, "|")
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- Is the player part-way through typing a number into this box?
--
-- Guarded rather than called outright: this client has gaps in the frame API,
-- and a missing HasFocus would turn a redraw into an error.
local function BeingTyped(box)
    return box.editBox.HasFocus and box.editBox:HasFocus()
end

--- Whether a label's text runs past its width. False when it cannot be
--- measured, so nothing is shortened on a guess.
local function TooWide(label)
    local ok, width = pcall(label.GetStringWidth, label)
    if not ok or type(width) ~= "number" then return false end

    local room = label.GetWidth and label:GetWidth()
    return type(room) == "number" and room > 0 and width > room
end

--- Put the first of `texts` that fits on a label, or the last when none does.
local function SetFirstThatFits(label, texts)
    for index, text in ipairs(texts) do
        label:SetText(text)
        if index == #texts or not TooWide(label) then return end
    end
end

--- Is the "Ignore max on hand" box ticked?
function CraftPanel:IgnoringLimit()
    return ns.Config:Get("craftPaneIgnoreLimit") == true
end

--- Queue this many more of the row's recipe, within the Keep in stock limit.
local function QueueMore(line, quantity)
    quantity = math.max(1, math.floor(tonumber(quantity) or 1))

    -- The limit is the player's own answer to "how many of these do I want",
    -- so queueing past it is nearly always a slip -- and a slip that costs
    -- materials and a deposit, not just a wrong number on a screen. Said out
    -- loud either way: a button that silently queues fewer than asked for
    -- looks broken.
    -- Unless the player has ticked the box that says to ignore it.
    local room = not CraftPanel:IgnoringLimit() and line.roomInCrafts or nil

    -- Read again now rather than from the row: the pane redraws a moment
    -- after a change, and three quick clicks on + all saw the same room.
    local queuedNow = 0
    if room and line.outputItemID then
        local fresh, _, _, queued, _, _, waiting = ns.Auctions:GetRoom(line.outputItemID)
        queuedNow = queued or 0
        room = RoomInCrafts(fresh, ns.Recipes:GetAny(line.recipeID)) or room
        line.waitingForLow = waiting == true
        line.restockAt = waiting and ns.Auctions:GetRestockAt() or nil
    end

    if room then
        if room <= 0 then
            if line.waitingForLow then
                ns.Warn(L.Format("%s: you have %d (%d queued). Restock When Down To is on, so more are made once you are down to %d.",
                    line.name, (line.stock or 0) + queuedNow, queuedNow, line.restockAt or 0))
            elseif queuedNow > 0 then
                ns.Warn(L.Format("%s: you have %d and %d queued, which fills your limit of %d, so none were queued.",
                    line.name, line.stock or 0, queuedNow, line.postLimit or 0))
            else
                ns.Warn(L.Format("%s: you already have %d and your limit is %d, so none were queued.",
                    line.name, line.stock or 0, line.postLimit or 0))
            end
            return
        end

        if quantity > room then
            quantity = room
            ns.Print(L.Format("%s: queued %d. That fills your limit of %d.",
                line.name, quantity, line.postLimit or 0))
        end
    end

    ns.Queue:Add(line.recipeID, quantity)
    if ns.Demand then ns.Demand:WarnIfLow(line.outputItemID, line.name) end

    -- Until the next full refresh re-reads it, so quick clicks cannot run
    -- past the limit on a number read before the first of them.
    if line.roomInCrafts then line.roomInCrafts = line.roomInCrafts - quantity end
end

--- Set this recipe's own queue entry to exactly this many.
--
-- The box on each row shows how many are queued, so typing into it or
-- pressing - and + all come here. Only the entry the player queued is
-- changed. A sub-craft the queue added to make something else is sized from
-- that parent and would come straight back, so it is left alone and the
-- player is told where to change it instead.
function CraftPanel:SetQueued(line, wanted)
    wanted = math.max(0, math.floor(tonumber(wanted) or 0))

    local _, entry = ns.Queue:Find(line.recipeID, true)
    local current = entry and entry.quantity or 0

    if wanted > current then
        QueueMore(line, wanted - current)
    elseif wanted < current then
        -- SetQuantity takes the entry off the queue once it reaches zero.
        ns.Queue:SetQuantity(line.recipeID, wanted)
        if line.roomInCrafts then line.roomInCrafts = line.roomInCrafts + (current - wanted) end
    elseif not entry and wanted == 0 and ns.Queue:Find(line.recipeID) then
        ns.Print(L.Format("%s is only queued as a material for another craft. Queue fewer of that craft to need fewer.", line.name))
    end
end

--- The row's Craft button: make this recipe's queued crafts now.
--
-- A real click, so the game accepts it, the same as Craft next. One click
-- makes as many of the queued number as the bags have materials for.
function CraftPanel:CraftRow(line)
    if ns.Crafting:IsBusy() then
        ns.Crafting:Stop()
        self:Refresh()
        return
    end

    local _, entry = ns.Queue:Find(line.recipeID)
    if not entry then return end

    self:CraftEntry(entry)
end

--- Start one queue entry, from a row here or in the queued crafts list.
function CraftPanel:CraftEntry(entry)
    if ns.Crafting:IsBusy() then
        ns.Crafting:Stop()
    else
        ns.Crafting:Start(entry.recipeID, entry.quantity)
    end
    self:Refresh()
end

-- Room at the left of every row for the skill-up star, reserved whether one is
-- shown or not so the names stay in a straight line.
local MARK_GUTTER = 15

CraftPanel.MARK_GUTTER = MARK_GUTTER

local function CreateRow(row)
    -- The left inset clears the skill-up star's gutter; the right edge is
    -- anchored to the row rather than given a width worked out from
    -- PANEL_WIDTH. A row is not the panel's width: the list is inset 14 either
    -- side, and the scroll bar takes another 10 when it appears. The old sum
    -- came to 214 in a space 194 wide -- 184 with the bar -- so every recipe
    -- name and every detail line ran on underneath the quantity box and the
    -- Add button. Anchoring makes the width follow the row it is actually in,
    -- scroll bar and all, so the overrun cannot come back however the gutter
    -- on the left changes.
    row.mark = Theme.CreateMark(row)
    row.mark:SetPoint("TOPLEFT", 7, -4)

    -- The made item's icon at the start of the name line, as the bags draw it.
    row.icon = Theme.CreateItemIcon(row, 13)
    row.icon:SetPoint("TOPLEFT", 8 + MARK_GUTTER, -3)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("TOPLEFT", 8 + MARK_GUTTER + 17, -4)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -TEXT_INSET, -4)

    -- Full width: nothing stands to the right of this line any more, and it
    -- is the one that carries the numbers.
    row.detail = Theme.CreateLabel(row, "tiny", "muted")
    row.detail:SetPoint("TOPLEFT", 8 + MARK_GUTTER, -17)
    row.detail:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -17)

    -- Reads - [box] +, the way a number you nudge up and down usually looks.
    -- The box is how many are queued: + and - change it by one, or type the
    -- number you want.
    row.add = Widgets.CreateButton(row, "+", function()
        if row.data then QueueMore(row.data, 1) end
    end, { width = STEP_WIDTH, height = 15, primary = true })
    row.add:SetPoint("TOPRIGHT", -8, -1)

    row.quantity = Widgets.CreateNumberBox(row, {
        width = QUANTITY_WIDTH,
        height = 15,
        background = "panel",
        min = 0,
        max = 9999,
        onChange = function(value)
            if row.data then CraftPanel:SetQueued(row.data, value) end
        end,
    })
    row.quantity:SetPoint("RIGHT", row.add, "LEFT", -STEP_GAP, 0)

    row.remove = Widgets.CreateButton(row, "-", function()
        -- From the queue as it is now, not the row: a second quick click
        -- would otherwise ask for the same number again.
        if not row.data then return end
        local _, entry = ns.Queue:Find(row.data.recipeID, true)
        CraftPanel:SetQueued(row.data, (entry and entry.quantity or 0) - 1)
    end, { width = STEP_WIDTH, height = 15 })
    row.remove:SetPoint("RIGHT", row.quantity, "LEFT", -STEP_GAP, 0)

    -- Only on rows with something queued, so the names on the rest keep
    -- their room.
    row.craft = Widgets.CreateButton(row, L["Craft"], function()
        if row.data then CraftPanel:CraftRow(row.data) end
    end, { width = CRAFT_WIDTH, height = 15, primary = true })
    row.craft:SetPoint("RIGHT", row.remove, "LEFT", -CRAFT_GAP, 0)
    row.craft:Hide()
    -- An Era enchant is made by a secure button laid over this one.
    if ns.SecureCraft then
        ns.SecureCraft:Attach(row.craft, function()
            local _, entry = row.data and ns.Queue:Find(row.data.recipeID)
            if entry then return entry.recipeID, entry.quantity end
        end)
    end
end

--- How much of this you already have, as a phrase, or nil for none.
--
-- Listed is called out separately from the rest because the two mean different
-- things when deciding what to make: stock in your bags is ready to list, and
-- stock on the auction house is already competing with anything else you post.
-- @return phrase, and true when it already says how many are queued
local function StockText(line)
    local stock = line.stock or 0

    -- Nothing held says nothing: "have 0 of 5" on every row was most of what
    -- pushed the line off the end.
    if line.postLimit and line.postLimit > 0 and (stock > 0 or line.atPostLimit) then
        local text = L.Format("have %d of %d", stock, line.postLimit)
        -- Queued crafts count toward the limit too; without saying so,
        -- "have 0 of 5, at your limit" contradicted itself.
        if line.atPostLimit and line.waitingForLow then
            return L.Format("have %d, restock at %d",
                stock + (line.queuedElsewhere or 0), line.restockAt or 0), true
        end
        if line.atPostLimit and (line.queuedElsewhere or 0) > 0 then
            return L.Format("have %d, %d queued, limit %d", stock, line.queuedElsewhere, line.postLimit), true
        end
        if line.atPostLimit then return L.Format("%s, at your limit", text) end
        return text
    end

    if stock <= 0 then return nil end

    if line.postLimit and line.postLimit > 0 then return nil end

    if (line.posted or 0) > 0 then
        return L.Format("have %d, %d listed", stock, line.posted)
    end

    return L.Format("have %d", stock)
end

local function UpdateRow(row, line)
    row.name:SetText(line.name)
    Theme.SetItemIcon(row.icon, line.outputItemID)

    -- Not while it is being typed into: overwriting someone mid-number is how
    -- a field ends up refusing to accept what they meant.
    -- A reused row now showing another recipe drops the half-typed number,
    -- though: it was for the recipe that scrolled away, and pressing Enter
    -- would have queued that many of this one.
    if BeingTyped(row.quantity) and row.boundRecipeID ~= line.recipeID then
        row.quantity:SetValue(line.queued, true)
        row.quantity.editBox:ClearFocus()
    elseif not BeingTyped(row.quantity) then
        row.quantity:SetValue(line.queued, true)
    end
    row.boundRecipeID = line.recipeID

    -- A queued number stands out from the zeros around it.
    row.quantity.editBox:SetTextColor(Theme.Unpack(line.queued > 0 and "accent" or "dim"))

    -- The Craft button, and room for it on the name line, only while there
    -- is something of this queued.
    local canCraftRow = line.queued > 0
    row.craft:SetShown(canCraftRow)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT",
        -(TEXT_INSET + (canCraftRow and CRAFT_INSET or 0)), -4)

    if canCraftRow then
        local busy = ns.Crafting:IsBusy()
        local ready, reason = ns.Crafting:GetReadiness(line.recipeID)
        local open = CraftPanel:GetOpenRecipeIDs()
        local here = not open or open[line.recipeID]

        row.craft:SetText(busy and L["Stop"] or L["Craft"])
        row.craft:SetEnabledState(busy or (ready and here) or false)
        row.craft.tooltipText = busy and L["Stop crafting"]
            or not here and L["Open its profession to craft it"]
            or not ready and (reason or L["Nothing to make it with yet"])
            or L.Format("Craft the %d queued, as many as your materials make", line.queued)
    end

    -- Rarity, the same as the Profit tab and the sell list, so the three read
    -- alike. A recipe with no sellable output has no colour to take.
    local r, g, b = Util.GetItemQualityColor(line.outputItemID)

    if r then
        row.name:SetTextColor(r, g, b)
    else
        row.name:SetTextColor(Theme.Unpack("text"))
        if line.outputItemID then CraftPanel.awaitingItemData = true end
    end

    -- The star marks every recipe that can still level you, orange, yellow or
    -- green, the way the game's own list does, sized by how likely the point
    -- is. Here, beside the profession window, the question is often "what
    -- levels me" rather than "what pays", so the Profit tab's rule (a skill
    -- up that also pays) hid nearly every star. Grey never gets one.
    local tier = line.skillUpTier
    Theme.SetMark(row.mark, tier ~= "trivial" and tier or nil)

    -- What you already hold, listed or otherwise. This is the number the pane
    -- was missing: "9 listed" changes the answer to "what should I make next"
    -- more than anything else on the row does.
    local stockText, saysQueued = StockText(line)

    -- What it is worth, and whether you can make one right now: the two things
    -- that decide whether this recipe is the one you want.
    local function Detail(coins, withQueued)
        local parts = {}

        if line.priceable then
            local amount = Util.FormatMoney(line.profit, { noColor = true, short = true, parts = coins })
            -- A craft that makes money shows its amount in green, so it
            -- reads at once. The rest of the line keeps its colour.
            if line.profit > 0 and ns.COLORS and ns.COLORS.profit then
                amount = "|c" .. ns.COLORS.profit .. amount .. "|r"
            end
            -- Which way it is for, in the VIA column's words.
            local via = line.via and ns.Profit.WAY_LABELS and ns.Profit.WAY_LABELS[line.via]
            if via then
                parts[#parts + 1] = L.Format("%s each (%s)", amount, via)
            else
                parts[#parts + 1] = L.Format("%s each", amount)
            end
        elseif line.soulbound then
            -- The whole reason is in the tooltip; the row has room for one word.
            parts[#parts + 1] = L["soulbound"]
        else
            parts[#parts + 1] = line.reason or L["no price data"]
        end

        parts[#parts + 1] = line.craftable > 0
            and L.Format("can make %d", line.craftable)
            or L["no materials"]

        if stockText then parts[#parts + 1] = stockText end

        -- Once: at the limit the stock already says how many are queued, and
        -- the line said "queued" twice.
        if withQueued and line.queued > 0 and not saysQueued then
            parts[#parts + 1] = L.Format("queued %d", line.queued)
        end

        return table.concat(parts, " · ")
    end

    -- When the whole line runs past the row, the queued count goes first
    -- (the box beside the name shows it), then coins off the amount.
    SetFirstThatFits(row.detail, { Detail(nil, true), Detail(nil, false), Detail(2, false), Detail(1, false) })

    local limitApplies = line.atPostLimit and not CraftPanel:IgnoringLimit()

    if limitApplies then
        row.detail:SetTextColor(Theme.Unpack("warn"))
    elseif line.priceable and line.profit < 0 then
        row.detail:SetTextColor(Theme.Unpack("loss"))
    elseif line.queued > 0 then
        row.detail:SetTextColor(Theme.Unpack("accent"))
    else
        row.detail:SetTextColor(Theme.Unpack("muted"))
    end

    if limitApplies and line.waitingForLow then
        row.add.tooltipText = L.Format("You have %d %s. More are queued once you're down to %d. Tick Ignore max on hand to queue more now.",
            (line.stock or 0) + (line.queuedElsewhere or 0), line.name, line.restockAt or 0)
    elseif limitApplies then
        row.add.tooltipText = ((line.queuedElsewhere or 0) > 0
            and L.Format("You have %d %s and %d queued, which is your limit. Tick Ignore max on hand to queue more.",
                line.stock or 0, line.name, line.queuedElsewhere)
            or L.Format("You have %d %s, which is your limit. Tick Ignore max on hand to queue more.",
                line.stock or 0, line.name))
    else
        row.add.tooltipText = L.Format("Queue one more %s, or type how many in the box.", line.name)
    end

    -- Greyed out with nothing of this recipe's own in the queue, so the
    -- button never looks like it did something when it could not.
    row.remove:SetEnabledState(line.queued > 0)
    row.remove.tooltipText = line.queued > 0
        and L.Format("Queue one fewer %s. Right-click the row to take all of it off.", line.name)
        or L["Nothing of this queued yet"]
end

CraftPanel._UpdateRow = UpdateRow

local function ShowRowTooltip(row, line)
    ns.Widgets.ShowItemTooltip(row, "ANCHOR_LEFT", line.outputItemID, line.name)
    GameTooltip:AddLine(" ")

    if line.priceable then
        GameTooltip:AddDoubleLine(L["Profit each"],
            Util.FormatMoney(line.profit, { noColor = true }), 0.7, 0.7, 0.7, 1, 1, 1)
    else
        GameTooltip:AddLine(line.reason or L["No price data for this yet"], 0.9, 0.38, 0.31)
    end

    -- What each way makes, as on the Profit tab, the one counted lit.
    for _, way in ipairs(line.ways or {}) do
        local label = way.label .. (way.note and (" (" .. way.note .. ")") or "")
        local r, g, b = 0.7, 0.7, 0.7
        if way.chosen then r, g, b = Theme.Unpack("accent") end
        local vr, vg, vb = Theme.Unpack(way.profit >= 0 and "profit" or "loss")
        GameTooltip:AddDoubleLine(label, Util.FormatMoney(way.profit, { noColor = true }),
            r, g, b, vr, vg, vb)
    end

    -- Above materials, because on a profession still climbing it is the thing
    -- that decides what to make with them.
    if line.skillUpTier then
        local r, g, b = ns.SkillUp:GetTierColor(line.skillUpTier)
        GameTooltip:AddDoubleLine(L["Skill up"],
            ns.SkillUp:GetTierLabel(line.skillUpTier), 0.7, 0.7, 0.7, r, g, b)

        if line.skillUpStale then
            GameTooltip:AddLine(L["Read at a lower skill. It may have gone green since."],
                0.91, 0.76, 0.35, true)
        end
    end

    local steps = ns.SkillUp.ColorSteps and ns.SkillUp:ColorSteps(line.recipeID)
    if steps then GameTooltip:AddLine(steps, 1, 1, 1, true) end

    GameTooltip:AddDoubleLine(L["Materials for"], tostring(line.craftable),
        0.7, 0.7, 0.7, 1, 1, 1)

    -- Stock first: it is the thing that decides whether to make more at all,
    -- where the profit above only says what one is worth.
    local stockText = StockText(line)

    if stockText then
        if line.atPostLimit then
            GameTooltip:AddDoubleLine(L["Already have"], stockText,
                0.7, 0.7, 0.7, 0.95, 0.65, 0.25)
        else
            GameTooltip:AddDoubleLine(L["Already have"], stockText, 0.7, 0.7, 0.7, 1, 1, 1)
        end
    end

    if line.queued > 0 then
        GameTooltip:AddDoubleLine(L["Already queued"], tostring(line.queued),
            0.7, 0.7, 0.7, 0.78, 0.64, 0.30)
    end

    GameTooltip:AddLine(L["Left-click to queue, right-click to remove, Shift-click to search the auction house."], 0.5, 0.5, 0.5, true)
    GameTooltip:AddLine(L["Ctrl-right-click to stop suggesting it."], 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

--- Left-click queues, right-click takes it back off, Ctrl-right-click
--- ignores the craft.
--
-- The + button is the discoverable way in; this is for working down a list
-- quickly, where reaching for the same small button every time is the slow part.
local function OnRowClick(line, _, mouseButton, row)
    if mouseButton == "RightButton" then
        -- Ignoring is the Profit tab's own list (a player asked, 2026-10-14),
        -- so a craft ignored in either place is gone from both and Settings
        -- restores it. What is already queued stays queued.
        if IsControlKeyDown and IsControlKeyDown() then
            GameTooltip:Hide()
            ns.Profit:SetIgnored(line.recipeID, true, line.name)
            ns.Print(L.Format("ignored %s: it is no longer suggested here or on the Profit tab. Restore it under Ignored crafts in Settings.",
                line.name))
            CraftPanel:Refresh()
            return
        end

        ns.Queue:Remove(line.recipeID)
        return
    end

    QueueMore(line, 1)
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

function CraftPanel:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSCraftPanel", UIParent)
    frame:SetWidth(PANEL_WIDTH)
    frame:SetFrameStrata("HIGH")

    -- Opaque, so a click on a row cannot fall through to whatever is behind
    -- the pane, and raised on click: the main window shares this strata, and
    -- without this the two would have a fixed order forever.
    frame:EnableMouse(true)
    if frame.SetToplevel then frame:SetToplevel(true) end
    frame:Hide()

    -- Opening the pane again sorts afresh (see CraftPanel:OrderKey).
    frame:HookScript("OnHide", function()
        CraftPanel.orderKey, CraftPanel.heldOrder = nil, nil
    end)

    Theme.Fill(frame, "window")
    -- The house frame (UI/Titanforged.lua): the gold rim and corner gems.
    if ns.Titanforged then
        ns.Titanforged:Dress(frame)
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    -- The house glow round its edge, flaring as it opens.
    Theme.Halo(frame, 8, 0.08)

    local header, title = ns.Collapse.CreateHeader(frame, L["Craft queue"])
    self.title = title

    -- Everything under the title, so the collapse button can fold it away in
    -- one go and leave the title strip showing.
    local body = CreateFrame("Frame", nil, frame)
    body:SetAllPoints(frame)
    self.body = body

    ns.Collapse.Attach(frame, {
        key = COLLAPSE_KEY,
        header = header,
        title = title,
        body = body,
        onToggle = function()
            CraftPanel:ApplyHeight()
            CraftPanel:Refresh()
        end,
    })

    -- Profit order is the useful default -- it answers "what should I make" --
    -- but a pane you came to in order to find one specific recipe needs the
    -- alphabet, so the order is a single click away rather than a setting.
    self.sortBy = self.sortBy or "profit"

    local sort = Widgets.CreateButton(body, "", function()
        local nextIndex = 1
        for index, key in ipairs(SORT_ORDER) do
            if key == CraftPanel.sortBy then nextIndex = index % #SORT_ORDER + 1 end
        end
        CraftPanel.sortBy = SORT_ORDER[nextIndex]
        CraftPanel:UpdateSortButton()
        CraftPanel:Refresh()
    end, { width = 116, height = 18, tooltip = L["Change the order of this list"] })
    -- On the header strip, though it folds away with the body.
    sort:SetPoint("RIGHT", header, "RIGHT", -6, 0)
    self.sortButton = sort
    self:UpdateSortButton()

    -- Coalesced rather than refreshed per keystroke: every refresh prices
    -- every recipe the profession is showing, and typing "copper" would
    -- otherwise do that six times before the word is finished.
    local search = Widgets.CreateSearchBox(body, L["Search recipes"], function()
        CraftPanel:RequestRefresh()
    end)
    -- One anchor and an explicit size. A TOPLEFT under the title plus a
    -- TOPRIGHT on the frame would set this box's top twice, from two frames
    -- that disagree about where it is, and the client resolves that by
    -- quietly dropping one of the two.
    search:SetPoint("TOPLEFT", 14, ns.Collapse.CONTENT_TOP)
    search:SetSize(PANEL_WIDTH - 28, 22)
    self.search = search

    local divider = Theme.CreateDivider(body)
    divider:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -8)
    divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, 0)

    local list = Widgets.CreateScrollList(body, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onClick = OnRowClick,
        onEnter = ShowRowTooltip,
        onLeave = function() GameTooltip:Hide() end,
    })
    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 94)
    self.list = list

    local empty = Theme.CreateLabel(body, "small", "dim", "CENTER")
    empty:SetPoint("CENTER", list, "CENTER")
    empty:SetWidth(PANEL_WIDTH - 40)
    empty:SetWordWrap(true)
    self.empty = empty

    -- Crafting needs a hardware event, so this is a real click each time: one
    -- click runs one queue entry to completion. Same call the Queue tab makes,
    -- so working from either place behaves identically.
    -- A shelf behind the controls along the bottom, under a lit rule, so the
    -- list ends clearly where the buttons begin.
    ns.Collapse.CreateFooter(body, 78)

    local craft = Widgets.CreateButton(body, L["Craft next"], function()
        if ns.Crafting:IsBusy() then
            ns.Crafting:Stop()
        else
            -- The same scoped lookup the button's label came from, so a
            -- click can never start something other than what it offered.
            local entry = CraftPanel:GetNextReadyHere()
            if entry then
                ns.Crafting:Start(entry.recipeID, entry.quantity)
            end
        end

        CraftPanel:Refresh()
    end, { width = PANEL_WIDTH - 28, height = 24, primary = true })
    craft:SetPoint("BOTTOMLEFT", 14, 40)
    self.craftButton = craft
    if ns.SecureCraft then
        ns.SecureCraft:Attach(craft, function()
            local entry = CraftPanel:GetNextReadyHere()
            if entry then return entry.recipeID, entry.quantity end
        end)
    end

    -- The Keep in stock limit (Settings) hides crafts you already hold enough
    -- of and caps what + will queue. Ticking this lifts both, for this pane
    -- only, without changing the limit itself. Remembered between sessions.
    local ignoreLimit = Widgets.CreateCheckbox(body, L["Ignore max on hand"], function(checked)
        ns.Config:Set("craftPaneIgnoreLimit", checked)
        CraftPanel:Refresh()
    end, self:IgnoringLimit())
    ignoreLimit:SetPoint("BOTTOMLEFT", 14, 70)
    ignoreLimit:HookScript("OnEnter", function(box)
        GameTooltip:SetOwner(box, "ANCHOR_TOP")
        GameTooltip:SetText(L["Shows every craft, even ones you have enough of, and queues the full number you type."], 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ignoreLimit:HookScript("OnLeave", function() GameTooltip:Hide() end)
    self.ignoreLimitBox = ignoreLimit

    -- How many crafts here are ignored, on the line of the box above, so
    -- an ignored craft is never simply lost. Shown only when there are some.
    local ignoredLabel = Theme.CreateLabel(body, "tiny", "muted")
    ignoredLabel:SetPoint("LEFT", ignoreLimit, "RIGHT", 10, 0)
    ignoredLabel:SetWidth(math.max(40, PANEL_WIDTH - 28 - (ignoreLimit:GetWidth() or 0) - 10))
    ignoredLabel:SetJustifyH("RIGHT")
    ignoredLabel:Hide()
    self.ignoredLabel = ignoredLabel

    local ignoredHover = CreateFrame("Frame", nil, body)
    ignoredHover:SetAllPoints(ignoredLabel)
    ignoredHover:EnableMouse(true)
    ignoredHover:SetScript("OnEnter", function(hover)
        if not ignoredLabel:IsShown() then return end
        GameTooltip:SetOwner(hover, "ANCHOR_TOP")
        GameTooltip:SetText(L["Ignored crafts"], 1, 1, 1)
        GameTooltip:AddLine(L["Ignored crafts aren't suggested here. Search by name to find one, or restore it in Settings."], 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    ignoredHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Room left of the two buttons at the bottom right.
    local summaryWidth = PANEL_WIDTH - 28 - QUEUE_TAB_WIDTH - CLEAR_WIDTH - 12

    local summary = Theme.CreateLabel(body, "tiny", "muted")
    summary:SetPoint("BOTTOMLEFT", 14, 22)
    summary:SetWidth(summaryWidth)
    self.summary = summary

    -- What the * after a profit that leaves crafts out means. The line has
    -- no room to say it, and "(some unpriced)" ran off its end.
    local summaryHover = CreateFrame("Frame", nil, body)
    summaryHover:SetAllPoints(summary)
    summaryHover:EnableMouse(true)
    summaryHover:SetScript("OnEnter", function(hover)
        if not CraftPanel.summaryNote or not summary:IsShown() then return end
        GameTooltip:SetOwner(hover, "ANCHOR_TOP")
        GameTooltip:SetText(CraftPanel.summaryNote, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    summaryHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- While a craft casts, a progress bar takes the summary line's place.
    local progress = ns.CraftProgress:Create(body, {
        width = summaryWidth, height = 16, covers = summary,
    })
    progress:SetPoint("LEFT", summary, "LEFT", 0, 0)
    self.progress = progress

    local openQueue = Widgets.CreateButton(body, L["Queue tab"], function()
        ns.UI:Show()
        ns.UI:SelectTab("queue")
    end, { width = QUEUE_TAB_WIDTH, height = 18, tooltip = L["Open the full queue, with its shopping list"] })
    openQueue:SetPoint("BOTTOMRIGHT", -14, 18)

    -- A queue can take a while to build, so emptying it takes a second click.
    local clear = Widgets.CreateButton(body, L["Clear queue"], function()
        CraftPanel:OnClearClicked()
    end, { width = CLEAR_WIDTH, height = 18 })
    clear:SetPoint("RIGHT", openQueue, "LEFT", -6, 0)
    self.clearButton = clear

    self.frame = frame
    return frame
end

--- Clear queue: the first click asks, a second click within a few seconds
--- empties the queue. Left alone, the button goes back to how it was.
function CraftPanel:OnClearClicked()
    local now = GetTime()

    if self.clearArmedUntil and now < self.clearArmedUntil then
        self.clearArmedUntil = nil
        local count = ns.Queue:Count()
        ns.Queue:Clear()
        ns.Print(count == 1 and L.Format("Craft queue cleared (%d entry).", count)
            or L.Format("Craft queue cleared (%d entries).", count))
        self:UpdateClearButton()
        return
    end

    self.clearArmedUntil = now + CLEAR_CONFIRM_SECONDS
    self:UpdateClearButton()

    if C_Timer and C_Timer.After then
        C_Timer.After(CLEAR_CONFIRM_SECONDS, function()
            if CraftPanel.clearArmedUntil and GetTime() >= CraftPanel.clearArmedUntil then
                CraftPanel.clearArmedUntil = nil
            end
            CraftPanel:UpdateClearButton()
        end)
    end
end

function CraftPanel:UpdateClearButton()
    local button = self.clearButton
    if not button then return end

    local empty = ns.Queue:Count() == 0
    if empty then self.clearArmedUntil = nil end

    local armed = self.clearArmedUntil ~= nil and GetTime() < self.clearArmedUntil

    button:SetText(armed and L["Click to clear"] or L["Clear queue"])
    button:SetEnabledState(not empty)
    button:SetConfirming(armed)

    button.tooltipText = empty and L["The queue is empty"]
        or armed and L["Click again to empty the whole craft queue"]
        or L["Empties the whole craft queue. Click twice to clear."]
end

function CraftPanel:UpdateSortButton()
    if not self.sortButton then return end

    self.sortButton:SetText(L.Format("Sort by: %s", SORT_LABEL[self.sortBy] or L["Profit"]))
    self.sortButton.tooltipText = ({
        profit = L["Best-paying crafts first. Click to sort by Level Up."],
        levelup = L["Best skill up chance first, then cheapest. Click to sort by name."],
        name = L["Sorted by name. Click to sort by profit."],
    })[self.sortBy]
end

--- Dock to the right of the profession window, as tall as it is.
function CraftPanel:Attach()
    local frame = self:Build()
    local tradeSkillFrame, frameName = self:FindTradeSkillFrame()
    local opening = not frame:IsShown()

    frame:ClearAllPoints()

    if tradeSkillFrame then
        -- One anchor and a measured height, rather than a point on the
        -- profession window's top and another on its bottom. Anchoring TOPLEFT
        -- and BOTTOM over-constrains the frame -- a BOTTOM point fixes the
        -- horizontal centre, which TOPLEFT has already decided -- and the
        -- client silently drops one of the two. That is how the sell list
        -- ended up docked at half the height it asked for.
        --
        -- Offset past the profession tabs down the window's right-hand edge,
        -- which stick out beyond the frame GetRight() reports. Still anchored
        -- to the frame rather than to a screen position, so the pane keeps
        -- moving with the window.
        local overhang = self:RightOverhang(tradeSkillFrame)

        frame:SetPoint("TOPLEFT", tradeSkillFrame, "TOPRIGHT", overhang + PANEL_GAP, 0)
        frame:SetHeight(ns.Collapse.Height(COLLAPSE_KEY,
            self:DesiredHeight(tradeSkillFrame) or PANEL_FALLBACK_HEIGHT))

        ns.Debug("docked craft pane to", frameName, "clearing", overhang)
    else
        -- Blizzard's profession UI is load-on-demand and may not exist yet.
        -- A pane in a slightly odd place beats one that silently never appears.
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
        frame:SetHeight(ns.Collapse.Height(COLLAPSE_KEY, PANEL_FALLBACK_HEIGHT))

        ns.Debug("no profession frame found; using fallback position")
    end

    frame:Show()
    self:Refresh()

    -- Opening a profession puts the pane up after the main window, which
    -- left the pane drawn across it. The window the player had open stays
    -- in front; a click on the pane still brings the pane forward.
    local window = ns.UI and ns.UI.window
    if window and window:IsShown() and window.Raise then window:Raise() end

    -- The tabs can be laid out a moment after the window opens, and the game
    -- moves the window into its slot beside the auction house after that:
    -- measure again once they have.
    if C_Timer and C_Timer.After then
        for _, delay in ipairs({ 0.2, 1 }) do
            C_Timer.After(delay, function() CraftPanel:Reflow() end)
        end
    end

    -- Fades in where it docked, its glow flaring; it never rises, since it
    -- sits beside the profession window.
    if opening and ns.Motion then ns.Motion:Open(frame, 0) end
end

function CraftPanel:IsCollapsed()
    return ns.Collapse.IsCollapsed(COLLAPSE_KEY)
end

--- Set the height outright, after folding or unfolding.
function CraftPanel:ApplyHeight()
    if not self.frame then return end

    local tradeSkillFrame = self:FindTradeSkillFrame()
    local full = tradeSkillFrame and self:DesiredHeight(tradeSkillFrame)

    self.frame:SetHeight(ns.Collapse.Height(COLLAPSE_KEY, full or PANEL_FALLBACK_HEIGHT))
end

--- Re-measure, for a profession window that changed size after it opened.
function CraftPanel:Reflow()
    if not self.frame or not self.frame:IsShown() then return end

    local tradeSkillFrame = self:FindTradeSkillFrame()
    if not tradeSkillFrame then return end

    local height = self:DesiredHeight(tradeSkillFrame)
    if height then height = ns.Collapse.Height(COLLAPSE_KEY, height) end

    -- Only when it actually moved: setting the height relayouts the list, and
    -- this runs on every refresh.
    if height and math.abs(height - self.frame:GetHeight()) > 0.5 then
        self.frame:SetHeight(height)
    end

    -- The tabs are not always laid out at the moment the window first opens,
    -- so the clearance is re-measured rather than settled once at attach.
    local point, relativeTo, relativePoint, x, y = self.frame:GetPoint()

    -- Only ever adjusts the docked anchor. Attached before the profession
    -- window existed, the pane is pinned to the screen edge instead, and
    -- writing a dock offset into that anchor would fling it across the screen.
    -- Attach puts it right; this must not be what moves it.
    if point ~= "TOPLEFT" or relativeTo ~= tradeSkillFrame then return end

    local wanted = self:RightOverhang(tradeSkillFrame) + PANEL_GAP

    if x and math.abs(wanted - x) > 0.5 then
        self.frame:SetPoint(point, relativeTo, relativePoint, wanted, y or 0)
    end
end

--- The next queued craft *this* profession window can actually make.
--
-- `Crafting:GetNextReady` walks the whole queue and asks only whether the
-- character could make each entry, which is the right question for the Queue
-- tab and the wrong one here. Standing at Enchanting with tailoring queued, it
-- answered "Bolt of Linen Cloth", and `C_TradeSkillUI.CraftRecipe` on a recipe
-- the open window does not have fails without saying anything -- this client
-- shows no Lua error unless scriptErrors is on, so the button would simply
-- have done nothing, forever, with no way to tell that from a dead button.
--
-- Scoped by the open window's own recipe list rather than by comparing skill
-- line IDs: this client reports each profession under two different ID spaces
-- (a modern one and a legacy one), so an ID comparison is a trap.
--
-- @return entry, readyElsewhere -- a ready craft for another profession is
--   counted rather than offered, so the button can say which.
function CraftPanel:GetNextReadyHere()
    local open = self:GetOpenRecipeIDs()
    local readyElsewhere = 0
    local ready = {}

    for _, entry in ipairs(ns.Queue:GetAll()) do
        if ns.Crafting:GetReadiness(entry.recipeID) then
            -- No open set means the client would not say which profession is
            -- showing. Offering the craft is then the best available guess,
            -- and matches what the Queue tab does.
            if not open or open[entry.recipeID] then
                ready[#ready + 1] = entry
            else
                readyElsewhere = readyElsewhere + 1
            end
        end
    end

    -- Of those, the one that frees the most bag space (Crafting:PickNext).
    if not ns.Crafting.PickNext then return ready[1], readyElsewhere end
    local entry, slots = ns.Crafting:PickNext(ready)
    return entry, readyElsewhere, slots
end

--- The Craft button's tooltip, saying the bag space it frees when that
--- picked it (Crafting:PickNext).
local function CraftTooltip(slots)
    if slots and slots > 0 then
        return slots == 1
            and L["Makes every craft in this entry. It frees 1 bag slot, more than anything else ready."]
            or L.Format("Makes every craft in this entry. It frees %d bag slots, more than anything else ready.", slots)
    end
    return L["Makes every craft in this entry"]
end

--- Keep the Craft next button honest about what it will do, and why it cannot.
function CraftPanel:UpdateCraftButton()
    local button = self.craftButton
    if not button then return end

    if ns.Crafting:IsBusy() then
        button:SetText(L["Stop crafting"])
        button:SetEnabledState(true)
        button.tooltipText = L["Stop after the current craft"]
        return
    end

    if ns.Queue:Count() == 0 then
        button:SetText(L["Craft next"])
        button:SetEnabledState(false)
        button.tooltipText = L["Nothing is queued"]
        return
    end

    local entry, readyElsewhere, slots = self:GetNextReadyHere()

    if not entry then
        button:SetText(L["Craft next"])
        button:SetEnabledState(false)

        if readyElsewhere > 0 then
            -- Ready, but not at this window. Say so, rather than reporting the
            -- first entry's obstacle: "need materials" would be a lie about a
            -- craft whose materials are sitting in the bags.
            button.tooltipText = readyElsewhere == 1
                and L.Format("%d queued craft is ready for another profession. Open that one to make it.", readyElsewhere)
                or L.Format("%d queued crafts are ready for another profession. Open that one to make them.", readyElsewhere)
            return
        end

        -- Report the first entry's actual obstacle rather than a generic one.
        local _, reason = ns.Crafting:GetReadiness(ns.Queue:GetAll()[1].recipeID)
        button.tooltipText = reason or L["Nothing here can be made yet"]
        return
    end

    local recipe = ns.Recipes:GetAny(entry.recipeID)
    local canMake = math.min(entry.quantity, ns.Profit:GetCraftableCount(entry.recipeID))

    button:SetText(L.Format("Craft %dx %s", canMake, (recipe and recipe.name) or L["item"]))
    button:SetEnabledState(true)
    button.tooltipText = CraftTooltip(slots)
end

--- The part of a refresh that comes before the rows: the frame laid out, the
--- folded pane filled in (all it needs), and the options the rows are read
--- with. Nil when there are no rows to read.
function CraftPanel:BeginRefresh()
    if not self.frame or not self.frame:IsShown() then return nil end

    self:Reflow()

    -- Folded away there is nothing to fill in, and filling it in prices every
    -- recipe the profession shows. The title carries the queue count instead.
    if self:IsCollapsed() then
        local queued = ns.Queue:Count()
        self.title:SetText(queued > 0
            and L.Format("Craft queue (%d queued)", queued)
            or L["Craft queue"])
        self:RefreshQueued()
        return nil
    end

    self.title:SetText(L["Craft queue"])

    local opts = {
        search = self.search and self.search:GetText() or "",
        sortBy = self.sortBy,
        ignoreLimit = self:IgnoringLimit(),
        method = PaneMethod(),
        methodRead = true,
    }

    local key = self:OrderKey(opts)
    if key ~= self.orderKey or not self:MouseOver() then
        self.orderKey, self.heldOrder = key, nil
    end
    opts.keepOrder = self.heldOrder
    return opts
end

--- Is the cursor on the pane? The order is held only then, so a row never
--- moves from under a click, and is sorted again once the cursor is away.
--- Held for good, prices and materials read after the pane opened never
--- moved a row, and the list stayed in the order it first had (a player's
--- report, 2026-10-18).
function CraftPanel:MouseOver()
    local frame = self.frame
    if not (frame and frame.IsMouseOver) then return false end
    local ok, over = pcall(frame.IsMouseOver, frame)
    return ok and over == true
end

-- How often, in seconds, a held order looks whether the cursor has gone.
CraftPanel.LEAVE_LOOK = 0.5

--- Once the cursor leaves a pane whose order is held, sort it again. One
--- short timer at a time, only while an order is held and the pane shows.
function CraftPanel:WatchLeave()
    if self.watchingLeave or not (C_Timer and C_Timer.After) then return end
    self.watchingLeave = true

    local function Look()
        if not (CraftPanel.heldOrder and CraftPanel:IsShown()) then
            CraftPanel.watchingLeave = nil
            return
        end
        if CraftPanel:MouseOver() then
            C_Timer.After(CraftPanel.LEAVE_LOOK, Look)
            return
        end
        CraftPanel.watchingLeave = nil
        CraftPanel:RequestRefresh()
    end

    C_Timer.After(self.LEAVE_LOOK, Look)
end

--- Put rows worked out for `opts` on screen, with everything that follows them.
function CraftPanel:ApplyRows(rows, opts)
    self.heldOrder = {}
    for index, row in ipairs(rows) do
        self.heldOrder[row.recipeID] = index
    end

    self.list:SetData(rows)
    self.empty:SetShown(#rows == 0)

    -- Rows put on screen in a held order, or under the cursor, are sorted
    -- again once it leaves.
    if self:MouseOver() then self:WatchLeave() end

    if #rows == 0 then
        local searching = self.search and self.search:GetText() ~= ""

        self.empty:SetText(searching
            and L["Nothing here matches that."]
            or (self.hiddenAtLimit or 0) > 0
                and L["Every recipe here is at its Keep in stock limit.\n\nTick Ignore max on hand to see them."]
            or (self.hiddenIgnored or 0) > 0
                and L["Every recipe here is ignored.\n\nRestore them under Settings, Queue, Ignored crafts."]
            or L["No recipes read for this profession yet.\n\nThey're read when the window opens, so give it a moment."])
    end

    self:UpdateIgnoredLabel()

    self:UpdateCraftButton()
    self:UpdateClearButton()
    self:RefreshQueued()
    self:UpdateSummary()
end

function CraftPanel:Refresh()
    self:StopSlicedRefresh()

    local opts = self:BeginRefresh()
    if not opts then return end

    self:ApplyRows(self:GetRows(opts), opts)
end

-- How much of a frame a refresh in the background may take, in milliseconds.
local SLICE_MS = 3

--- Refresh with the rows worked out a few at a time, over as many frames as
--- that takes, then shown all at once.
--
-- A refresh prices every recipe the profession window shows, several hundred
-- on a maxed profession, and during a run of crafts the bags change with
-- every craft. Done in one go, that was a hitch per craft that a player saw
-- as a jerky craft bar (2026-10-09). Clicks and typing still refresh at once
-- (Refresh); only the refreshes events ask for are spread out.
function CraftPanel:RefreshInSlices()
    if not (Util and type(Util.NewWorker) == "function") then return self:Refresh() end

    -- One already under way finishes, then goes again with what changed since.
    if self.slicing then
        self.sliceAgain = true
        return
    end

    local opts = self:BeginRefresh()
    if not opts then return end

    local list, search = RowSources(self, opts)
    local rows, tally = {}, { hiddenAtLimit = 0, ignored = 0 }

    local worker = Util.NewWorker({
        budgetMs = SLICE_MS,
        onItem = function(item)
            rows[#rows + 1] = RowFor(item.recipeID, item.recipe, opts, search, tally)
        end,
        onDone = function(done)
            if CraftPanel.slicing ~= done then return end
            CraftPanel.slicing = nil

            if CraftPanel:IsShown() and not CraftPanel:IsCollapsed() then
                CraftPanel.hiddenAtLimit = tally.hiddenAtLimit
                CraftPanel.hiddenIgnored = tally.ignored
                CraftPanel:ApplyRows(SortRows(rows, opts), opts)
            end

            if CraftPanel.sliceAgain then
                CraftPanel.sliceAgain = nil
                CraftPanel:RequestRefresh()
            end
        end,
    })

    self.slicing = worker
    worker:Start(list)
end

--- Drop a refresh under way in the background: one taken at once replaces it.
function CraftPanel:StopSlicedRefresh()
    local worker = self.slicing
    self.slicing, self.sliceAgain = nil, nil
    if worker then worker:Cancel() end
end

--- "N ignored" beside the Ignore max on hand box, hidden at none.
function CraftPanel:UpdateIgnoredLabel()
    local label = self.ignoredLabel
    if not label then return end

    local count = self.hiddenIgnored or 0
    if count > 0 then
        label:SetText(L.Format("%d ignored", count))
        label:Show()
    else
        label:Hide()
    end
end

--- The queue total along the bottom of the pane.
function CraftPanel:UpdateSummary()
    if not self.summary then return end

    local queued = ns.Queue:Count()
    self.summaryNote = nil

    if queued == 0 then
        self.summary:SetText(L["Nothing queued"])
        self.summary:SetTextColor(Theme.Unpack("dim"))
        return
    end

    local totals = ns.Queue:GetTotals()
    local colour = (totals.profit or 0) < 0 and ns.COLORS.loss or ns.COLORS.profit

    -- A craft with no price is left out of the profit. A * says so, and the
    -- hover says what it means.
    local marker = ""
    if not totals.priceable then
        marker = ("|c%s*|r"):format(ns.COLORS.warn)
        self.summaryNote = L["Some queued crafts have no price, so this profit leaves them out."]
    end

    -- The profit in its own colour: green when the queue pays, red when not.
    -- Kept short: it shares the bottom line with Clear queue and Queue tab,
    -- and an amount too long for it loses coins rather than its end.
    local texts = {}
    for _, coins in ipairs({ 3, 2, 1 }) do
        texts[#texts + 1] = L.Format("%d queued · profit |c%s%s|r%s", totals.crafts, colour,
            Util.FormatMoney(totals.profit, { noColor = true, short = true, parts = coins }),
            marker)
    end
    SetFirstThatFits(self.summary, texts)
    self.summary:SetTextColor(Theme.Unpack("muted"))
end

--------------------------------------------------------------------------------
-- Queued crafts, beside the pane
--------------------------------------------------------------------------------

-- Asked 2026-09-28: "show the crafting queue out to the right of this Craft
-- queue window once things are queued." The queue itself, in the order it is
-- worked through, each entry with its own Craft button, so nothing here needs
-- the main window. A child of the pane, so it hides whenever the pane does.

local QUEUED_WIDTH = 250
local QUEUED_ROW_HEIGHT = 30
local QUEUED_GAP = 4

CraftPanel.QUEUED_WIDTH = QUEUED_WIDTH

--- What the queued list says under an entry's name, and whether its Craft
--- button can be pressed.
--
-- @param open the open profession's recipe set, or nil when the game will not say
-- @return text, colour key, craftable here
function CraftPanel:QueuedStatus(entry, open)
    local active = ns.Crafting.active
    if active and active.recipeID == entry.recipeID then
        return L["crafting now"], "accent", true
    end

    local ready, reason = ns.Crafting:GetReadiness(entry.recipeID)
    local here = not open or open[entry.recipeID]

    if ready and here then
        local canMake = math.min(entry.quantity,
            ns.Profit:GetCraftableCount(entry.recipeID) or 0)
        return L.Format("ready, materials for %d", canMake), "profit", true
    end

    if ready then return L["ready, in another profession"], "muted", false end

    return reason or L["missing materials"], "muted", false
end

local BUY_WIDTH = 34

local function CreateQueuedRow(row)
    row.icon = Theme.CreateItemIcon(row, 13)
    row.icon:SetPoint("TOPLEFT", 8, -3)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("TOPLEFT", 25, -4)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -(8 + 16 + 4 + CRAFT_WIDTH + 6), -4)

    row.detail = Theme.CreateLabel(row, "tiny", "muted")
    row.detail:SetPoint("TOPLEFT", 8, -17)
    row.detail:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -17)

    -- On a sub-craft: never make it as one, buy it instead (Queue:NeverMake).
    row.remove = Widgets.CreateButton(row, "x", function()
        if not row.data then return end
        if row.data.isDependency then
            -- Asks first: it sets the craft to Buy for good (UI/NeverMakeBox.lua).
            if ns.NeverMakeBox then ns.NeverMakeBox.Click(row.data, row.remove)
            else ns.Queue:NeverMake(row.data) end
        else
            ns.Queue:Remove(row.data.recipeID)
        end
    end, { width = 16, height = 15, tooltip = L["Take this off the queue"] })
    row.remove:SetPoint("TOPRIGHT", -8, -1)

    row.craft = Widgets.CreateButton(row, L["Craft"], function()
        if row.data then CraftPanel:CraftEntry(row.data) end
    end, { width = CRAFT_WIDTH, height = 15, primary = true })
    row.craft:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)
    if ns.SecureCraft then
        ns.SecureCraft:Attach(row.craft, function()
            if row.data then return row.data.recipeID, row.data.quantity end
        end)
    end

    -- On a sub-craft kept after buying its item turned cheaper, at the end
    -- of the line that says so.
    row.buy = Widgets.CreateButton(row, L["Buy"], function()
        if row.data then ns.Queue:BuyInstead(row.data) end
    end, { width = BUY_WIDTH, height = 13 })
    row.buy:SetPoint("TOPRIGHT", -8, -16)
    row.buy:Hide()
end

local function UpdateQueuedRow(row, entry)
    local recipe = ns.Recipes:GetAny(entry.recipeID)

    row.name:SetText(("%dx %s"):format(entry.quantity,
        (recipe and recipe.name) or L.Format("recipe %s", tostring(entry.recipeID))))
    Theme.SetItemIcon(row.icon, recipe and recipe.outputItemID)

    local r, g, b = Util.GetItemQualityColor(recipe and recipe.outputItemID)
    if r then
        row.name:SetTextColor(r, g, b)
    else
        row.name:SetTextColor(Theme.Unpack("text"))
        if recipe and recipe.outputItemID then CraftPanel.awaitingItemData = true end
    end

    local status, colour, craftable = CraftPanel:QueuedStatus(entry, CraftPanel.queuedOpen)

    -- A material the queue added for another craft says which, as the Queue
    -- tab does. Its x never makes it as a sub-craft again: it is sized from
    -- that craft, so taking it off alone would bring it straight back.
    local texts = {}
    if entry.isDependency then
        local parents = ns.Queue:GetDependencyParents(entry)
        status = L.Format("for %s · %s",
            #parents > 0 and table.concat(parents, ", ") or L["another craft"], status)
    end

    -- Kept after buying turned cheaper (Queue:RebuildDependencies): said
    -- first, in amber, with a Buy button to take it off.
    local kept = entry.isDependency and entry.buyCheaper == true
    if kept then
        status = L.Format("buying is cheaper now · %s", status)
        colour = "warn"
        local name = (recipe and recipe.name) or L["this"]
        local buy, make = ns.Queue:GetBuyOrMake(entry)
        local tip = L.Format("Buying %s is now cheaper than making it.", name)
        if buy and make then
            tip = L.Format("%s\nBuy: %s each. Make: %s each.", tip,
                Util.FormatMoney(buy), Util.FormatMoney(make))
        end
        row.buy.tooltipText = tip .. "\n" .. L["Buy takes it off the queue and puts it on the shopping list."]
    end
    row.buy:SetShown(kept)
    row.detail:SetPoint("TOPRIGHT", row, "TOPRIGHT", kept and -(8 + BUY_WIDTH + 4) or -8, -17)

    -- Who it is for, when another of your characters is waiting on it, or
    -- who makes it, when it is not this one: the longest that fits.
    local who = ns.Queue.DescribeWho and ns.Queue:DescribeWho(entry) or {}
    for _, text in ipairs(who) do texts[#texts + 1] = text .. " · " .. status end
    texts[#texts + 1] = status
    Theme.FitText(row.detail, texts)
    row.detail:SetTextColor(Theme.Unpack(colour))

    row.remove:Show()
    row.remove.tooltipText = entry.isDependency and ns.Queue.NeverMakeTooltip
        and ns.Queue:NeverMakeTooltip(entry) or nil

    local busy = ns.Crafting:IsBusy()
    row.craft:SetText(busy and L["Stop"] or L["Craft"])
    row.craft:SetEnabledState(busy or craftable)
    row.craft.tooltipText = busy and L["Stop crafting"]
        or craftable and L["Craft these now, as many as your materials make"]
        or status
end

--------------------------------------------------------------------------------
-- The shopping list, under the queued crafts
--------------------------------------------------------------------------------

-- Ranatsu32 on CurseForge: "Is it possible to have the 'Crafting Queue' show a
-- total materials needed to complete the queue? Like a shopping list?" The
-- Queue tab had one, but this is the window people craft from. Same list as
-- that tab (Queue:GetShoppingList), so the two never disagree.

local SHOPPING_ROW_HEIGHT = 28
local SHOPPING_BAR_WIDTH = 96
local SHOPPING_COUNT_WIDTH = 54
local SHOPPING_FOOTER_HEIGHT = 26

-- The queued crafts keep at least this many rows when the shopping list
-- shares the column with them, and never take more than this share of it.
local QUEUED_MIN_ROWS = 2
local QUEUED_MAX_SHARE = 0.45

--- Who else holds the most of an item, bags and bank together.
--
-- From the counts Inventory already saved for each character; nothing new is
-- read. Only a hint: stock on another character is not in reach of the craft.
-- @return name, count  (nil when no other character has any)
function CraftPanel:AltHolder(itemID)
    local characters = ns.db and ns.db.characters
    if type(characters) ~= "table" then return nil end

    local selfKey = ns.Config:GetCharacterKey()
    local bestKey, bestCount = nil, 0

    for key, record in pairs(characters) do
        if key ~= selfKey and type(record) == "table" then
            local count = 0
            if type(record.inventory) == "table" then count = count + (record.inventory[itemID] or 0) end
            if type(record.bank) == "table" then count = count + (record.bank[itemID] or 0) end
            if count > bestCount or (count == bestCount and count > 0 and key < bestKey) then
                bestKey, bestCount = key, count
            end
        end
    end

    if not bestKey then return nil end
    local name = Util.CharacterName(bestKey)

    -- The full name (never shortened, the owner's rule 2026-10-11); a tag
    -- with too little room for it falls back to its shorter wording.
    if name ~= "" and ns.Recipes and ns.Recipes.GetShortCharacterName then
        local short = ns.Recipes:GetShortCharacterName(bestKey)
        if type(short) == "string" and short ~= "" then name = short end
    end

    if name == "" then name = L["another character"] end
    return name, bestCount
end

--- How one shopping list line reads.
--
-- Green when you have enough on you, amber when you own enough but some of it
-- is in the bank, the mailbox or on another character, red when you still
-- have to buy.
-- @return look { count, colour, fraction, tag, tagColour, shorter }
--   shorter: the tag in fewer words, for a row with too little room for it
function CraftPanel:ShoppingLook(line)
    local needed = math.max(1, line.needed or 0)
    local look = {
        count = ("%d/%d"):format(line.have or 0, line.needed or 0),
        fraction = math.min(1, (line.have or 0) / needed),
    }

    if (line.shortfall or 0) <= 0 then
        if line.needsBankTrip then
            look.colour, look.tag, look.tagColour = "warn", L["in bank"], "warn"
        elseif line.needsMailTrip then
            look.colour, look.tag, look.tagColour = "warn", L["in mail"], "warn"
        else
            look.colour, look.tag, look.tagColour = "profit", L["have all"], "profit"
        end

        -- Bought on the auction house today: what it cost, amber when it
        -- came to well over what this list had said.
        if line.paid then
            local where = look.tag
            local function Paid(coins)
                return L.Format("paid %s", Util.FormatMoney(line.paid, { short = true, parts = coins }))
            end
            look.tag = where .. ", " .. Paid(nil)
            look.shorter = { Paid(nil), Paid(2), where }
            if line.overpaid then look.tagColour = "warn" end
        end
        return look
    end

    look.colour = "loss"

    local altName, altCount = self:AltHolder(line.itemID)
    if altName and altCount >= line.shortfall then
        look.colour, look.tag, look.tagColour = "warn", L.Format("on %s", altName), "warn"
        look.shorter = { L["on an alt"] }
        return look
    end

    if line.estimatedCost then
        local function Cost(coins)
            local cost = Util.FormatMoney(line.estimatedCost, { short = true, parts = coins })
            return line.fromVendor and L.Format("|c%svendor|r %s", ns.COLORS.accent, cost) or cost
        end
        look.tag = Cost(nil)
        look.shorter = { Cost(2), Cost(1) }
        -- Amber: what was bought of it today came to well over the estimate.
        look.tagColour = line.overpaid and "warn" or "text"
    else
        look.tag, look.tagColour = L["no price"], "muted"
    end
    return look
end

--- The total along the bottom: what is left to buy. Kept to the money, as it
--- shares the line with the button; a line with no price says so itself.
-- @param lines  the shopping list already built for the rows, so it is not
--   built a second time for the total
function CraftPanel:ShoppingTotalText(lines)
    local cost = ns.Queue:GetShoppingTotal(lines)
    return L.Format("To buy %s", Util.FormatMoney(cost or 0, { short = true }))
end

local function CreateShoppingRow(row)
    row.icon = Theme.CreateItemIcon(row, 13)
    row.icon:SetPoint("TOPLEFT", 8, -3)

    row.count = Theme.CreateLabel(row, "small", "muted", "RIGHT")
    row.count:SetPoint("TOPRIGHT", -8, -4)
    row.count:SetWidth(SHOPPING_COUNT_WIDTH)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("TOPLEFT", 25, -4)
    row.name:SetPoint("TOPRIGHT", row.count, "TOPLEFT", -4, 0)

    row.bar = Theme.CreateBar(row, SHOPPING_BAR_WIDTH, 3)
    row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 25, -19)

    row.tag = Theme.CreateLabel(row, "tiny", "muted", "RIGHT")
    row.tagRight = -8
    row.tag:SetPoint("TOPLEFT", row, "TOPLEFT", 25 + SHOPPING_BAR_WIDTH + 6, -15)
    row.tag:SetPoint("TOPRIGHT", -8, -15)
end

--- The bar and its words sit under the name. A long name wraps rather than
--- ending in "..." (a player's report at the auction house, 2026-10-17), and
--- then pushes them down and the row grows to hold them.
local function PlaceShoppingLine(row, need)
    local barY = need and -(4 + need + 2) or -19
    local tagY = barY + 4
    row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 25, barY)
    row.tag:SetPoint("TOPLEFT", row, "TOPLEFT", 25 + SHOPPING_BAR_WIDTH + 6, tagY)
    row.tag:SetPoint("TOPRIGHT", row, "TOPRIGHT", rawget(row, "tagRight") or -8, tagY)
    if need then row.name.rowNeed = need + 12 end
end

CraftPanel._PlaceShoppingLine = PlaceShoppingLine

local function SetShoppingName(row, text)
    if Theme.SetRowName then Theme.SetRowName(row.name, text) else row.name:SetText(text) end
    local need = rawget(row.name, "rowNeed")
    PlaceShoppingLine(row, type(need) == "number" and need or nil)
end

local function UpdateShoppingRow(row, line)
    local look = CraftPanel:ShoppingLook(line)

    -- The plain name in its rarity colour, greyed once you have it all. Not
    -- the link: its own colour code shows over the label's, and its brackets
    -- read as plain text on a list. Plain until the client has the item; the
    -- redraw on GET_ITEM_INFO_RECEIVED colours it then.
    SetShoppingName(row, Util.GetItemName(line.itemID))
    local r, g, b = Util.GetItemQualityColor(line.itemID)
    if look.colour == "profit" then
        row.name:SetTextColor(Theme.Unpack("muted"))
    elseif r then
        row.name:SetTextColor(r, g, b)
    else
        row.name:SetTextColor(Theme.Unpack("text"))
        CraftPanel.awaitingItemData = true
    end
    Theme.SetItemIcon(row.icon, line.itemID)

    row.count:SetText(look.count)
    row.count:SetTextColor(Theme.Unpack(look.colour))

    row.bar:Set(look.fraction, look.colour)

    -- The first wording that fits beside the bar, rather than one cut off.
    local tags = { look.tag or "" }
    for _, shorter in ipairs(look.shorter or {}) do tags[#tags + 1] = shorter end
    SetFirstThatFits(row.tag, tags)
    row.tag:SetTextColor(Theme.Unpack(look.tagColour or "muted"))
end

-- The sell list's Buy view at the auction house draws the same rows.
CraftPanel.CreateShoppingRow = CreateShoppingRow
CraftPanel.UpdateShoppingRow = UpdateShoppingRow

--- Show the shopping list or not; remembered across sessions.
function CraftPanel:SetShoppingShown(on)
    ns.Config:Set("craftPaneShoppingList", on and true or false)
    self:RefreshQueued()
end

function CraftPanel:IsShoppingShown()
    return ns.Config:Get("craftPaneShoppingList") ~= false
end

--- How tall the queued crafts list is when the shopping list shares the column.
--
-- Its rows, as long as they fit in its share; at least a couple, so a long
-- shopping list never squeezes the crafts out.
-- @param available the height both lists share
-- @param queued how many crafts are queued
function CraftPanel.QueuedListHeight(available, queued)
    local most = math.max(QUEUED_MIN_ROWS, math.floor(available * QUEUED_MAX_SHARE / QUEUED_ROW_HEIGHT))
    return math.max(1, math.min(queued, most)) * QUEUED_ROW_HEIGHT
end

function CraftPanel:BuildQueued()
    if self.queuedFrame then return self.queuedFrame end

    local frame = CreateFrame("Frame", nil, self.frame)
    frame:SetWidth(QUEUED_WIDTH)
    frame:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", QUEUED_GAP, 0)
    -- Kept on screen: beside a wide profession window on a narrow screen it
    -- would otherwise hang off the right edge.
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:Hide()

    Theme.Fill(frame, "window")
    -- The house frame (UI/Titanforged.lua): the gold rim and corner gems.
    if ns.Titanforged then
        ns.Titanforged:Dress(frame)
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    Theme.Halo(frame, 8, 0.08)

    local _, title = ns.Collapse.CreateHeader(frame, L["Queued crafts"])
    self.queuedTitle = title

    local list = Widgets.CreateScrollList(frame, {
        rowHeight = QUEUED_ROW_HEIGHT,
        createRow = CreateQueuedRow,
        updateRow = UpdateQueuedRow,
        -- The craft being made right now is the lit row.
        isSelected = function(entry)
            local active = ns.Crafting and ns.Crafting.active
            return active ~= nil and active.recipeID == entry.recipeID
        end,
        onClick = function(entry, _, mouseButton)
            if mouseButton == "RightButton" and not entry.isDependency then
                ns.Queue:Remove(entry.recipeID)
            end
        end,
    })
    list:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, ns.Collapse.CONTENT_TOP)
    list:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, ns.Collapse.CONTENT_TOP)
    self.queuedList = list

    -- The total and the show/hide switch, along the bottom.
    ns.Collapse.CreateFooter(frame, SHOPPING_FOOTER_HEIGHT)

    local total = Theme.CreateLabel(frame, "small", "text")
    total:SetPoint("LEFT", frame, "BOTTOMLEFT", 14, 24)
    self.shoppingTotal = total

    local toggle = Widgets.CreateButton(frame, L["Hide list"], function()
        CraftPanel:SetShoppingShown(not CraftPanel:IsShoppingShown())
    end, { width = 56, height = 16 })
    toggle:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 16)
    total:SetPoint("RIGHT", toggle, "LEFT", -6, 0)
    self.shoppingToggle = toggle

    local heading = Theme.CreateHeading(frame, L["SHOPPING LIST"])
    heading:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -8)
    self.shoppingHeading = heading

    local columns = Theme.CreateLabel(frame, "tiny", "muted", "RIGHT")
    columns:SetText(L["have / need"])
    columns:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", 0, -8)
    heading.rule:SetPoint("RIGHT", columns, "LEFT", -6, 0)
    self.shoppingColumns = columns

    local shopping = Widgets.CreateScrollList(frame, {
        rowHeight = SHOPPING_ROW_HEIGHT,
        createRow = CreateShoppingRow,
        updateRow = UpdateShoppingRow,
        -- The Queue tab's tooltip: need, bags, bank, other characters, cost.
        onEnter = function(row, line)
            if ns.UI and ns.UI.ShowMaterialTooltip then ns.UI.ShowMaterialTooltip(row, line) end
        end,
        onLeave = function() GameTooltip:Hide() end,
    })
    shopping:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -6)
    shopping:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    shopping:SetPoint("BOTTOM", frame, "BOTTOM", 0, 14 + SHOPPING_FOOTER_HEIGHT)
    self.shoppingList = shopping

    self.queuedFrame = frame
    return frame
end

--- Is there room for the queued crafts to the right of the pane?
--
-- Kept on screen, they used to be pushed back over the pane itself when there
-- was not, covering its sort button and recipes (a screenshot with the
-- auction house open, 2026-10-01). Out of the way instead, as the sell list
-- steps aside for the character window.
-- @param paneRight the pane's right edge, nil when not laid out yet
-- @param screenRight the screen's right edge, nil when unknown
function CraftPanel.QueuedFits(paneRight, screenRight)
    if type(paneRight) ~= "number" or type(screenRight) ~= "number" then return true end
    return paneRight + QUEUED_GAP + QUEUED_WIDTH <= screenRight
end

--- Show the queued crafts beside the pane while anything is queued.
function CraftPanel:RefreshQueued()
    local wanted = self.frame and self.frame:IsShown()
        and not self:IsCollapsed() and ns.Queue:Count() > 0
        and CraftPanel.QueuedFits(self.frame:GetRight(), UIParent and UIParent:GetRight())

    if not wanted then
        if self.queuedFrame then self.queuedFrame:Hide() end
        return
    end

    local entries = ns.Queue:GetAll()

    local frame = self:BuildQueued()
    frame:SetHeight(self.frame:GetHeight())
    local opening = not frame:IsShown()
    frame:Show()
    if opening and ns.Motion then ns.Motion:Open(frame, 0) end

    self.queuedTitle:SetText(L.Format("Queued crafts (%d)", #entries))
    self.queuedOpen = self:GetOpenRecipeIDs()

    -- Between the title and the footer, shared with the shopping list when
    -- it is showing.
    local available = frame:GetHeight() + ns.Collapse.CONTENT_TOP - 14 - SHOPPING_FOOTER_HEIGHT
    local shown = self:IsShoppingShown()

    -- Built once for the rows and the total: it walks the queue, the bags
    -- and every character's recipes, and this runs on every queue click.
    local lines = ns.Queue:GetShoppingList()

    if shown then
        self.queuedList:SetHeight(CraftPanel.QueuedListHeight(available, #entries))
        self.shoppingList:SetData(lines)
    else
        self.queuedList:SetHeight(math.max(QUEUED_ROW_HEIGHT, available - 4))
    end

    self.shoppingHeading:SetShown(shown)
    self.shoppingColumns:SetShown(shown)
    self.shoppingList:SetShown(shown)
    self.shoppingToggle:SetText(shown and L["Hide list"] or L["Shopping"])
    self.shoppingToggle.tooltipText = not shown
        and L["Show what the queue still needs, minus what you have"] or nil
    self.shoppingTotal:SetText(self:ShoppingTotalText(lines))

    self.queuedList:SetData(entries)
end

--- The queue just changed: show it now.
--
-- A full refresh prices every recipe the profession shows, so it waits a
-- moment (RequestRefresh) to take a burst of changes in one pass. A player
-- clicking + three times does not want to wait for it. kronosbest on
-- CurseForge: "a noticeable ~1s delay from the button is pressed to when it
-- shows up in queued crafts". So the cheap parts, the queued numbers on the
-- rows already on screen, the queued crafts list, the buttons and the total,
-- are redrawn on the spot, and the full refresh follows as before.
function CraftPanel:OnQueueChanged()
    if self.frame and self.frame:IsShown() and not self:IsCollapsed() and self.list then
        for _, line in ipairs(self.list:GetData() or {}) do
            local _, entry = ns.Queue:Find(line.recipeID, true)
            line.queued = entry and entry.quantity or 0
        end
        self.list:Refresh()

        self:UpdateCraftButton()
        self:UpdateClearButton()
        self:UpdateSummary()
    end

    self:RefreshQueued()
    self:RequestRefresh()
end

--- Ask for a refresh soon, rather than taking one now.
--
-- A refresh analyses every recipe the profession window is showing, which is
-- several hundred on a maxed profession. The events that invalidate this pane
-- -- bags changing, a craft finishing, the recipe cache filling in -- arrive
-- in bursts, so a burst costs one pass instead of ten.
function CraftPanel:RequestRefresh()
    if not self:IsShown() or self.refreshPending then return end

    self.refreshPending = true

    C_Timer.After(0.35, function()
        CraftPanel.refreshPending = false
        CraftPanel:RefreshInSlices()
    end)
end

function CraftPanel:Hide()
    -- A refresh still spread over frames would price on for a pane nobody
    -- sees, and throw the result away at the end.
    self:StopSlicedRefresh()
    if self.frame then self.frame:Hide() end
end

function CraftPanel:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

--- Show or hide the pane by hand.
--
-- Reports what it did rather than what it tried: on this client a command that
-- errors prints nothing at all unless scriptErrors is on, so "it isn't doing
-- anything" has to be answerable from the chat frame.
function CraftPanel:Toggle()
    if self:IsShown() then
        self:Hide()
        ns.Print(L["craft pane hidden. It comes back when you open a profession."])
        return
    end

    self:Attach()

    if self:IsShown() then
        local _, frameName = self:FindTradeSkillFrame()

        local count = #self:GetRows({ sortBy = self.sortBy, ignoreLimit = self:IgnoringLimit() })
        ns.Print(frameName
            and L.Format("craft pane shown, docked to the profession window, %d recipe(s) listed.", count)
            or L.Format("craft pane shown (no profession window open), %d recipe(s) listed.", count))
    else
        ns.Warn(L["the craft pane would not show."])
    end
end

--- Item data arrived: colour the names that were waiting for it.
function CraftPanel:OnItemInfo()
    if self.itemRedrawQueued or not self.awaitingItemData then return end
    if not self:IsShown() then return end

    self.itemRedrawQueued = true
    C_Timer.After(0.2, function()
        CraftPanel.itemRedrawQueued = false
        CraftPanel.awaitingItemData = false
        if not CraftPanel:IsShown() then return end
        for _, list in ipairs({ CraftPanel.list, CraftPanel.queuedList, CraftPanel.shoppingList }) do
            if list and list:IsVisible() then list:Refresh() end
        end
    end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CraftPanel:OnEnable()
    -- Blizzard's profession UI is load-on-demand, so on the first open of a
    -- session the frame may not exist yet when this event arrives. Re-anchor
    -- shortly after in case it appeared late.
    ns.RegisterEvent(self, "TRADE_SKILL_SHOW", function()
        CraftPanel:Attach()

        C_Timer.After(0.5, function()
            if ns.Crafting and ns.Crafting.isTradeSkillOpen then
                CraftPanel:Attach()
            end
        end)
    end)

    ns.RegisterEvent(self, "TRADE_SKILL_CLOSE", function()
        CraftPanel:Hide()
    end)

    -- A name drawn before the client had its item gets its rarity colour
    -- when the item arrives: the rows on screen are drawn again, once for a
    -- burst, and only while a row waits and the pane shows.
    ns.RegisterEvent(self, "GET_ITEM_INFO_RECEIVED", function()
        CraftPanel:OnItemInfo()
    end)

    ns.RegisterCommand("pane", L["show or hide the craft pane"], function()
        CraftPanel:Toggle()
    end)
end
