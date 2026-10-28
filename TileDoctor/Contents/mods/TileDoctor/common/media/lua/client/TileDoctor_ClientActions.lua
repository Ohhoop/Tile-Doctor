require "TileDoctor_Core"
require "TileDoctor_Commands"

TileDoctorClientActions = {}

--- Sends the command to the server in multiplayer, or runs it directly in solo.
function TileDoctorClientActions.request(playerObj, command, args)
    if isClient() then
        sendClientCommand(playerObj, TileDoctor.COMMAND_MODULE, command, args)
        return
    end
    TileDoctor.runCommand(command, args)
end

--- Applies the display heights sent by the server after an object reset to the objects of the square.
local function onServerCommand(module, command, args)
    if module ~= TileDoctor.COMMAND_MODULE or command ~= TileDoctor.COMMAND_RESTORE_OFFSETS then
        return
    end
    local square = TileDoctor.getSquareFromArgs(args)
    if square and type(args.offsets) == "table" then
        TileDoctor.applyRenderOffsets(square, args.offsets)
    end
end

Events.OnServerCommand.Add(onServerCommand)
