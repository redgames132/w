-- ==========================================================
-- GUIAGEM DE MÍSSIL POR RADAR (create_radar:radar_bearing_0)
-- Escala analógica real: 0 = desligado | 1 = fraco | 15 = máximo
-- Baixo (bottom): ir reto (2x concretos vermelhos)
-- Trás (back): Norte (-Z) | Frente (front): Sul (+Z)
-- Direita (right): Leste (+X) | Esquerda (left): Oeste (-X)
-- ==========================================================

local LAUNCH_POS = { x = 47,  y = -61, z = -18 }
local TARGET     = { x = 179, y = -59, z = -160 }

local START_TIME     = 2.0  -- 2 segundos iniciais
local START_STRAIGHT = 3    -- Nível baixo (1..15) nos 2s iniciais
local MAX_STRAIGHT   = 12   -- Teto em 'bottom' durante o voo

local LOOP_DT        = 0.05
local ARRIVAL_RADIUS = 5.0

-- Ganhos proporcionais para saída de 0 a 15
local KP_HORIZ       = 0.06
local KD_HORIZ       = 0.025

local SIDES = {
    north = "back",   -- Norte (-Z): concreto marrom
    south = "front",  -- Sul (+Z): 2 concretos brancos
    east  = "right",  -- Leste (+X): concreto preto
    west  = "left",   -- Oeste (-X): concreto lima
    power = "bottom", -- Baixo: 2 concretos vermelhos (ir reto)
}

local RADAR_NAME = "create_radar:radar_bearing_0"

local function setAnalog(side, val)
    local v = math.max(0, math.min(15, math.floor(val + 0.5)))
    redstone.setAnalogOutput(side, v)
end

local function shutdownAll()
    setAnalog(SIDES.north, 0)
    setAnalog(SIDES.south, 0)
    setAnalog(SIDES.east,  0)
    setAnalog(SIDES.west,  0)
    setAnalog(SIDES.power, 0)
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local radar = peripheral.wrap(RADAR_NAME)
if not radar then
    error("Não foi possível ligar ao periférico: " .. RADAR_NAME)
end

local trackedId = nil
local lastKnownPos = { x = LAUNCH_POS.x, y = LAUNCH_POS.y, z = LAUNCH_POS.z }

local function isMissileTrack(t)
    if type(t) ~= "table" then return false end
    return t.category == "SABLE" or t.entityType == "Sable:ship"
end

local function extractXYZ(t)
    if type(t) ~= "table" then return nil end

    if t.position and type(t.position) == "table" and t.position.x and t.position.y and t.position.z then
        return tonumber(t.position.x), tonumber(t.position.y), tonumber(t.position.z)
    end
    if t.pos and type(t.pos) == "table" and t.pos.x and t.pos.y and t.pos.z then
        return tonumber(t.pos.x), tonumber(t.pos.y), tonumber(t.pos.z)
    end
    if t.x and t.y and t.z then
        return tonumber(t.x), tonumber(t.y), tonumber(t.z)
    end
    return nil
end

local function findMissilePosition()
    local tracks = radar.getTracks()
    if type(tracks) ~= "table" or #tracks == 0 then
        return nil
    end

    local bestTrack = nil
    local bestDist = math.huge

    for _, t in ipairs(tracks) do
        if isMissileTrack(t) then
            local tx, ty, tz = extractXYZ(t)
            if tx and ty and tz then
                local id = t.id or t.uuid or t.shipId

                if trackedId and id and id == trackedId then
                    bestTrack = { x = tx, y = ty, z = tz, id = id }
                    break
                end

                local d = math.sqrt(
                    (tx - lastKnownPos.x)^2 +
                    (ty - lastKnownPos.y)^2 +
                    (tz - lastKnownPos.z)^2
                )
                if d < bestDist then
                    bestDist = d
                    bestTrack = { x = tx, y = ty, z = tz, id = id }
                end
            end
        end
    end

    if bestTrack then
        if bestTrack.id then trackedId = bestTrack.id end
        lastKnownPos = { x = bestTrack.x, y = bestTrack.y, z = bestTrack.z }
        return bestTrack.x, bestTrack.y, bestTrack.z
    end

    return nil
end

-- Fase 1: 2 segundos iniciais em nível baixo (3/15) para sair suave
print(("Saída suave por %.1fs (nível %d/15) a partir de (47, -61, -18)..."):format(START_TIME, START_STRAIGHT))
setAnalog(SIDES.power, START_STRAIGHT)
setAnalog(SIDES.north, 0)
setAnalog(SIDES.south, 0)
setAnalog(SIDES.east,  0)
setAnalog(SIDES.west,  0)

local elapsed = 0.0
while elapsed < START_TIME do
    local cx, cy, cz = findMissilePosition()
    if cx then
        lastKnownPos = { x = cx, y = cy, z = cz }
    end
    sleep(LOOP_DT)
    elapsed = elapsed + LOOP_DT
end

-- Fase 2: guiagem proporcional (0 a 15) até (179, -59, -160)
local prevDx, prevDz = nil, nil
local lostFrames = 0

print("Guiando para (179, -59, -160)...")

while true do
    local cx, cy, cz = findMissilePosition()

    if not cx then
        lostFrames = lostFrames + 1
        if lostFrames > 40 then
            print("Míssil não encontrado no radar. Desligando...")
            shutdownAll()
            break
        end
    else
        lostFrames = 0
        local dx = TARGET.x - cx
        local dz = TARGET.z - cz

        local distHoriz = math.sqrt(dx * dx + dz * dz)
        if distHoriz <= ARRIVAL_RADIUS then
            print(("Alvo alcançado! Distância: %.2f m"):format(distHoriz))
            shutdownAll()
            break
        end

        local speedFactor = clamp(distHoriz / 40.0, 0.0, 1.0)
        local straightLevel = math.max(1, math.floor(speedFactor * MAX_STRAIGHT + 0.5))
        setAnalog(SIDES.power, straightLevel)

        local dt = (type(LOOP_DT) == "number" and LOOP_DT > 0) and LOOP_DT or 0.05
        local ddx = (type(prevDx) == "number") and ((dx - prevDx) / dt) or 0
        local ddz = (type(prevDz) == "number") and ((dz - prevDz) / dt) or 0
        prevDx, prevDz = dx, dz

        local cmdEast  = clamp(KP_HORIZ * dx + KD_HORIZ * ddx, -1.0, 1.0)
        local cmdSouth = clamp(KP_HORIZ * dz + KD_HORIZ * ddz, -1.0, 1.0)

        if cmdEast > 0.02 then
            setAnalog(SIDES.east, cmdEast * 15)
            setAnalog(SIDES.west, 0)
        elseif cmdEast < -0.02 then
            setAnalog(SIDES.west, -cmdEast * 15)
            setAnalog(SIDES.east, 0)
        else
            setAnalog(SIDES.east, 0)
            setAnalog(SIDES.west, 0)
        end

        if cmdSouth > 0.02 then
            setAnalog(SIDES.south, cmdSouth * 15)
            setAnalog(SIDES.north, 0)
        elseif cmdSouth < -0.02 then
            setAnalog(SIDES.north, -cmdSouth * 15)
            setAnalog(SIDES.south, 0)
        else
            setAnalog(SIDES.south, 0)
            setAnalog(SIDES.north, 0)
        end
    end

    sleep(LOOP_DT)
end
