-- ==========================================================
-- GUIAGEM DE MÍSSIL POR RADAR (create_radar:radar_bearing_0)
-- Fase inicial: sobe por 10s e depois guia até o alvo
-- Trás (back): Norte (-Z) | Frente (front): Sul (+Z)
-- Direita (right): Leste (+X) | Esquerda (left): Oeste (-X)
-- Baixo (bottom): Intensidade / Liga-Desliga (2x concreto vermelho)
-- Massa: 10,25 kpg | Gravidade: 11 m/s² | Peso: 112,75
-- ==========================================================

-- 1. POSIÇÃO INICIAL DO MÍSSIL E ALVO
local LAUNCH_POS = { x = 48,  y = -60, z = -18 }
local TARGET     = { x = 179, y = -59, z = -160 }

-- 2. FÍSICA DO MÍSSIL
local MASS_KPG       = 10.25
local GRAVITY        = 11.0
local WEIGHT         = MASS_KPG * GRAVITY -- 112.75
local MAX_THRUST     = 260.0

-- 3. PARÂMETROS DE SUBIDA E CONTROLE
local CLIMB_TIME     = 10.0 -- Segundos subindo antes de ir ao alvo
local CLIMB_LIFT     = 0.35 -- Intensidade vertical na subida (ajuste se subir pouco ou muito)
local CLIMB_POWER    = 15   -- Potência em 'bottom' durante a subida

local LOOP_DT        = 0.05
local ARRIVAL_RADIUS = 5.0
local MIN_POWER      = 6

local KP_HORIZ       = 0.12
local KD_HORIZ       = 0.04
local KP_VERT        = 0.18
local KD_VERT        = 0.06

-- 4. FACES DO COMPUTADOR
local SIDES = {
    north = "back",   -- Norte (-Z): concreto marrom
    south = "front",  -- Sul (+Z): 2 concretos brancos
    east  = "right",  -- Leste (+X): concreto preto
    west  = "left",   -- Oeste (-X): concreto lima
    power = "bottom", -- Baixo: 2 concretos vermelhos
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

-- ==========================================================
-- LEITURA DO RADAR (FILTRANDO SABLE / Sable:ship)
-- ==========================================================
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

-- ==========================================================
-- FASE 1: SUBIDA INICIAL POR 10 SEGUNDOS
-- ==========================================================
print(("Subindo por %.0f segundos antes de ir ao alvo..."):format(CLIMB_TIME))
setAnalog(SIDES.power, CLIMB_POWER)
setAnalog(SIDES.north, 0)
setAnalog(SIDES.south, 0)
setAnalog(SIDES.east,  0)
setAnalog(SIDES.west,  0)

local climbElapsed = 0.0
while climbElapsed < CLIMB_TIME do
    -- Atualiza a última posição conhecida pelo radar durante a subida
    local cx, cy, cz = findMissilePosition()
    if cx then
        lastKnownPos = { x = cx, y = cy, z = cz }
    end

    -- Aplica impulso vertical leve nas faces mantendo direção horizontal zerada
    local vertSignal = clamp(CLIMB_LIFT * 0.25, 0.0, 0.5) * 15
    setAnalog(SIDES.north, vertSignal)
    setAnalog(SIDES.south, vertSignal)
    setAnalog(SIDES.east,  vertSignal)
    setAnalog(SIDES.west,  vertSignal)

    sleep(LOOP_DT)
    climbElapsed = climbElapsed + LOOP_DT
end

-- Zera os sinais direcionais antes de iniciar a guiagem para o alvo
setAnalog(SIDES.north, 0)
setAnalog(SIDES.south, 0)
setAnalog(SIDES.east,  0)
setAnalog(SIDES.west,  0)

-- ==========================================================
-- FASE 2: LOOP PRINCIPAL DE GUIAGEM ATÉ O ALVO
-- ==========================================================
local prevDx, prevDz, prevDy = nil, nil, nil
local lostFrames = 0

print("Subida concluída! Guiando para (179, -59, -160)...")

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

        local dist3D = math.sqrt(dx * dx + (TARGET.y - cy)^2 + dz * dz)
        if dist3D <= ARRIVAL_RADIUS then
            print(("Alvo alcançado! Distância: %.2f m"):format(dist3D))
            shutdownAll()
            break
        end

        local throttle01 = dist3D < 25.0 and clamp(dist3D / 25.0, 0.4, 1.0) or 1.0
        local powerVal = math.max(MIN_POWER, math.floor(throttle01 * 15 + 0.5))
        setAnalog(SIDES.power, powerVal)

        local curThrust = math.max(1.0, MAX_THRUST * (powerVal / 15.0))
        local gravLift  = clamp((WEIGHT / curThrust) * 6.0, 0.0, 8.0)
        local dy = (TARGET.y - cy) + gravLift

        local ddx = prevDx and ((dx - prevDx) / LOOP_DT) or 0
        local ddz = prevDz and ((dz - prevDz) / LOOP_DT) or 0
        local ddy = prevDy and ((dy - prevDy) / LOOP_DT) or 0
        prevDx, prevDz, prevDy = dx, dz, dy

        local cmdEast  = clamp(KP_HORIZ * dx + KD_HORIZ * ddx, -1.0, 1.0)
        local cmdSouth = clamp(KP_HORIZ * dz + KD_HORIZ * ddz, -1.0, 1.0)
        local cmdVert  = clamp(KP_VERT  * dy + KD_VERT  * ddy, -0.5, 0.5)

        if cmdEast >= 0 then
            setAnalog(SIDES.east, (cmdEast + cmdVert * 0.25) * 15)
            setAnalog(SIDES.west, 0)
        else
            setAnalog(SIDES.west, (-cmdEast + cmdVert * 0.25) * 15)
            setAnalog(SIDES.east, 0)
        end

        if cmdSouth >= 0 then
            setAnalog(SIDES.south, (cmdSouth + cmdVert * 0.25) * 15)
            setAnalog(SIDES.north, 0)
        else
            setAnalog(SIDES.north, (-cmdSouth + cmdVert * 0.25) * 15)
            setAnalog(SIDES.south, 0)
        end
    end

    sleep(LOOP_DT)
end
