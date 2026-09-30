require "TileDoctor_Core"
require "luautils"

TileDoctor.COMMAND_RESTORE_OFFSETS = "restoreOffsets"

local GENERATOR_ITEM_RANGES = {
    { first = 0, last = 3, itemType = "Base.Generator" },
    { first = 4, last = 7, itemType = "Base.Generator_Old" },
    { first = 8, last = 11, itemType = "Base.Generator_Yellow" },
    { first = 12, last = 15, itemType = "Base.Generator_Blue" },
}

local GENERATOR_SPRITE_PREFIX = "appliances_misc_01_"
local DIRT_FLOOR_SPRITE = "blends_natural_01_64"
local WOODEN_FLOOR_SPRITE = "carpentry_02_58"

--- Returns the sprite name of the object, or an empty string when it has none.
function TileDoctor.getSpriteName(object)
    local sprite = object:getSprite()
    return sprite and sprite:getName() or ""
end

--- Returns the item lying on the ground represented by the object, or nil when the object is not a dropped item.
function TileDoctor.getWorldItem(object)
    if not instanceof(object, "IsoWorldInventoryObject") then
        return nil
    end
    return object:getItem()
end

--- Returns a key identifying the object: the item type and id for a dropped item, the sprite name otherwise.
function TileDoctor.getObjectKey(object)
    local item = TileDoctor.getWorldItem(object)
    if item then
        return "item:" .. item:getFullType() .. ":" .. tostring(item:getID())
    end
    return TileDoctor.getSpriteName(object)
end

--- Returns a key identifying the corpse by its outfit and by whether it was a zombie.
function TileDoctor.getCorpseKey(body)
    return "corpse:" .. tostring(body:getOutfitName()) .. ":" .. tostring(body:isZombie())
end

--- Returns the element at the given index of the list when its key, computed by keyOf, still matches, or nil otherwise.
local function findByKey(list, index, key, keyOf)
    if index < 0 or index >= list:size() then
        return nil
    end
    local element = list:get(index)
    if keyOf(element) ~= key then
        return nil
    end
    return element
end

--- Returns the object at the given index of the square when its key still matches, or nil otherwise.
function TileDoctor.findObject(square, index, key)
    return findByKey(square:getObjects(), index, key, TileDoctor.getObjectKey)
end

--- Returns the corpse at the given index of the square's corpses when its key still matches, or nil otherwise.
function TileDoctor.findCorpse(square, index, key)
    return findByKey(square:getDeadBodys(), index, key, TileDoctor.getCorpseKey)
end

--- Removes the corpse from the square.
function TileDoctor.removeCorpse(square, body)
    square:removeCorpse(body, false)
end

--- Removes the vehicle from the world permanently.
function TileDoctor.removeVehicle(vehicle)
    vehicle:permanentlyRemove()
end

--- Refreshes the collision and render state of the square and its neighbours.
local function refreshSquare(square)
    square:RecalcProperties()
    square:RecalcAllWithNeighbours(true)
    square:setSquareChanged()
end

--- Returns the names of the sprites attached on top of the object, such as wallpaper, trim or blend tiles.
local function getAttachedSpriteNames(object)
    local names = {}
    local attached = object:getAttachedAnimSprite()
    if not attached then
        return names
    end
    for i = 0, attached:size() - 1 do
        local sprite = attached:get(i):getParentSprite()
        if sprite and sprite:getName() then
            table.insert(names, sprite:getName())
        end
    end
    return names
end

--- Attaches the named sprites on top of the object.
local function attachSprites(object, spriteNames)
    for _, name in ipairs(spriteNames) do
        local sprite = getSprite(name)
        if sprite then
            object:AttachExistingAnim(sprite, 0, 0, false, 0, false, 0.0)
        end
    end
end

--- Lays a floor with the given sprite on the square, which also sends it to the clients, then attaches the given sprites and sends them to the clients; returns false when no floor could be laid.
local function placeFloor(square, spriteName, attachedNames)
    local floor = square:addFloor(spriteName)
    if not floor then
        return false
    end
    if #attachedNames > 0 then
        attachSprites(floor, attachedNames)
        floor:transmitUpdatedSpriteToClients()
    end
    return true
end

--- Returns true when the object carries a sprite flagged as water.
local function isWater(object)
    local sprite = object:getSprite()
    local props = sprite and sprite:getProperties()
    return props ~= nil and props:has(IsoFlagType.water)
end

--- Returns the sprite that replaces a removed floor and the sprites to attach on it: the same water tile for water, dirt on the ground and basement levels, a low quality wooden floor above.
local function getReplacementFloor(square, floor)
    if isWater(floor) then
        return TileDoctor.getSpriteName(floor), getAttachedSpriteNames(floor)
    end
    if square:getZ() <= 0 then
        return DIRT_FLOOR_SPRITE, {}
    end
    return WOODEN_FLOOR_SPRITE, {}
end

--- Removes this single object from the square, leaving the other parts of a multi-square object in place; a removed floor is replaced by its replacement floor.
function TileDoctor.removeObject(square, object)
    if object == square:getFloor() then
        placeFloor(square, getReplacementFloor(square, object))
    else
        square:transmitRemoveItemFromSquare(object, false)
    end
    refreshSquare(square)
end

--- Copies the build settings of a player built object onto its replacement and restores full health.
local function copyThumpableSettings(source, target)
    target:setMaxHealth(source:getMaxHealth())
    target:setHealth(source:getMaxHealth())
    target:setIsThumpable(source:isThumpable())
    target:setCanPassThrough(source:isCanPassThrough())
    target:setBlockAllTheSquare(source:isBlockAllTheSquare())
    target:setIsHoppable(source:isHoppable())
    target:setIsDismantable(source:isDismantable())
    target:setCanBarricade(source:getCanBarricade())
    target:setThumpDmg(source:getThumpDmg())
    target:setBreakSound(source:getBreakSound())
    target:setIsDoor(source:isDoor())
    target:setIsDoorFrame(source:isDoorFrame())
    target:setIsFloor(source:isFloor())
    target:setIsStairs(source:isStairs())
    target:setCanBeLockByPadlock(source:canBeLockByPadlock())
end

--- Creates a fresh player built object with the same sprites and build settings as the source; a built door is rebuilt closed from its closed and open sprites.
local function createThumpable(cell, square, source, spriteName)
    local openSprite = source:getOpenSprite()
    local replacement
    if source:isDoor() and openSprite and openSprite:getName() then
        local closedName = source:getClosedSpriteTextureName() or spriteName
        replacement = IsoThumpable.new(cell, square, closedName, openSprite:getName(), source:getNorth(), {})
    else
        replacement = IsoThumpable.new(cell, square, spriteName, source:getNorth(), {})
    end
    copyThumpableSettings(source, replacement)
    return replacement
end

--- Creates a fresh curtain with the same sprite and orientation as the source, open or closed like the source.
local function createCurtain(cell, square, source, spriteName)
    local isOpen = source:IsOpen()
    local replacement = IsoCurtain.new(cell, square, getSprite(spriteName), source:getNorth(), not isOpen)
    if not isOpen then
        replacement:ToggleDoorSilent()
    end
    return replacement
end

--- Returns the generator item type matching the generator sprite, or nil when the sprite is not a known generator.
local function getGeneratorItemType(_object, spriteName)
    if not luautils.stringStarts(spriteName, GENERATOR_SPRITE_PREFIX) then
        return nil
    end
    local index = tonumber(string.sub(spriteName, #GENERATOR_SPRITE_PREFIX + 1))
    if not index then
        return nil
    end
    for _, range in ipairs(GENERATOR_ITEM_RANGES) do
        if index >= range.first and index <= range.last then
            return range.itemType
        end
    end
    return nil
end

--- Creates a fresh generator from a new generator item, empty and switched off, facing like the source; the generator adds itself to the square and to the clients.
local function createGenerator(cell, square, source, spriteName)
    local replacement = IsoGenerator.new(instanceItem(getGeneratorItemType(source, spriteName)), cell, square)
    replacement:setSprite(getSprite(spriteName))
    return replacement
end

--- Creates a fresh light switch or lamp for the room of the square, with its light source.
local function createLightSwitch(cell, square, _source, spriteName)
    local replacement = IsoLightSwitch.new(cell, square, getSprite(spriteName), square:getRoomID())
    replacement:addLightSourceFromSprite()
    replacement:setActivated(true)
    return replacement
end

--- Creates a fresh undressed mannequin with the given sprite.
local function createMannequin(cell, square, _source, spriteName)
    local replacement = IsoMannequin.new(cell, square, getSprite(spriteName))
    replacement:setSquare(square)
    return replacement
end

--- Creates a fresh empty feeding trough part with the given sprite.
local function createFeedingTrough(_cell, square, _source, spriteName)
    return IsoFeedingTrough.new(square, spriteName, nil)
end

--- Returns a factory creating an object of the given class from the cell, the square and the sprite only.
local function spriteFactory(classTable)
    return function(cell, square, _source, spriteName)
        return classTable.new(cell, square, getSprite(spriteName))
    end
end

--- Returns a factory creating an object of the given class from the cell, the square, the sprite and the orientation of the source.
local function northFactory(classTable)
    return function(cell, square, source, spriteName)
        return classTable.new(cell, square, getSprite(spriteName), source:getNorth())
    end
end

--- Adds the replacement to the square at the given index, which also creates its containers.
local function addToSquare(square, replacement, index)
    square:AddSpecialObject(replacement, index)
end

--- Sends the replacement to the clients.
local function sendToClients(replacement)
    if isServer() then
        replacement:transmitCompleteItemToClients()
    end
end

--- Does nothing, for objects whose constructor already added them to the square.
local function handledByConstructor()
end

--- Sends the sprite and attached sprites of an object that the clients already know.
local function sendSpriteToClients(replacement)
    replacement:transmitUpdatedSpriteToClients()
end

--- Returns true when the map door is closed; only a closed door can be rebuilt.
local function isDoorClosed(object)
    return not object:IsOpen()
end

--- Returns true when the window is closed and intact; only a closed and intact window can be rebuilt.
local function isWindowIntact(object)
    return not object:IsOpen() and not object:isSmashed() and not object:isGlassRemoved() and not object:isDestroyed()
end

local FACTORIES = {
    IsoObject = { create = spriteFactory(IsoObject) },
    IsoDoor = { create = northFactory(IsoDoor), accepts = isDoorClosed },
    IsoWindow = { create = northFactory(IsoWindow), accepts = isWindowIntact },
    IsoWindowFrame = { create = northFactory(IsoWindowFrame) },
    IsoThumpable = { create = createThumpable },
    IsoCurtain = { create = createCurtain },
    IsoStove = { create = spriteFactory(IsoStove) },
    IsoBarbecue = { create = spriteFactory(IsoBarbecue) },
    IsoFireplace = { create = spriteFactory(IsoFireplace) },
    IsoClothingWasher = { create = spriteFactory(IsoClothingWasher) },
    IsoClothingDryer = { create = spriteFactory(IsoClothingDryer) },
    IsoCombinationWasherDryer = { create = spriteFactory(IsoCombinationWasherDryer) },
    IsoCompost = { create = spriteFactory(IsoCompost) },
    IsoRadio = { create = spriteFactory(IsoRadio) },
    IsoTelevision = { create = spriteFactory(IsoTelevision) },
    IsoJukebox = { create = spriteFactory(IsoJukebox) },
    IsoLightSwitch = { create = createLightSwitch },
    IsoMannequin = { create = createMannequin },
    IsoFeedingTrough = { create = createFeedingTrough },
    IsoGenerator = { create = createGenerator, place = handledByConstructor, publish = sendSpriteToClients, accepts = getGeneratorItemType },
}

--- Returns true when the object is of a class that can be rebuilt, its sprite exists in the game and its class accepts its current state.
function TileDoctor.canResetObject(object)
    local factory = FACTORIES[getClassSimpleName(object)]
    if not factory then
        return false
    end
    local spriteName = TileDoctor.getSpriteName(object)
    if spriteName == "" or getSprite(spriteName) == nil then
        return false
    end
    if factory.accepts == nil then
        return true
    end
    local accepted = factory.accepts(object, spriteName)
    return accepted ~= nil and accepted ~= false
end

--- Returns, for each container of the object, whether it has already been searched.
local function getContainersExplored(object)
    local explored = {}
    for i = 0, object:getContainerCount() - 1 do
        explored[i] = object:getContainerByIndex(i):isExplored()
    end
    return explored
end

--- Marks every container of the object as searched, except those that the original object had left unsearched.
local function applyContainersExplored(object, explored)
    for i = 0, object:getContainerCount() - 1 do
        object:getContainerByIndex(i):setExplored(explored[i] ~= false)
    end
end

--- Returns the display height of every object of the square, keyed by object.
local function captureRenderOffsets(square)
    local offsets = {}
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        offsets[object] = object:getRenderYOffset()
    end
    return offsets
end

--- Puts back the recorded display height of the objects still on the square, and sends the heights to the clients by object index and key.
local function restoreRenderOffsets(square, offsets)
    local sent = {}
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local offset = offsets[object]
        if offset then
            object:setRenderYOffset(offset)
            table.insert(sent, { index = i, key = TileDoctor.getObjectKey(object), offset = offset })
        end
    end
    if isServer() then
        sendServerCommand(TileDoctor.COMMAND_MODULE, TileDoctor.COMMAND_RESTORE_OFFSETS,
            { x = square:getX(), y = square:getY(), z = square:getZ(), offsets = sent })
    end
end

--- Applies display heights received by object index to the objects of the square whose key still matches.
function TileDoctor.applyRenderOffsets(square, offsets)
    local objects = square:getObjects()
    for _, entry in ipairs(offsets) do
        local object = findByKey(objects, entry.index, entry.key, TileDoctor.getObjectKey)
        if object then
            object:setRenderYOffset(entry.offset)
        end
    end
end

--- Runs replaceObject, which swaps the object for another, while keeping every object of the square at its display height: the replacement takes the height of the object it replaces.
local function preserveSquareLayout(square, object, replaceObject)
    local offsets = captureRenderOffsets(square)
    local replacement = replaceObject()
    offsets[replacement] = offsets[object]
    restoreRenderOffsets(square, offsets)
end

--- Builds a fresh object of the same class, sprite, overlay and attached sprites, then swaps it for this single object at the same position in the square, leaving the other parts of a multi-square object in place.
local function resetStandardObject(square, object, spriteName, attachedNames)
    local factory = FACTORIES[getClassSimpleName(object)]
    local place = factory.place or addToSquare
    local publish = factory.publish or sendToClients
    local overlay = object:getOverlaySprite()
    local overlayName = overlay and overlay:getName()
    local index = object:getObjectIndex()
    local explored = getContainersExplored(object)
    preserveSquareLayout(square, object, function()
        local replacement = factory.create(getCell(), square, object, spriteName)
        attachSprites(replacement, attachedNames)
        if overlayName then
            replacement:setOverlaySprite(overlayName)
        end
        square:transmitRemoveItemFromSquare(object, false)
        place(square, replacement, index)
        applyContainersExplored(replacement, explored)
        publish(replacement)
        return replacement
    end)
    return true
end

--- Rebuilds the object from its sprite and finishes, discarding any other state it carried.
function TileDoctor.resetObject(square, object)
    if not TileDoctor.canResetObject(object) then
        return false
    end
    local spriteName = TileDoctor.getSpriteName(object)
    local attachedNames = getAttachedSpriteNames(object)
    local done
    if object == square:getFloor() then
        done = placeFloor(square, spriteName, attachedNames)
    else
        done = resetStandardObject(square, object, spriteName, attachedNames)
    end
    refreshSquare(square)
    return done
end
