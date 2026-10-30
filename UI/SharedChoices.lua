-- Blackthornes -- UI/SharedChoices.lua
-- Choices set once for every addon (the owner said build it, 2026-10-29,
-- from the unified look's mockups): Text Size, Window Style, Effects, Use
-- TomTom, Guide Me and Arrow Size. A change to one in any addon is written
-- to every Blackthornes addon loaded, as the sister note's "Sister Addons"
-- has done since 2026-10-11. Nothing moves until the player changes one, and
-- every addon keeps its own saved key under its own name.
--
-- There is no shared core addon: every copy signs up in
-- `_G.BlackthornesSharedChoices`. Each addon joins with how it writes a
-- choice its own way (its own setter, so a live change shows at once), and
-- calls :Changed after the player changes one there. A change heard from a
-- sister is never sent on again. The same file in all five addons (a fix to
-- it belongs in all five).
--
--   ns.SharedChoices:Join(name, write)   write(choice, value)
--   ns.SharedChoices:Changed(choice, value)
--
-- Choices and values: textSize ("normal", "large", "larger"), windowStyle
-- ("titanforged", "blizzard"), effects ("full", "subtle", "off"),
-- useTomTom and arrowRoute (true or false), arrowSize (50, 75 or 100).

local _, ns = ...

local Shared = {}
ns.SharedChoices = Shared

Shared.CHOICES = {
    textSize = true, windowStyle = true, effects = true,
    useTomTom = true, arrowRoute = true, arrowSize = true,
}

local board = rawget(_G, "BlackthornesSharedChoices")
if type(board) ~= "table" then
    board = {}
    _G.BlackthornesSharedChoices = board
end
if type(board.members) ~= "table" then board.members = {} end
Shared.board = board

--- This addon signs up, with how it writes a choice.
function Shared:Join(name, write)
    if type(name) ~= "string" or type(write) ~= "function" then return end
    self.name = name
    board.members[name] = write
end

--- The player changed a choice in this addon: every other addon loaded
--- takes it too. Returns how many others took it.
function Shared:Changed(choice, value)
    if not self.CHOICES[choice] then return 0 end
    -- Heard from a sister: written here already, never sent on again.
    if board.busy then return 0 end
    board.busy = true
    local count = 0
    for name, write in pairs(board.members) do
        if name ~= self.name then
            local ok, err = pcall(write, choice, value)
            if ok then
                count = count + 1
            elseif ns.Debug then
                ns.Debug("shared choice:", tostring(err))
            end
        end
    end
    board.busy = false
    return count
end

return Shared
