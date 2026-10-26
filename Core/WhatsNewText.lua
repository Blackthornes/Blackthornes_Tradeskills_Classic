-- Core/WhatsNewText.lua
-- Written by tools/make_whatsnew.py from NEWS.md. Never edit it by hand:
-- change NEWS.md and run the tool. UI/WhatsNew.lua shows it.

local _, ns = ...

ns.WHATS_NEW = {
    { version = "0.2.0", lines = {
        "Price Order picks whether TSM or Auctionator prices come first.",
        "Friends shows which of your friends can make a craft.",
        "Road to 300 says when you still need to buy a recipe, and queues its craft once you learn it.",
    } },
    { version = "0.1.0", lines = {
        "Tradeskills is here for Classic Era. Level Up shows the cheapest craft for your next skill point.",
        "Road to 300 lays out every step to 300 and what it costs.",
        "Learn Next shows which recipes to learn and where to find the trainer.",
        "The craft queue adds up your materials, and the Craft button crafts with one click.",
        "Scan the auction house for prices.",
    } },
}
