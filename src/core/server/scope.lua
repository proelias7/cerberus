local GRID_SIZE = 100.0
local UPDATE_INTERVAL = 5000
local MAX_RADIUS = 200.0
local DEFAULT_RADIUS = 50.0

local grid = {}
local playerGrid = {}

local function getGridKey(x, y)
    local gx = math.floor(x / GRID_SIZE)
    local gy = math.floor(y / GRID_SIZE)
    return gx .. ":" .. gy, gx, gy
end

local function getCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    if c.x == 0.0 and c.y == 0.0 and c.z == 0.0 then return nil end
    return c
end

local function removeFromGrid(src)
    local key = playerGrid[src]
    if not key then return end
    local cell = grid[key]
    if cell then
        cell[src] = nil
        if not next(cell) then grid[key] = nil end
    end
    playerGrid[src] = nil
end

CreateThread(function()
    while true do
        for _, raw in ipairs(GetPlayers()) do
            local src = tonumber(raw)
            local coords = getCoords(src)

            if coords then
                local newKey = getGridKey(coords.x, coords.y)

                if playerGrid[src] ~= newKey then
                    removeFromGrid(src)
                    if not grid[newKey] then grid[newKey] = {} end
                    grid[newKey][src] = coords
                    playerGrid[src] = newKey
                else
                    -- atualiza coords dentro da mesma célula
                    if grid[newKey] then
                        grid[newKey][src] = coords
                    end
                end
            end
        end

        Wait(UPDATE_INTERVAL)
    end
end)

AddEventHandler("playerDropped", function()
    removeFromGrid(tonumber(source))
end)

---@param source number
---@param radius number
---@return number[]
function PlayersScope(source, radius)
    local r = math.min(radius or DEFAULT_RADIUS, MAX_RADIUS)
    local r2 = r * r
    local origin = getCoords(source)

    if not origin then return {} end

    local nearby = {}
    local _, gx, gy = getGridKey(origin.x, origin.y)
    local range = math.ceil(r / GRID_SIZE)

    for ix = -range, range do
        for iy = -range, range do
            local cell = grid[(gx + ix) .. ":" .. (gy + iy)]
            if cell then
                for src, pos in pairs(cell) do
                    if src ~= source then
                        local dx = origin.x - pos.x
                        local dy = origin.y - pos.y
                        local dz = origin.z - pos.z
                        if (dx*dx + dy*dy + dz*dz) <= r2 then
                            nearby[#nearby + 1] = src
                        end
                    end
                end
            end
        end
    end

    return nearby
end

---@param coords vector3
---@param radius number
---@param maxRadius? number
---@return table, table
local function ScopeAll(coords, radius, maxRadius)
    if not coords or not coords.x then return {}, {} end

    local r = math.min(radius or DEFAULT_RADIUS, MAX_RADIUS)
    local r2 = r * r
    local nearby = {}
    local distant = {}

    if maxRadius then
        local mr = math.min(maxRadius, MAX_RADIUS)
        if mr < r then mr = r end
        local mr2 = mr * mr
        local _, gx, gy = getGridKey(coords.x, coords.y)
        local cellRange = math.ceil(mr / GRID_SIZE)

        for ix = -cellRange, cellRange do
            for iy = -cellRange, cellRange do
                local cell = grid[(gx + ix) .. ":" .. (gy + iy)]
                if cell then
                    for src, pos in pairs(cell) do
                        local dx = coords.x - pos.x
                        local dy = coords.y - pos.y
                        local dz = coords.z - pos.z
                        local d2 = dx*dx + dy*dy + dz*dz
                        if d2 <= r2 then
                            nearby[#nearby + 1] = src
                        elseif d2 <= mr2 then
                            distant[#distant + 1] = src
                        end
                    end
                end
            end
        end
    else
        local allInGrid = {}
        for _, cell in pairs(grid) do
            for src in pairs(cell) do
                allInGrid[src] = true
            end
        end

        local _, gx, gy = getGridKey(coords.x, coords.y)
        local cellRange = math.ceil(r / GRID_SIZE)

        local nearbySet = {}
        for ix = -cellRange, cellRange do
            for iy = -cellRange, cellRange do
                local cell = grid[(gx + ix) .. ":" .. (gy + iy)]
                if cell then
                    for src, pos in pairs(cell) do
                        local dx = coords.x - pos.x
                        local dy = coords.y - pos.y
                        local dz = coords.z - pos.z
                        if (dx*dx + dy*dy + dz*dz) <= r2 then
                            nearbySet[src] = true
                            nearby[#nearby + 1] = src
                        end
                    end
                end
            end
        end

        for src in pairs(allInGrid) do
            if not nearbySet[src] then
                distant[#distant + 1] = src
            end
        end
    end

    return nearby, distant
end

---@param coords vector3
---@param radius number
---@param includeSelf? boolean
---@param maxRadius? number
---@return table, table?
function PlayersScopeCoords(coords, radius, includeSelf, maxRadius)
    if includeSelf then
        return ScopeAll(coords, radius, maxRadius)
    end
    if not coords or not coords.x then return {} end

    local r = math.min(radius or DEFAULT_RADIUS, MAX_RADIUS)
    local r2 = r * r
    local nearby = {}

    local _, gx, gy = getGridKey(coords.x, coords.y)
    local range = math.ceil(r / GRID_SIZE)

    for ix = -range, range do
        for iy = -range, range do
            local cell = grid[(gx + ix) .. ":" .. (gy + iy)]
            if cell then
                for src, pos in pairs(cell) do
                    local dx = coords.x - pos.x
                    local dy = coords.y - pos.y
                    local dz = coords.z - pos.z
                    if (dx*dx + dy*dy + dz*dz) <= r2 then
                        nearby[#nearby + 1] = src
                    end
                end
            end
        end
    end

    return nearby
end

exports("PlayersScope", PlayersScope)
exports("PlayersScopeCoords", PlayersScopeCoords)

-- local perto, longe = exports["cerberus"]:PlayersScopeCoords(GetEntityCoords(PlayerPedId()), 50.0, true)

RegisterCommand("scopedebug", function(src)
    if src == 0 then
        local cells, total = 0, 0
        for _, cell in pairs(grid) do
            cells = cells + 1
            for _ in pairs(cell) do total = total + 1 end
        end
        print(("[SCOPE] Células ativas: %d | Players no grid: %d"):format(cells, total))
    end
end, true)