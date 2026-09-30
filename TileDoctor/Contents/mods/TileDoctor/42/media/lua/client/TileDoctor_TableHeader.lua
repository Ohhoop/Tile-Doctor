require "ISUI/ISPanel"

TileDoctorTableHeader = ISPanel:derive("TileDoctorTableHeader")

local GRIP_WIDTH = 4
local MIN_COLUMN_WIDTH = 40
local TEXT_PADDING = 6
local SORT_ASCENDING_MARK = " ^"
local SORT_DESCENDING_MARK = " v"

--- Recomputes the left position of every column from the widths of the columns before it, and stretches the last column to the right edge of the header.
function TileDoctorTableHeader:layoutColumns()
    local x = 0
    local count = #self.columns
    for i, column in ipairs(self.columns) do
        column.x = x
        if i == count then
            column.width = math.max(column.minWidth, self.width - x)
        end
        x = x + column.width
    end
end

--- Returns the index of the column, other than the last one, whose right border lies under the given position, or nil when none does.
function TileDoctorTableHeader:getBorderAt(x)
    for i = 1, #self.columns - 1 do
        local column = self.columns[i]
        local border = column.x + column.width
        if math.abs(x - border) <= GRIP_WIDTH then
            return i
        end
    end
    return nil
end

--- Returns the index and the column of the columns lying under the given position, or nil when none does.
function TileDoctorTableHeader.findColumnAt(columns, x)
    for i, column in ipairs(columns) do
        if x >= column.x and x < column.x + column.width then
            return i, column
        end
    end
    return nil
end

--- Lays the columns out against the current header width, then draws the header background, every column title with its sort mark, and the column borders.
function TileDoctorTableHeader:render()
    self:layoutColumns()
    self:drawRect(0, 0, self.width, self.height, 0.8, 0.15, 0.15, 0.15)
    self:drawRectBorder(0, 0, self.width, self.height, 1, 0.4, 0.4, 0.4)
    local textY = self.textY
    for i, column in ipairs(self.columns) do
        local title = column.title
        if self.sortColumn == i then
            title = title .. (self.sortAscending and SORT_ASCENDING_MARK or SORT_DESCENDING_MARK)
        end
        if column.centered then
            self:drawTextCentre(title, column.x + column.width / 2, textY, 1, 1, 1, 1, UIFont.Small)
        else
            self:drawText(title, column.x + TEXT_PADDING, textY, 1, 1, 1, 1, UIFont.Small)
        end
        self:drawRect(column.x + column.width - 1, 0, 1, self.height, 1, 0.4, 0.4, 0.4)
    end
end

--- Starts resizing a column when its border is pressed, otherwise sorts by the pressed column.
function TileDoctorTableHeader:onMouseDown(x, y)
    local border = self:getBorderAt(x)
    if border then
        self.resizingColumn = border
        self:setCapture(true)
        return true
    end
    local index = TileDoctorTableHeader.findColumnAt(self.columns, x)
    if index and self.columns[index].field then
        if self.sortColumn == index then
            self.sortAscending = not self.sortAscending
        else
            self.sortColumn = index
            self.sortAscending = true
        end
        self.onSortChanged()
    end
    return true
end

--- Resizes the column being dragged so that its right border follows the mouse, never narrower than the smaller of the minimum width and its starting width.
function TileDoctorTableHeader:resizeToMouse()
    local column = self.columns[self.resizingColumn]
    column.width = math.max(math.min(MIN_COLUMN_WIDTH, column.minWidth), self:getMouseX() - column.x)
    self:layoutColumns()
end

--- Follows the mouse, inside or outside the header, while a column is being resized.
function TileDoctorTableHeader:onMouseMove(dx, dy)
    if self.resizingColumn then
        self:resizeToMouse()
    end
end

TileDoctorTableHeader.onMouseMoveOutside = TileDoctorTableHeader.onMouseMove

--- Stops resizing the column.
function TileDoctorTableHeader:stopResizing()
    if self.resizingColumn then
        self.resizingColumn = nil
        self:setCapture(false)
    end
end

--- Stops resizing when the mouse button is released over the header.
function TileDoctorTableHeader:onMouseUp(x, y)
    self:stopResizing()
    return true
end

--- Stops resizing when the mouse button is released outside the header.
function TileDoctorTableHeader:onMouseUpOutside(x, y)
    self:stopResizing()
end

--- Returns the row field to sort on and the direction of the current sort, or nil when the table is not sorted.
function TileDoctorTableHeader:getSort()
    if not self.sortColumn then
        return nil, true
    end
    local column = self.columns[self.sortColumn]
    return column.sortField or column.field, self.sortAscending
end

--- Creates a header for the given columns; onSortChanged is called whenever the sort column or direction changes.
function TileDoctorTableHeader:new(x, y, width, height, columns, onSortChanged)
    local o = ISPanel.new(self, x, y, width, height)
    o.columns = columns
    o.onSortChanged = onSortChanged
    o.sortColumn = nil
    o.sortAscending = true
    o.textY = (height - getTextManager():getFontHeight(UIFont.Small)) / 2
    o:layoutColumns()
    return o
end
