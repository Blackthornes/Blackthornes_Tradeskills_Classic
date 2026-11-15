-- Every sound Tradeskills plays goes on the Master channel.
--
-- A player with only Master turned on heard the sale sound but not
-- Crafting Finishes (2026-10-22): a PlaySound with no channel plays on
-- Sound Effects, so with that off it was silent. This reads every file
-- the TOC lists and fails on any PlaySound or PlaySoundFile call that
-- names no channel.

local toc = io.open(lfs_cwd .. "/Blackthornes_TS.toc"):read("*a")
local bad, seen = {}, 0
for path in toc:gmatch("[^\r\n]+") do
    if path:match("%.lua$") and not path:match("^#") then
        local file = io.open(lfs_cwd .. "/" .. path:gsub("\\", "/"))
        if file then
            local n = 0
            for line in file:lines() do
                n = n + 1
                -- Calls go through ns.PlaySound (Mute All Sounds), falling
                -- back to the game's own when a test's ns has none.
                local plain = line:gsub("ns%.PlaySound%a* or ", "")
                for args in plain:gmatch("pcall%(PlaySound%a*,%s*(.-)%)%s*[%a%)]*$") do
                    seen = seen + 1
                    if not args:find('"Master"', 1, true) then
                        bad[#bad + 1] = path .. ":" .. n .. ": " .. line:match("^%s*(.-)%s*$")
                    end
                end
            end
            file:close()
        end
    end
end

print(("  %d sound calls read"):format(seen))
for _, where in ipairs(bad) do print("  FAIL  no channel: " .. where) end
assert(seen > 10, "found too few sound calls; the pattern is wrong")
assert(#bad == 0, #bad .. " sound call(s) name no channel")
print("  ok    every sound plays on Master")
