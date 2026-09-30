require "TileDoctor_Core"
require "TileDoctor_ExamineWindow"

--- Opens the Tile Doctor window following the player.
local function onOpenTileDoctor(playerObj)
    TileDoctorExamineWindow.open(playerObj)
end

--- Adds the Tile Doctor option to the world context menu for allowed players.
local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not TileDoctor.canUse(playerObj) then
        return
    end
    if test and ISWorldObjectContextMenu.Test then
        return true
    end
    context:addOption("Tile Doctor", playerObj, onOpenTileDoctor)
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
