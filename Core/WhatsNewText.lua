-- Core/WhatsNewText.lua
-- Written by tools/make_whatsnew.py from NEWS.md. Never edit it by hand:
-- change NEWS.md and run the tool. UI/WhatsNew.lua shows it.

local _, ns = ...

ns.WHATS_NEW = {
    { version = "0.10.0", lines = {
        "The auction house tabs now match the other Blackthornes add-ons.",
        "Search All now opens the buy plan for the first item.",
        "Item icons now have a ring and a name colour that match their quality.",
        "Stack counts show on the corner of item icons.",
        "Items show a small mark and colour for what to do with them.",
        "The sell list shows each price in gold, silver and copper coins.",
    } },
    { version = "0.9.0", lines = {
        "All your Blackthornes add-ons now open in one window, with a button for each add-on down the side.",
        "The window moves beside the auction house, mailbox, vendor and trainer when you open them.",
        "The auction house now shows the price of the item you searched for.",
    } },
    { version = "0.8.0", lines = {
        "Every window has a new look that matches the other Blackthornes add-ons.",
        "The Disenchanting tab now has a Buy button for gear deals.",
    } },
}
