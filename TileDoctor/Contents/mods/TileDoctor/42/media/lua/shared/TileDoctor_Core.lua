require "luautils"

TileDoctor = TileDoctor or {}

TileDoctor.COMMAND_MODULE = "TileDoctor"
TileDoctor.MOD_ID = "TileDoctor"

local DEV_SUFFIX = "-DEV"

TileDoctor.OUTLINE_COLOR = { r = 1.0, g = 0.9, b = 0.0, a = 1.0 }

--- Returns true when this copy of the mod is the development build.
function TileDoctor.isDevBuild()
    return luautils.stringEnds(TileDoctor.MOD_ID, DEV_SUFFIX)
end

--- Returns true when the player is allowed to use Tile Doctor: always in solo, only with the brush tool capability in multiplayer.
function TileDoctor.canUse(player)
    if not isClient() and not isServer() then
        return true
    end
    if not player then
        return false
    end
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.UseBrushToolManager)
end
