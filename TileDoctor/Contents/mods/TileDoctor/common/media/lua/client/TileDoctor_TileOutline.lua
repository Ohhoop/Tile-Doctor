require "TileDoctor_Core"

TileDoctorTileOutline = {}
TileDoctorTileOutline.__index = TileDoctorTileOutline

local THICKNESS_PIXELS = 2
local LAYER_STEP_PIXELS = 0.5
local SCREEN_PIXELS_PER_TILE_SCALE = 64 / math.sqrt(5)

local activeOutlines = {}
local activeCount = 0

--- Draws a one pixel diamond along the edges of the rectangle of squares from (x1, y1) to (x2, y2).
local function drawDiamond(x1, y1, x2, y2, z)
    local c = TileDoctor.OUTLINE_COLOR
    renderIsoLine(x1, y1, z, x2, y1, z, 1, c.r, c.g, c.b, c.a)
    renderIsoLine(x2, y1, z, x2, y2, z, 1, c.r, c.g, c.b, c.a)
    renderIsoLine(x2, y2, z, x1, y2, z, 1, c.r, c.g, c.b, c.a)
    renderIsoLine(x1, y2, z, x1, y1, z, 1, c.r, c.g, c.b, c.a)
end

--- Draws a solid band along the inside edges of the outlined area as thin diamonds stacked a fraction of a pixel apart.
function TileDoctorTileOutline:draw(squaresPerPixel)
    local x1, y1 = self.areaX, self.areaY
    local x2, y2 = x1 + self.areaWidth, y1 + self.areaHeight
    local inset = 0
    while inset <= THICKNESS_PIXELS - 1 do
        local offset = inset * squaresPerPixel
        drawDiamond(x1 + offset, y1 + offset, x2 - offset, y2 - offset, self.areaZ)
        inset = inset + LAYER_STEP_PIXELS
    end
end

--- Moves the outline to the area starting at the given square and spanning the given number of squares.
function TileDoctorTileOutline:setArea(x, y, z, width, height)
    self.areaX = x
    self.areaY = y
    self.areaZ = z
    self.areaWidth = width
    self.areaHeight = height
end

--- Stops drawing the outline.
function TileDoctorTileOutline:remove()
    if activeOutlines[self] then
        activeOutlines[self] = nil
        activeCount = activeCount - 1
    end
end

--- Creates an outline of an area of squares, drawn with the world for the given player until it is removed.
function TileDoctorTileOutline.create(playerNum, x, y, z, width, height)
    local outline = setmetatable({ playerNum = playerNum }, TileDoctorTileOutline)
    outline:setArea(x, y, z, width, height)
    activeOutlines[outline] = true
    activeCount = activeCount + 1
    return outline
end

--- Draws, right after the world of the player being rendered, every outline belonging to that player; does nothing while no outline exists.
local function onPostRender()
    if activeCount == 0 then
        return
    end
    local player = IsoPlayer.getInstance()
    if not player then
        return
    end
    local playerNum = player:getPlayerNum()
    local squaresPerPixel = 1 / (SCREEN_PIXELS_PER_TILE_SCALE * Core.getTileScale())
    for outline in pairs(activeOutlines) do
        if outline.playerNum == playerNum then
            outline:draw(squaresPerPixel)
        end
    end
end

Events.OnPostRender.Add(onPostRender)
