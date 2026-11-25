-- ==========================================================
-- GUIAGEM DE MÍSSIL POR RADAR (create_radar:radar_bearing_0)
-- Curva estável sem oscilação ("ficar maluco ao virar")
-- ==========================================================

local LAUNCH_POS = { x = 47,  y = -61, z = -18 }
local TARGET     = { x = 179, y = -59, z = -160 }

local START_TIME     = 2.0  -- 2 segundos iniciais
local START_STRAIGHT = 2    -- Nível suave nos 2s iniciais (1..15)
local MAX_STRAIGHT   = 5    -- Avanço contido para não abrir curva demais
local MAX_TURN_OUT   = 4    -- Força máxima de virada (0..15) bem controlada

local MAX_STEP_POWER = 1
local MAX_STEP_TURN  = 1

local LOOP_DT        = 0.05
local ARRIVAL_RADIUS = 6.0
local TURN_DEADBAND  = 4.0  -- Só corrige se estiver a mais de 4 blocos do eixo

-- Controle proporcional suave (sem derivada para não gerar picos)
local KP_HORIZ       = 0.008
local SMOOTH_ALPHA   = 0.25 -- Suavização do erro (0.1 = bem suave, 1.0 = sem filtro)

local SIDES = {
    north = "back",   -- Norte (-Z): concreto marrom
    south = "front",  -- Sul (+Z): 2 concretos brancos
    east  = "right",  -- Leste (+X): concreto preto
    west  = "left",   -- Oeste (-X): concreto lima
    power = "bottom", -- Baixo: 2 concretos vermelhos (ir reto)
}

local RADAR_NAME = "create_radar:radar_bearing_0"

local currentOut = {
    [SIDES.north] = 0,
    [SIDES.south] = 0,
    [SIDES.east]  = 0,
    [SIDES.west]  = 0,
    [SIDES.power] = 0,
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function setAnalog(side, targetVal, maxStep)
    local desired = math.max(0, math.min(15, math.floor(targetVal + 0.5)))
    local prev = currentOut[side] or 0
    local nextVal = desired

    if maxStep and maxStep > 0 then
        nextVal = clamp(desired, prev - maxStep, prev + maxStep)
    end

    currentOut[side] = nextVal
    redstone.setAnalogOutput(side, nextVal)
end

local function shutdownAll()
    for _, side in pairs(SIDES) do
        currentOut[side] = 0
        redstone.setAnalogOutput(side, 0)
    end
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

-- Fase 1: 2 segundos iniciais suaves
print(("Saída suave por %.1fs (nível %d/15) a partir de (47, -61, -18)..."):format(START_TIME, START_STRAIGHT))
setAnalog(SIDES.power, START_STRAIGHT, 0)
setAnalog(SIDES.north, 0, 0)
setAnalog(SIDES.south, 0, 0)
setAnalog(SIDES.east,  0, 0)
setAnalog(SIDES.west,  0, 0)

local elapsed = 0.0
while elapsed < START_TIME do
    local cx, cy, cz = findMissilePosition()
    if cx then
        lastKnownPos = { x = cx, y = cy, z = cz }
    end
    sleep(LOOP_DT)
    elapsed = elapsed + LOOP_DT
end

-- Fase 2: guiagem estável até (179, -59, -160)
local filtDx, filtDz = nil, nil
local lostFrames = 0

print("Guiando com curva suave para (179, -59, -160)...")

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
        local rawDx = TARGET.x - cx
        local rawDz = TARGET.z - cz

        if not filtDx then
            filtDx, filtDz = rawDx, rawDz
        else
            filtDx = filtDx + SMOOTH_ALPHA * (rawDx - filtDx)
            filtDz = filtDz + SMOOTH_ALPHA * (rawDz - filtDz)
        end

        local distHoriz = math.sqrt(rawDx * rawDx + rawDz * rawDz)
        if distHoriz <= ARRIVAL_RADIUS then
            print(("Alvo alcançado! Distância: %.2f m"):format(distHoriz))
            shutdownAll()
            break
        end

        local speedFactor = clamp(distHoriz / 60.0, 0.0, 1.0)
        local desiredStraight = math.max(1, math.floor(speedFactor * MAX_STRAIGHT + 0.5))
        setAnalog(SIDES.power, desiredStraight, MAX_STEP_POWER)

        local cmdEast  = clamp(KP_HORIZ * filtDx, -1.0, 1.0)
        local cmdSouth = clamp(KP_HORIZ * filtDz, -1.0, 1.0)

        if filtDx > TURN_DEADBAND then
            setAnalog(SIDES.east, math.max(1, cmdEast * MAX_TURN_OUT), MAX_STEP_TURN)
            setAnalog(SIDES.west, 0, MAX_STEP_TURN)
        elseif filtDx < -TURN_DEADBAND then
            setAnalog(SIDES.west, math.max(1, -cmdEast * MAX_TURN_OUT), MAX_STEP_TURN)
            setAnalog(SIDES.east, 0, MAX_STEP_TURN)
        else
            setAnalog(SIDES.east, 0, MAX_STEP_TURN)
            setAnalog(SIDES.west, 0, MAX_STEP_TURN)
        end

        if filtDz > TURN_DEADBAND then
            setAnalog(SIDES.south, math.max(1, cmdSouth * MAX_TURN_OUT), MAX_STEP_TURN)
            setAnalog(SIDES.north, 0, MAX_STEP_TURN)
        elseif filtDz < -TURN_DEADBAND then
            setAnalog(SIDES.north, math.max(1, -cmdSouth * MAX_TURN_OUT), MAX_STEP_TURN)
            setAnalog(SIDES.south, 0, MAX_STEP_TURN)
        else
            setAnalog(SIDES.south, 0, MAX_STEP_TURN)
            setAnalog(SIDES.north, 0, MAX_STEP_TURN)
        end
    end

    sleep(LOOP_DT)
end
