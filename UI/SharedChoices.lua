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
-- useTomTom and arrowRoute (true or false), arrowSize (50, 75 or 100),
-- muteSounds (true or false).
--
-- Mute All Sounds (a player asked, the owner said build it, 2026-11-12):
-- one switch quiets every sound every Blackthornes addon plays. The state
-- lives on the shared board, so all addons go quiet the moment it is
-- ticked in any one. Each addon also keeps it in its own save as
-- `muteSounds` and `muteSoundsAt` (never rename them). Each addon joins
-- with how to read those two (readMute, nil until its save is loaded), and
-- the first sound asked for after a save loads takes what it kept, the
-- newest winning, so an addon that was turned off when the box was ticked
-- still goes quiet.
--
--   ns.SharedChoices:Join(name, write, readMute)   readMute() -> on, at
--   ns.SharedChoices:SetMute(on)        the player changed it here
--   ns.SharedChoices:Muted()            true while every sound is off
--   ns.Muted()                          the same, for the play calls

local _, ns = ...

local Shared = {}
ns.SharedChoices = Shared

Shared.CHOICES = {
    textSize = true, windowStyle = true, effects = true,
    useTomTom = true, arrowRoute = true, arrowSize = true,
    muteSounds = true,
}

local board = rawget(_G, "BlackthornesSharedChoices")
if type(board) ~= "table" then
    board = {}
    _G.BlackthornesSharedChoices = board
end
if type(board.members) ~= "table" then board.members = {} end
if type(board.mute) ~= "table" then board.mute = { on = false, at = 0 } end
if type(board.muteReaders) ~= "table" then board.muteReaders = {} end
Shared.board = board

--- At login: what this addon's save says. The newest answer among the
--- addons loaded wins.
function Shared:NoteMute(on, at)
    at = tonumber(at) or 0
    if at > (tonumber(board.mute.at) or 0) then
        board.mute.on = on == true
        board.mute.at = at
    end
end

--- The player ticked or unticked Mute All Sounds here: every addon hears
--- it at once, through the board, and is told so it saves it too. The
--- caller saves it in its own addon. Returns the time it was set.
function Shared:SetMute(on, at)
    board.mute.on = on == true
    board.mute.at = tonumber(at) or (type(time) == "function" and time()) or 0
    self:Changed("muteSounds", board.mute.on)
    return board.mute.at
end

--- Each save read once it has loaded: what it kept counts, newest first.
local function ReadSaves()
    for name, read in pairs(board.muteReaders) do
        local ok, on, at = pcall(read)
        if ok and on ~= nil then
            board.muteReaders[name] = nil
            Shared:NoteMute(on, at)
        elseif not ok then
            board.muteReaders[name] = nil
        end
    end
end

function Shared:Muted()
    if next(board.muteReaders) then ReadSaves() end
    return board.mute.on == true
end

--- For every play call: true while every Blackthornes sound is off.
function ns.Muted()
    return Shared:Muted()
end

--- This addon signs up, with how it writes a choice.
function Shared:Join(name, write, readMute)
    if type(name) ~= "string" or type(write) ~= "function" then return end
    self.name = name
    board.members[name] = write
    if type(readMute) == "function" then board.muteReaders[name] = readMute end
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
