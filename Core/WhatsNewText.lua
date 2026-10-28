-- Core/WhatsNewText.lua
-- Written by tools/make_whatsnew.py from NEWS.md. Never edit it by hand:
-- change NEWS.md and run the tool. UI/WhatsNew.lua shows it.

local _, ns = ...

ns.WHATS_NEW = {
    { version = "0.6.0", lines = {
        "The Road to 300 now counts what your other characters carry.",
        "One minimap button now opens all your Blackthornes add-ons.",
    } },
    { version = "0.5.0", lines = {
        "The Profit tab now has a Shuffles view.",
        "The auction house now shows a Sale Total counter.",
        "You can set the highest price you will sell for.",
    } },
    { version = "0.4.0", lines = {
        "The Road to 300 and Learn Next now send you to the closest trainer.",
        "The Road to 300 lets you pick recipes by lowest cost or real cost.",
    } },
}
