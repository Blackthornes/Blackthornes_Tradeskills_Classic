-- Core/WhatsNewText.lua
-- Written by tools/make_whatsnew.py from NEWS.md. Never edit it by hand:
-- change NEWS.md and run the tool. UI/WhatsNew.lua shows it.

local _, ns = ...

ns.WHATS_NEW = {
    { version = "0.5.0", lines = {
        "The Profit tab now has a Shuffles view.",
        "The auction house now shows a Sale Total counter.",
        "You can set the highest price you will sell for.",
    } },
    { version = "0.4.0", lines = {
        "The Road to 300 and Learn Next now send you to the closest trainer.",
        "The Road to 300 lets you pick recipes by lowest cost or real cost.",
    } },
    { version = "0.3.0", lines = {
        "The auction house List button now lists in one press.",
        "The auction house Buy button buys your queue's materials stack by stack.",
        "Item tooltips show what a vendor sells the item for.",
    } },
}
