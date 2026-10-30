-- Core/WhatsNewText.lua
-- Written by tools/make_whatsnew.py from NEWS.md. Never edit it by hand:
-- change NEWS.md and run the tool. UI/WhatsNew.lua shows it.

local _, ns = ...

ns.WHATS_NEW = {
    { version = "0.8.0", lines = {
        "Every window has a new look that matches the other Blackthornes add-ons.",
        "The Disenchanting tab now has a Buy button for gear deals.",
    } },
    { version = "0.7.0", lines = {
        "The auction house now shows a Potential Sale Total that counts up as you list.",
        "Enchanters now see disenchant results and chances on item tooltips.",
        "The minimap button has a new Blackthornes badge.",
        "Show the way now puts a gold marker on your map.",
    } },
    { version = "0.6.0", lines = {
        "The Road to 300 now counts what your other characters carry.",
        "One minimap button now opens all your Blackthornes add-ons.",
    } },
}
