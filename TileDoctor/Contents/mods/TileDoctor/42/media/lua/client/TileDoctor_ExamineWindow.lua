require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISModalDialog"
require "TileDoctor_Commands"
require "TileDoctor_ClientActions"
require "TileDoctor_TileOutline"
require "TileDoctor_TableHeader"

local PADDING = 8
local CELL_PADDING = 6
local ICON_GAP = 6
local REFRESH_INTERVAL_MS = 500
local TILE_CHANGE_MARGIN = 0.2
local CONFIRM_WIDTH = 380
local CONFIRM_HEIGHT = 140
local WINDOW_HEIGHT = 360
local SCROLLBAR_ALLOWANCE = 20
local ELLIPSIS = "..."
local UNKNOWN_COLOR = { r = 1.0, g = 0.45, b = 0.45, a = 1.0 }
local DELETE_TEXTURE = "media/ui/TileDoctor/Delete.png"
local RESET_TEXTURE = "media/ui/TileDoctor/Reset.png"
local ALERT_TEXTURE = "media/ui/TileDoctor/Alert.png"

local ALERT_MARK = "!"

local COLUMN_DEFINITIONS = {
    { kind = "alert", field = "alert", label = ALERT_MARK, width = 26, centered = true },
    { kind = "text", field = "square", sortField = "squareSortKey", titleKey = "UI_TileDoctor_ColSquare", width = 90 },
    { kind = "text", field = "className", titleKey = "UI_TileDoctor_ColClass", width = 170 },
    { kind = "text", field = "name", titleKey = "UI_TileDoctor_ColName", width = 200 },
    { kind = "text", field = "source", titleKey = "UI_TileDoctor_ColSource", width = 240 },
    { kind = "text", field = "flags", titleKey = "UI_TileDoctor_ColFlags", width = 240 },
    { kind = "actions", field = nil, titleKey = "UI_TileDoctor_ColActions", width = 70 },
}

local REPORTED_FLAGS = {
    "solid", "solidtrans", "WallN", "WallW", "WallNW", "WallSE",
    "collideN", "collideW", "doorN", "doorW", "windowN", "windowW",
    "WindowN", "WindowW", "cutN", "cutW",
}

--- Returns a fresh copy of the column definitions for one window, with translated titles or their fixed label.
local function createColumns()
    local columns = {}
    for _, definition in ipairs(COLUMN_DEFINITIONS) do
        local title = definition.titleKey and getText(definition.titleKey) or definition.label
        table.insert(columns, {
            kind = definition.kind,
            field = definition.field,
            sortField = definition.sortField,
            title = title,
            width = definition.width,
            minWidth = definition.width,
            centered = definition.centered,
            x = 0,
        })
    end
    return columns
end

--- Returns the total width of the column definitions.
local function getTableWidth()
    local width = 0
    for _, definition in ipairs(COLUMN_DEFINITIONS) do
        width = width + definition.width
    end
    return width
end

TileDoctorObjectList = ISScrollingListBox:derive("TileDoctorObjectList")

--- Shows or hides the native outline of the object for the player.
local function setObjectOutline(object, playerNum, isOutlined)
    if isOutlined then
        local color = TileDoctor.OUTLINE_COLOR
        object:setOutlineHighlightCol(playerNum, color.r, color.g, color.b, color.a)
    end
    object:setOutlineHighlight(playerNum, isOutlined)
    object:setOutlineHlAttached(playerNum, isOutlined)
end

--- Returns the text shortened with an ellipsis so that it fits in the given width.
local function fitText(font, text, width)
    local manager = getTextManager()
    if manager:MeasureStringX(font, text) <= width then
        return text
    end
    local low, high = 0, #text
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if manager:MeasureStringX(font, string.sub(text, 1, middle) .. ELLIPSIS) <= width then
            low = middle
        else
            high = middle - 1
        end
    end
    return string.sub(text, 1, low) .. ELLIPSIS
end

--- Returns the text of the field of the row fitted to the width, computing it again only when the width changed.
function TileDoctorObjectList:getFittedText(entry, field, width)
    local cached = entry.fitted[field]
    if not cached or cached.width ~= width then
        cached = { width = width, text = fitText(self.font, entry[field], width) }
        entry.fitted[field] = cached
    end
    return cached.text
end

--- Returns the size of the row icons.
function TileDoctorObjectList:getIconSize()
    return self.itemheight - 4
end

--- Returns the left position of the reset icon and of the delete icon inside the given actions column.
function TileDoctorObjectList:getActionIconsX(column)
    local resetX = column.x + CELL_PADDING
    local deleteX = resetX + self:getIconSize() + ICON_GAP
    return resetX, deleteX
end

--- Draws the text of the column field in the cell, in red when the cell carries a warning.
local function drawTextCell(list, entry, column, y, height)
    local color = entry.warnings[column.field] and UNKNOWN_COLOR or list.textColor
    local text = list:getFittedText(entry, column.field, column.width - CELL_PADDING * 2)
    list:drawText(text, column.x + CELL_PADDING, y + (height - list.fontHgt) / 2, color.r, color.g, color.b, color.a, list.font)
end

--- Draws the alert icon centered in the cell when the row is flagged.
local function drawAlertCell(list, entry, column, y, height)
    if entry.alert == "" then
        return
    end
    local size = list:getIconSize()
    list:drawTextureScaled(list.alertTexture, column.x + (column.width - size) / 2, y + (height - size) / 2, size, size, 1, 1, 1, 1)
end

--- Draws the reset icon when the row can be rebuilt and the delete icon when it can be removed.
local function drawActionsCell(list, entry, column, y, height)
    local size = list:getIconSize()
    local iconY = y + (height - size) / 2
    local resetX, deleteX = list:getActionIconsX(column)
    if entry.resetCommand then
        list:drawTextureScaled(list.resetTexture, resetX, iconY, size, size, 1, 1, 1, 1)
    end
    if entry.removeCommand then
        list:drawTextureScaled(list.deleteTexture, deleteX, iconY, size, size, 1, 1, 1, 1)
    end
end

--- Returns the alert explanation of the row, or nil when it is not flagged.
local function alertTooltip(entry)
    return entry.alertTooltip
end

--- Asks for confirmation of the action whose icon lies under the mouse; returns true when an icon was clicked.
local function clickActionsCell(list, entry, column, mouseX)
    local size = list:getIconSize()
    local resetX, deleteX = list:getActionIconsX(column)
    if entry.removeCommand and mouseX >= deleteX and mouseX < deleteX + size then
        list:confirmAction("UI_TileDoctor_ConfirmRemove", entry, entry.removeCommand)
        return true
    end
    if entry.resetCommand and mouseX >= resetX and mouseX < resetX + size then
        list:confirmAction("UI_TileDoctor_ConfirmReset", entry, entry.resetCommand)
        return true
    end
    return false
end

local COLUMN_KINDS = {
    text = { draw = drawTextCell },
    alert = { draw = drawAlertCell, tooltip = alertTooltip },
    actions = { draw = drawActionsCell, click = clickActionsCell },
}

--- Draws one table row: its background, then every cell with the renderer of its column kind and the column borders.
function TileDoctorObjectList:doDrawItem(y, item, alt)
    local scrollY = self:getYScroll()
    if (y + scrollY + item.height < 0) or (y + scrollY >= self.height) then
        return y + item.height
    end
    local width = self:getWidth()
    if self.selected == item.index then
        self:drawSelection(0, y, width, item.height - 1)
    elseif self.mouseoverselected == item.index and self:isMouseOver() and not self:isMouseOverScrollBar() then
        self:drawMouseOverHighlight(0, y, width, item.height - 1)
    end
    self:drawRectBorder(0, y, width, item.height, 0.5, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    for _, column in ipairs(self.tableColumns) do
        COLUMN_KINDS[column.kind].draw(self, item.item, column, y, item.height)
        self:drawRect(column.x + column.width - 1, y, 1, item.height, 0.3, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    end
    return y + item.height
end

--- Returns a short description of the row for confirmation messages: its class followed by its name, or by its tile when it has no name.
local function describeEntryForConfirmation(entry)
    local label = entry.name ~= "-" and entry.name or entry.source
    return string.format("%s (%s)", entry.className, label)
end

--- Requests the confirmed command with the arguments of the row and asks the window to check for changes.
local function onConfirmAction(list, button, command, args)
    if button.internal ~= "YES" then
        return
    end
    TileDoctorClientActions.request(list.playerObj, command, args)
    list.parent:scheduleRefresh()
end

--- Asks the player to confirm the command on the row with the translated message describing it, warning that its contents will be lost when it holds items.
function TileDoctorObjectList:confirmAction(messageKey, entry, command)
    local text = getText(messageKey, describeEntryForConfirmation(entry))
    if entry.holdsItems then
        text = text .. "\n" .. getText("UI_TileDoctor_ConfirmHoldsItems")
    end
    local dialog = ISModalDialog:new(0, 0, CONFIRM_WIDTH, CONFIRM_HEIGHT, text, true, self, onConfirmAction, self.playerNum, command, entry.args)
    dialog:initialise()
    dialog:centerOnScreen(self.playerNum)
    dialog:addToUIManager()
end

--- Lets the column under the mouse handle the click, otherwise selects the row.
function TileDoctorObjectList:onMouseDown(x, y)
    local item = self.items[self:rowAt(x, y)]
    local _, column = TileDoctorTableHeader.findColumnAt(self.tableColumns, x)
    local click = column and COLUMN_KINDS[column.kind].click
    if item and click and click(self, item.item, column, x) then
        return
    end
    ISScrollingListBox.onMouseDown(self, x, y)
end

--- Outlines the object under the mouse and removes the outline from the previously hovered one.
function TileDoctorObjectList:prerender()
    ISScrollingListBox.prerender(self)
    local hovered = nil
    if self:isMouseOver() and not self:isMouseOverScrollBar() then
        local row = self.items[self.mouseoverselected]
        hovered = row and row.item.object
    end
    if hovered ~= self.outlinedObject then
        self:clearOutline()
        if hovered then
            setObjectOutline(hovered, self.playerNum, true)
            self.outlinedObject = hovered
        end
    end
end

--- Shows as a tooltip the text that the column under the mouse gives for the hovered row, when its kind provides one.
function TileDoctorObjectList:updateTooltip()
    if self.tooltipItem then
        self.tooltipItem.tooltip = nil
        self.tooltipItem = nil
    end
    local mouseX = self:getMouseX()
    local _, column = TileDoctorTableHeader.findColumnAt(self.tableColumns, mouseX)
    local tooltipOf = column and COLUMN_KINDS[column.kind].tooltip
    local item = tooltipOf and self.items[self:rowAt(mouseX, self:getMouseY())]
    if item then
        item.tooltip = tooltipOf(item.item)
        self.tooltipItem = item
    end
    ISScrollingListBox.updateTooltip(self)
end

--- Removes the outline from the currently outlined object.
function TileDoctorObjectList:clearOutline()
    if self.outlinedObject then
        setObjectOutline(self.outlinedObject, self.playerNum, false)
        self.outlinedObject = nil
    end
end

--- Creates the object table for the player, laid out along the given columns.
function TileDoctorObjectList:new(x, y, width, height, playerObj, columns)
    local o = ISScrollingListBox.new(self, x, y, width, height)
    o.playerObj = playerObj
    o.tableColumns = columns
    o.playerNum = playerObj:getPlayerNum()
    o.drawBorder = true
    o.deleteTexture = getTexture(DELETE_TEXTURE)
    o.resetTexture = getTexture(RESET_TEXTURE)
    o.alertTexture = getTexture(ALERT_TEXTURE)
    return o
end

TileDoctorExamineWindow = ISCollapsableWindow:derive("TileDoctorExamineWindow")

--- Returns the collision and structure flags carried by the sprite, followed by a marker when the sprite has no texture.
local function describeFlags(sprite)
    local flags = {}
    local props = sprite:getProperties()
    for _, flagName in ipairs(REPORTED_FLAGS) do
        if props and props:has(IsoFlagType[flagName]) then
            table.insert(flags, flagName)
        end
    end
    if sprite:hasNoTextures() then
        table.insert(flags, "noTexture")
    end
    return table.concat(flags, " ")
end

--- Fills the table row of a dropped item with its display name and its full item type.
local function describeWorldItem(entry, item)
    entry.name = item:getDisplayName() or "-"
    entry.source = item:getFullType() or "?"
end

--- Marks the given cell of the row as a warning and records the translation key explaining why.
local function addWarning(entry, field, reasonKey)
    entry.warnings[field] = true
    table.insert(entry.alertReasons, reasonKey)
end

--- Fills the table row of a map or built object with its name, its sprite name and its flags, marking missing or unknown sprites as warnings.
local function describeTileObject(entry, object)
    local sprite = object:getSprite()
    entry.name = object:getObjectName() or "-"
    if not sprite then
        entry.source = "?"
        entry.flags = "noSprite"
        addWarning(entry, "flags", "UI_TileDoctor_AlertNoSprite")
        return
    end
    local spriteName = sprite:getName() or ""
    entry.flags = describeFlags(sprite)
    if spriteName == "" then
        entry.source = "?"
        addWarning(entry, "source", "UI_TileDoctor_AlertNoSpriteName")
    elseif not getSprite(spriteName) then
        entry.source = spriteName .. " (unknown)"
        addWarning(entry, "source", "UI_TileDoctor_AlertUnknownSprite")
    else
        entry.source = spriteName
    end
    if sprite:hasNoTextures() then
        addWarning(entry, "flags", "UI_TileDoctor_AlertNoTexture")
    end
end

--- Returns a table row for the element standing on the square, with its position and class, no action and no warning.
local function newEntry(square, element)
    return {
        object = element,
        square = string.format("%d, %d", square:getX(), square:getY()),
        squareSortKey = string.format("%09d %09d", square:getX(), square:getY()),
        className = element and getClassSimpleName(element) or "-",
        name = "-",
        source = "-",
        flags = "",
        alert = "",
        alertReasons = {},
        warnings = {},
        fitted = {},
    }
end

--- Returns the command arguments locating an element of the square by its index and key.
local function keyedArgs(square, index, key)
    return { x = square:getX(), y = square:getY(), z = square:getZ(), index = index, key = key }
end

--- Marks the row with a red alert when it has warnings, and builds the tooltip listing their explanations one per line.
local function applyAlert(entry)
    if #entry.alertReasons == 0 then
        return
    end
    entry.alert = ALERT_MARK
    local lines = {}
    for _, reasonKey in ipairs(entry.alertReasons) do
        table.insert(lines, getText(reasonKey))
    end
    entry.alertTooltip = table.concat(lines, " <LINE> ")
end

--- Returns true when the container exists and holds at least one item.
local function containerHoldsItems(container)
    return container ~= nil and not container:isEmpty()
end

--- Returns true when one of the containers of the object holds at least one item.
local function objectHoldsItems(object)
    for i = 0, object:getContainerCount() - 1 do
        if containerHoldsItems(object:getContainerByIndex(i)) then
            return true
        end
    end
    return false
end

--- Returns true when one of the vehicle parts, such as its trunk or glove box, holds at least one item.
local function vehicleHoldsItems(vehicle)
    for i = 0, vehicle:getPartCount() - 1 do
        if containerHoldsItems(vehicle:getPartByIndex(i):getItemContainer()) then
            return true
        end
    end
    return false
end

--- Builds the table row for the object found at the given index of the square, with its remove command and, when it can be rebuilt, its reset command.
local function buildObjectEntry(square, object, index)
    local entry = newEntry(square, object)
    entry.args = keyedArgs(square, index, TileDoctor.getObjectKey(object))
    entry.removeCommand = TileDoctor.COMMAND_REMOVE_OBJECT
    if TileDoctor.canResetObject(object) then
        entry.resetCommand = TileDoctor.COMMAND_RESET_OBJECT
    end
    local item = TileDoctor.getWorldItem(object)
    if item then
        describeWorldItem(entry, item)
        entry.holdsItems = instanceof(item, "InventoryContainer") and containerHoldsItems(item:getInventory())
    else
        describeTileObject(entry, object)
        entry.holdsItems = objectHoldsItems(object)
    end
    applyAlert(entry)
    return entry
end

--- Returns the first and last name of the corpse, or nil when it has none.
local function getCorpseName(body)
    local descriptor = body:getDescriptor()
    if not descriptor then
        return nil
    end
    local name = string.format("%s %s", descriptor:getForename() or "", descriptor:getSurname() or "")
    if name == " " then
        return nil
    end
    return name
end

--- Builds the table row for the corpse found at the given index of the square's corpses, with its remove command.
local function buildCorpseEntry(square, body, index)
    local entry = newEntry(square, body)
    entry.args = keyedArgs(square, index, TileDoctor.getCorpseKey(body))
    entry.removeCommand = TileDoctor.COMMAND_REMOVE_CORPSE
    entry.name = getCorpseName(body) or "-"
    entry.source = body:getOutfitName() or "-"
    local flags = {}
    if body:isZombie() then table.insert(flags, "zombie") end
    if body:isAnimal() then table.insert(flags, "animal") end
    if body:isSkeleton() then table.insert(flags, "skeleton") end
    entry.flags = table.concat(flags, " ")
    entry.holdsItems = containerHoldsItems(body:getContainer())
    return entry
end

--- Builds the table row for the vehicle covering the square, with its remove command.
local function buildVehicleEntry(square, vehicle)
    local entry = newEntry(square, vehicle)
    local id = vehicle:getId()
    entry.args = { x = square:getX(), y = square:getY(), z = square:getZ(), id = id }
    entry.removeCommand = TileDoctor.COMMAND_REMOVE_VEHICLE
    entry.name = vehicle:getScriptName() or "-"
    entry.source = "id " .. tostring(id)
    entry.holdsItems = vehicleHoldsItems(vehicle)
    return entry
end

--- Builds a fake flagged row on the square, carrying every alert, with no object and no action.
local function buildTestEntry(square)
    local entry = newEntry(square, nil)
    entry.className = "TileDoctorTest"
    entry.name = "Tile Doctor test"
    entry.source = "tiledoctor_test_01_0 (unknown)"
    entry.flags = "solid noTexture"
    addWarning(entry, "flags", "UI_TileDoctor_AlertNoSprite")
    addWarning(entry, "source", "UI_TileDoctor_AlertNoSpriteName")
    addWarning(entry, "source", "UI_TileDoctor_AlertUnknownSprite")
    addWarning(entry, "flags", "UI_TileDoctor_AlertNoTexture")
    applyAlert(entry)
    return entry
end

--- Calls visit for every object, corpse and vehicle found on the squares, each vehicle once, with the builder of its row, the square, the element and its index.
local function forEachListedElement(squares, visit)
    local seenVehicles = {}
    for _, square in ipairs(squares) do
        local objects = square:getObjects()
        for i = 0, objects:size() - 1 do
            visit(buildObjectEntry, square, objects:get(i), i)
        end
        local bodies = square:getDeadBodys()
        for i = 0, bodies:size() - 1 do
            visit(buildCorpseEntry, square, bodies:get(i), i)
        end
        local vehicle = square:getVehicleContainer()
        if vehicle and not seenVehicles[vehicle:getId()] then
            seenVehicles[vehicle:getId()] = true
            visit(buildVehicleEntry, square, vehicle, nil)
        end
    end
end

--- Returns the table rows for every object, corpse and vehicle found on the squares.
local function collectEntries(squares)
    local entries = {}
    forEachListedElement(squares, function(build, square, element, index)
        table.insert(entries, build(square, element, index))
    end)
    return entries
end

--- Returns the objects, corpses and vehicles found on the squares, in scan order.
local function snapshotElements(squares)
    local elements = {}
    forEachListedElement(squares, function(_build, _square, element)
        table.insert(elements, element)
    end)
    return elements
end

--- Returns the elements of the rows, in the order of the rows.
local function elementsOf(entries)
    local elements = {}
    for _, entry in ipairs(entries) do
        table.insert(elements, entry.object)
    end
    return elements
end

--- Returns true when both lists hold the same elements in the same order.
local function sameElements(left, right)
    if #left ~= #right then
        return false
    end
    for i = 1, #left do
        if left[i] ~= right[i] then
            return false
        end
    end
    return true
end

--- Sorts the rows by the text of the given field, in the given direction, keeping the scan order between equal rows.
local function sortEntries(entries, field, ascending)
    if not field then
        return
    end
    for i, entry in ipairs(entries) do
        entry.order = i
        entry.sortKey = string.lower(tostring(entry[field]))
    end
    table.sort(entries, function(a, b)
        if a.sortKey == b.sortKey then
            return a.order < b.order
        end
        if ascending then
            return a.sortKey < b.sortKey
        end
        return a.sortKey > b.sortKey
    end)
end

--- Returns true when the position has left the tile starting at the given coordinate by more than the change margin.
local function hasLeftTile(position, tileStart)
    return position < tileStart - TILE_CHANGE_MARGIN or position >= tileStart + 1 + TILE_CHANGE_MARGIN
end

--- Returns the loaded squares examined around the player: the player's square and its 8 neighbours on the player's level.
function TileDoctorExamineWindow:getExaminedSquares()
    local cell = getCell()
    local squares = {}
    for dy = -1, 1 do
        for dx = -1, 1 do
            local square = cell:getGridSquare(self.centerX + dx, self.centerY + dy, self.centerZ)
            if square then
                table.insert(squares, square)
            end
        end
    end
    return squares
end

--- Returns true when the player has clearly moved onto another square since the table was built, ignoring small moves around a square border.
function TileDoctorExamineWindow:hasPlayerChangedTile()
    local player = self.playerObj
    if math.floor(player:getZ()) ~= self.centerZ then
        return true
    end
    return hasLeftTile(player:getX(), self.centerX) or hasLeftTile(player:getY(), self.centerY)
end

--- Centers the scanned area on the square the player stands on and moves the area outline onto it, creating the outline the first time.
function TileDoctorExamineWindow:centerOnPlayer()
    local player = self.playerObj
    self.centerX, self.centerY, self.centerZ = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local x, y = self.centerX - 1, self.centerY - 1
    if self.zoneOutline then
        self.zoneOutline:setArea(x, y, self.centerZ, 3, 3)
    else
        self.zoneOutline = TileDoctorTileOutline.create(player:getPlayerNum(), x, y, self.centerZ, 3, 3)
    end
end

--- Rebuilds the rows from the current objects, corpses and vehicles of the scanned area and shows them.
function TileDoctorExamineWindow:refresh()
    self.entries = collectEntries(self:getExaminedSquares())
    self.elements = elementsOf(self.entries)
    self:showEntries()
end

--- Shows the rows sorted as the header asks, with the test row first in the development build.
function TileDoctorExamineWindow:showEntries()
    self.list:clearOutline()
    self.list:clear()
    local entries = {}
    for i, entry in ipairs(self.entries) do
        entries[i] = entry
    end
    local field, ascending = self.header:getSort()
    sortEntries(entries, field, ascending)
    local centerSquare = getCell():getGridSquare(self.centerX, self.centerY, self.centerZ)
    if TileDoctor.isDevBuild() and centerSquare then
        table.insert(entries, 1, buildTestEntry(centerSquare))
    end
    for _, entry in ipairs(entries) do
        self.list:addItem("", entry)
    end
end

--- Asks for the table to be checked for changes on the next frame.
function TileDoctorExamineWindow:scheduleRefresh()
    self.nextCheckMs = 0
end

--- Rebuilds the table as soon as the player moves onto another square, or when the objects around the player have changed since the last check.
function TileDoctorExamineWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self:hasPlayerChangedTile() then
        self:centerOnPlayer()
        self:refresh()
        return
    end
    local now = getTimestampMs()
    if now < self.nextCheckMs then
        return
    end
    self.nextCheckMs = now + REFRESH_INTERVAL_MS
    if not sameElements(snapshotElements(self:getExaminedSquares()), self.elements) then
        self:refresh()
    end
end

--- Keeps the window permanently expanded without collapse or pin buttons, then creates the sortable and resizable table header, the object table and the scanned area outline, and fills the table with the objects around the player.
function TileDoctorExamineWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.pin = true
    self.collapseButton:setVisible(false)
    self.pinButton:setVisible(false)
    local columns = createColumns()
    local headerHeight = getTextManager():getFontHeight(UIFont.Small) + 6
    local headerTop = self:titleBarHeight() + PADDING
    self.header = TileDoctorTableHeader:new(PADDING, headerTop, self.width - PADDING * 2, headerHeight, columns, function()
        self:showEntries()
    end)
    self.header:initialise()
    self.header:setAnchorRight(true)
    self:addChild(self.header)
    local top = headerTop + headerHeight
    self.list = TileDoctorObjectList:new(PADDING, top, self.width - PADDING * 2, self.height - top - PADDING, self.playerObj, columns)
    self.list:initialise()
    self.list:instantiate()
    self.list:setFont(UIFont.Small, 2)
    self.list:setAnchorRight(true)
    self.list:setAnchorBottom(true)
    self:addChild(self.list)
    self:centerOnPlayer()
    self:refresh()
end

--- Removes the object and scanned area outlines and any open tooltip, then closes the window.
function TileDoctorExamineWindow:close()
    self.list:clearOutline()
    if self.list.tooltipUI then
        self.list.tooltipUI:removeFromUIManager()
    end
    self.zoneOutline:remove()
    self:setVisible(false)
    self:removeFromUIManager()
end

--- Creates the examine window following the player.
function TileDoctorExamineWindow:new(playerObj)
    local o = ISCollapsableWindow.new(self, 0, 0, getTableWidth() + PADDING * 2 + SCROLLBAR_ALLOWANCE, WINDOW_HEIGHT)
    o.playerObj = playerObj
    o.elements = {}
    o.entries = {}
    o.nextCheckMs = 0
    o:setTitle("Tile Doctor")
    o:setResizable(true)
    return o
end

--- Opens the examine window following the player, centered on the player's screen.
function TileDoctorExamineWindow.open(playerObj)
    local window = TileDoctorExamineWindow:new(playerObj)
    window:initialise()
    window:centerOnScreen(playerObj:getPlayerNum())
    window:addToUIManager()
end
