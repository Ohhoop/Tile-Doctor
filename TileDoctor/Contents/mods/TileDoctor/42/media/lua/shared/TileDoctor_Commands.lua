require "TileDoctor_Core"
require "TileDoctor_ObjectRepair"

TileDoctor.COMMAND_REMOVE_OBJECT = "removeObject"
TileDoctor.COMMAND_RESET_OBJECT = "resetObject"
TileDoctor.COMMAND_REMOVE_CORPSE = "removeCorpse"
TileDoctor.COMMAND_REMOVE_VEHICLE = "removeVehicle"

--- Returns true when the value is a whole number.
local function isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

--- Returns the loaded square designated by the arguments, or nil when the coordinates are invalid or not loaded.
function TileDoctor.getSquareFromArgs(args)
    if type(args) ~= "table" or not isInteger(args.x) or not isInteger(args.y) or not isInteger(args.z) then
        return nil
    end
    return getCell():getGridSquare(args.x, args.y, args.z)
end

--- Returns true when the arguments carry a whole index and a text key.
local function hasIndexAndKey(args)
    return isInteger(args.index) and type(args.key) == "string"
end

--- Returns a handler that finds the element designated by the index and key of the arguments with find, then applies act to it.
local function keyedHandler(find, act)
    return function(square, args)
        if not hasIndexAndKey(args) then
            return
        end
        local element = find(square, args.index, args.key)
        if element then
            act(square, element)
        end
    end
end

--- Removes the vehicle whose id is given in the arguments when it covers the square.
local function removeVehicleHandler(square, args)
    if not isInteger(args.id) then
        return
    end
    local vehicle = square:getVehicleContainer()
    if vehicle and vehicle:getId() == args.id then
        TileDoctor.removeVehicle(vehicle)
    end
end

local HANDLERS = {
    [TileDoctor.COMMAND_REMOVE_OBJECT] = keyedHandler(TileDoctor.findObject, TileDoctor.removeObject),
    [TileDoctor.COMMAND_RESET_OBJECT] = keyedHandler(TileDoctor.findObject, TileDoctor.resetObject),
    [TileDoctor.COMMAND_REMOVE_CORPSE] = keyedHandler(TileDoctor.findCorpse, TileDoctor.removeCorpse),
    [TileDoctor.COMMAND_REMOVE_VEHICLE] = removeVehicleHandler,
}

--- Returns true when the command is a known Tile Doctor command.
function TileDoctor.isCommand(command)
    return HANDLERS[command] ~= nil
end

--- Validates the arguments and runs the command on the square they designate; does nothing when the command is unknown or the target is invalid.
function TileDoctor.runCommand(command, args)
    local handler = HANDLERS[command]
    if not handler then
        return
    end
    local square = TileDoctor.getSquareFromArgs(args)
    if not square then
        return
    end
    handler(square, args)
end
