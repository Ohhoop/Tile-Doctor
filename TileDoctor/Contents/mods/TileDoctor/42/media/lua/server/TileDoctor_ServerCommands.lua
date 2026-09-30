require "TileDoctor_Core"
require "TileDoctor_Commands"

--- Runs the requested Tile Doctor command when the sender is allowed to.
local function onClientCommand(module, command, player, args)
    if module ~= TileDoctor.COMMAND_MODULE or not TileDoctor.isCommand(command) then
        return
    end
    if not TileDoctor.canUse(player) then
        print("TileDoctor: " .. tostring(command) .. " denied for " .. tostring(player and player:getUsername()))
        return
    end
    TileDoctor.runCommand(command, args)
end

Events.OnClientCommand.Add(onClientCommand)
