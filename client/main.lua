-- ─── Main client — sincronização, zonas, NPCs e animais ──────────────────────

Farms = {}

local farmZones         = {}   -- [farmId] = lib.zones handle
local farmBlips         = {}   -- [farmId] = blip handle
local buyerPeds         = {}   -- [farmId] = ped entity
local spawnedAnimals    = {}   -- [animalId] = { entity, targetAdded, roaming }
local animalData        = {}   -- [animalId] = snapshot do servidor
local corralSupplyZones = {}   -- [farmId] = { zone, zone }
local currentFarmId     = nil  -- fazenda com tablet aberto
local nuiOpen           = false
local openFarmTablet    -- forward declaration
local getSupplyZoneCenter
local getAnimalNeedZone
local travelAnimalToNeedZone

TruckSaleState = TruckSaleState or {
    active = false,
    arrived = false,
    farmId = nil,
    eventId = nil,
    animalType = nil,
    loadedAnimals = {},
    loadedCount = 0,
    maxLoad = 0,
}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function notify(description, notifyType, title)
    lib.notify({
        title       = title or 'Fazenda',
        description = description,
        type        = notifyType or 'inform',
    })
end

local function getAnimalStatusLabel(animalType)
    if animalType == 'cow' then return 'Vaca' end
    if animalType == 'pig' then return 'Porco' end
    return 'Animal'
end

local function getEstimatedSellPrice(snap)
    if not snap then return nil end

    if snap.type == 'cow' then
        local startPrice = tonumber(Config.Payments.cowSellStart) or tonumber(Config.Payments.cowSell) or 0
        local maxPrice = tonumber(Config.Payments.cowSellMax) or startPrice
        local stepHours = math.max(1, math.floor(tonumber(Config.Payments.cowSellAgeStepHours) or 24))
        local stepValue = math.max(0, math.floor(tonumber(Config.Payments.cowSellAgeStepValue) or 0))
        local ageHours = math.floor((tonumber(snap.ageDays) or 0) * 24)

        return math.min(maxPrice, startPrice + (math.floor(ageHours / stepHours) * stepValue))
    end

    if snap.type == 'pig' then
        local basePrice = tonumber(Config.Payments.pigSell) or 0
        local bonusSteps = math.min(tonumber(snap.ageDays) or 0, 10)
        return math.floor((basePrice * (1.0 + (bonusSteps * 0.05))) + 0.5)
    end

    return nil
end

local function showAnimalStatus(farmId, snap)
    if not snap then
        notify('Sem dados.', 'error')
        return
    end
    if nuiOpen and currentFarmId == farmId then
        SendNUIMessage({ type = 'switchTab', tab = 'animals' })
    else
        openFarmTablet(farmId, 'animals')
    end
end

local function isCartel()
    local player = exports.qbx_core:GetPlayerData()
    if not player or not player.gang then return false end
    if player.gang.name ~= Config.CartelGang then return false end
    return player.gang.grade and player.gang.grade.level >= 0
end

local function progress(actionCfg)
    return lib.progressBar({
        duration     = actionCfg.duration,
        label        = actionCfg.label,
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true, mouse = false },
        anim         = { dict = actionCfg.anim.dict, clip = actionCfg.anim.clip },
    })
end

local function resolveGroundZ(x, y, fallbackZ)
    local probeHeights = { fallbackZ + 2.0, fallbackZ + 10.0, fallbackZ + 25.0, fallbackZ + 50.0 }

    for i = 1, #probeHeights do
        local ok, groundZ = GetGroundZFor_3dCoord(x, y, probeHeights[i], false)
        if ok then
            return groundZ
        end
    end

    return fallbackZ
end

local function isPointInPolygon(point, polygonPoints)
    if not point or not polygonPoints or #polygonPoints < 3 then return false end

    local inside = false
    local j = #polygonPoints

    for i = 1, #polygonPoints do
        local pi = polygonPoints[i]
        local pj = polygonPoints[j]

        local intersects = ((pi.y > point.y) ~= (pj.y > point.y))
            and (point.x < (pj.x - pi.x) * (point.y - pi.y) / ((pj.y - pi.y) + 0.000001) + pi.x)

        if intersects then
            inside = not inside
        end

        j = i
    end

    return inside
end

local function isPlayerInsideFarm(farm)
    if not farm or not farm.area or not farm.area.points or #farm.area.points < 3 then
        return false
    end

    local playerCoords = GetEntityCoords(cache.ped)
    local thickness = farm.area.thickness or 8.0
    local firstPoint = farm.area.points[1]
    local baseZ = firstPoint and firstPoint.z or playerCoords.z

    if math.abs(playerCoords.z - baseZ) > thickness then
        return false
    end

    return isPointInPolygon({ x = playerCoords.x, y = playerCoords.y }, farm.area.points)
end

local function isPointInsideCorral(corral, coords)
    if not corral or not corral.area or not corral.area.points or #corral.area.points < 3 or not coords then
        return false
    end

    return isPointInPolygon({ x = coords.x, y = coords.y }, corral.area.points)
end

local function getNearestCorralReturnPoint(corral, pedCoords)
    if not corral or not corral.spawn_points or #corral.spawn_points == 0 then
        return nil
    end

    local closestPoint = corral.spawn_points[1]
    local closestDistance = math.huge

    for _, point in ipairs(corral.spawn_points) do
        local dist = #(vec3(point.x, point.y, pedCoords.z or point.z or 0.0) - vec3(pedCoords.x, pedCoords.y, pedCoords.z or point.z or 0.0))
        if dist < closestDistance then
            closestDistance = dist
            closestPoint = point
        end
    end

    return closestPoint
end

local function getCorralRoamData(corral)
    local points = corral and corral.area and corral.area.points
    if not points or #points == 0 then return nil end

    local sumX, sumY, sumZ = 0.0, 0.0, 0.0
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for _, point in ipairs(points) do
        sumX = sumX + point.x
        sumY = sumY + point.y
        sumZ = sumZ + point.z
        if point.x < minX then minX = point.x end
        if point.y < minY then minY = point.y end
        if point.x > maxX then maxX = point.x end
        if point.y > maxY then maxY = point.y end
    end

    local center = vec3(sumX / #points, sumY / #points, sumZ / #points)
    local maxDistance = 0.0
    for _, point in ipairs(points) do
        local dist = #(vec3(point.x, point.y, center.z) - center)
        if dist > maxDistance then
            maxDistance = dist
        end
    end

    local roamCfg = Config.AnimalRoaming or {}
    local radius = math.max(roamCfg.minRadius or 4.0, maxDistance - (roamCfg.padding or 1.5))

    return {
        center = center,
        radius = radius,
        points = points,
        bounds = {
            minX = minX,
            minY = minY,
            maxX = maxX,
            maxY = maxY,
        },
        leashDistance = roamCfg.leashDistance or 6.0,
        repathInterval = roamCfg.repathInterval or 15000,
    }
end

local function getAnimalSpreadAnchor(animalId, ped, corral, roamData)
    local pedCoords = GetEntityCoords(ped)
    if isPointInsideCorral(corral, pedCoords) then
        return vec3(pedCoords.x, pedCoords.y, pedCoords.z)
    end

    local slot = tonumber((animalId or ''):match('_(%d+)$')) or 1
    local totalSlots = math.max(1, #(corral and corral.spawn_points or {}))
    local normalized = math.min(1.0, math.max(0.0, (slot - 0.5) / totalSlots))
    local goldenAngle = 2.399963229728653
    local angle = slot * goldenAngle
    local radialScale = 0.30 + (0.55 * math.sqrt(normalized))
    local desiredRadius = roamData.radius * radialScale
    local candidateX = roamData.center.x + math.cos(angle) * desiredRadius
    local candidateY = roamData.center.y + math.sin(angle) * desiredRadius

    if isPointInPolygon({ x = candidateX, y = candidateY }, roamData.points) then
        local candidateZ = resolveGroundZ(candidateX, candidateY, roamData.center.z)
        return vec3(candidateX, candidateY, candidateZ)
    end

    local b = roamData.bounds
    for _ = 1, 25 do
        local randX = b.minX + (math.random() * (b.maxX - b.minX))
        local randY = b.minY + (math.random() * (b.maxY - b.minY))
        if isPointInPolygon({ x = randX, y = randY }, roamData.points) then
            local randZ = resolveGroundZ(randX, randY, roamData.center.z)
            return vec3(randX, randY, randZ)
        end
    end

    return roamData.center
end

-- Anims de pastagem — pré-carregadas uma vez por sessão de roaming
local GRAZE_ANIM_DICT = 'ANIMALS@QUADRUPED@COW'
local GRAZE_ANIM_CLIP = 'eat_grass_loop'
local grazeAnimReady  = false

local function ensureGrazeAnim()
    if grazeAnimReady then return true end
    if not HasAnimDictLoaded(GRAZE_ANIM_DICT) then
        RequestAnimDict(GRAZE_ANIM_DICT)
        local deadline = GetGameTimer() + 3000
        while not HasAnimDictLoaded(GRAZE_ANIM_DICT) and GetGameTimer() < deadline do
            Wait(100)
        end
    end
    grazeAnimReady = HasAnimDictLoaded(GRAZE_ANIM_DICT)
    return grazeAnimReady
end

-- Escolhe comportamento para o próximo ciclo: 'graze' | 'wander' | 'stroll' | 'need'
local function pickBehavior(animalId, animalType, corral)
    if travelAnimalToNeedZone and getAnimalNeedZone(animalId, corral) then
        return 'need'
    end
    local roll = math.random()
    if animalType == 'cow' then
        -- Vacas: mais tempo paradas pastando, movimento lento e curto
        if roll < 0.40 then return 'graze'  end  -- 40% pasta no lugar
        if roll < 0.75 then return 'stroll' end  -- 35% anda devagar para perto
        return 'wander'                           -- 25% wander normal
    end
    -- Porcos: mais agitados
    if roll < 0.20 then return 'graze'  end
    if roll < 0.55 then return 'stroll' end
    return 'wander'
end

-- Caminha devagar até um ponto próximo ao anchor (mais natural que TaskWanderInArea)
local function strollToNearby(ped, anchor, radius, heading)
    local angle  = math.random() * math.pi * 2
    local dist   = 2.0 + math.random() * math.min(radius * 0.5, 6.0)
    local tx     = anchor.x + math.cos(angle) * dist
    local ty     = anchor.y + math.sin(angle) * dist
    local tz     = resolveGroundZ(tx, ty, anchor.z)
    local speed  = 0.6 + math.random() * 0.6   -- 0.6–1.2 m/s  (passo de pasto)
    ClearPedTasks(ped)
    TaskGoStraightToCoord(ped, tx, ty, tz, speed, 8000, heading or GetEntityHeading(ped), 0.3)
end

local function startAnimalRoaming(animalId, ped, corral, animalType)
    local roamCfg = Config.AnimalRoaming or {}
    if roamCfg.enabled == false or not DoesEntityExist(ped) then return nil end

    local roamData = getCorralRoamData(corral)
    if not roamData then return nil end

    local spreadAnchor = getAnimalSpreadAnchor(animalId, ped, corral, roamData)
    local localRadius  = roamData.radius
    if animalType == 'cow' then
        localRadius = math.max(4.0, math.min(roamData.radius, roamData.radius * 0.45))
    end

    local roaming = {
        active     = true,
        ped        = ped,
        roamData   = roamData,
        corral     = corral,
        anchor     = spreadAnchor,
        localRadius = localRadius,
    }

    -- Início: wander leve
    ClearPedTasks(ped)
    if not travelAnimalToNeedZone(animalId, ped, corral) then
        TaskWanderInArea(ped, spreadAnchor.x, spreadAnchor.y, spreadAnchor.z, localRadius, 1.0, 14.0)
    end

    -- Pré-carrega dict de anim em background sem bloquear
    CreateThread(function() ensureGrazeAnim() end)

    CreateThread(function()
        -- Espaçar o ciclo de cada animal levemente para não sincronizarem (mais natural)
        local slot = tonumber((animalId or ''):match('_(%d+)$')) or 1
        Wait((slot % 5) * 1800)

        while roaming.active and spawnedAnimals[animalId] and DoesEntityExist(ped) do
            local interval = roamData.repathInterval + math.random(-3000, 3000)
            Wait(math.max(8000, interval))
            if not roaming.active or not spawnedAnimals[animalId] or not DoesEntityExist(ped) then break end

            -- Leash: se saiu do curral, teleporta de volta
            local pedCoords    = GetEntityCoords(ped)
            local horizDist    = #(vec3(pedCoords.x, pedCoords.y, roamData.center.z) - roamData.center)
            local outsideCorral = not isPointInsideCorral(roaming.corral, pedCoords)

            if horizDist > (roamData.radius + roamData.leashDistance) or outsideCorral then
                local rp = getNearestCorralReturnPoint(roaming.corral, pedCoords)
                local tx = rp and rp.x or roamData.center.x
                local ty = rp and rp.y or roamData.center.y
                local tz = resolveGroundZ(tx, ty, rp and rp.z or roamData.center.z)
                ClearPedTasksImmediately(ped)
                SetEntityCoordsNoOffset(ped, tx, ty, tz, false, false, false)
                SetEntityHeading(ped, rp and (rp.w or GetEntityHeading(ped)) or GetEntityHeading(ped))
            end

            -- Escolher próximo comportamento
            local behavior = pickBehavior(animalId, animalType, corral)

            if behavior == 'need' then
                travelAnimalToNeedZone(animalId, ped, corral)

            elseif behavior == 'graze' and grazeAnimReady then
                -- Pasta no lugar com animação
                local grazeDuration = 5000 + math.random(0, 6000)
                ClearPedTasks(ped)
                SetEntityHeading(ped, math.random() * 360.0)
                TaskPlayAnim(ped, GRAZE_ANIM_DICT, GRAZE_ANIM_CLIP, 2.0, -1.0, grazeDuration, 1, 0.0, false, false, false)
                Wait(grazeDuration)
                if roaming.active and DoesEntityExist(ped) then ClearPedTasks(ped) end

            elseif behavior == 'stroll' then
                strollToNearby(ped, roaming.anchor, localRadius, nil)

            else -- 'wander'
                ClearPedTasks(ped)
                TaskWanderInArea(ped, roaming.anchor.x, roaming.anchor.y, roaming.anchor.z, localRadius, 1.0, 14.0)
            end
        end
    end)

    return roaming
end

local function resumeAnimalRoaming(animalId)
    local entry = spawnedAnimals[animalId]
    local roaming = entry and entry.roaming
    if not roaming or not roaming.active or not DoesEntityExist(roaming.ped) then return end

    if not travelAnimalToNeedZone(animalId, roaming.ped, roaming.corral) then
        ClearPedTasks(roaming.ped)
        TaskWanderInArea(roaming.ped, roaming.anchor.x, roaming.anchor.y, roaming.anchor.z, roaming.localRadius, 2.0, 10.0)
    end
end

local function holdAnimalStill(animalId)
    local entry = spawnedAnimals[animalId]
    local ped = entry and entry.entity
    if not ped or not DoesEntityExist(ped) then return end

    ClearPedTasksImmediately(ped)
    FreezeEntityPosition(ped, true)
end

local function releaseAnimalStill(animalId)
    local entry = spawnedAnimals[animalId]
    local ped = entry and entry.entity
    if not ped or not DoesEntityExist(ped) then return end

    FreezeEntityPosition(ped, false)
end

-- ─── Ações de animais ─────────────────────────────────────────────────────────

local function doAnimalAction(animalId, action, actionCfg)
    local started = lib.callback.await('rodz-fazenda:server:beginAction', false, animalId, action)
    if not started or not started.ok then
        notify(started and started.msg or 'Não foi possível iniciar.', 'error')
        return
    end

    if action == 'milk_cow' then
        holdAnimalStill(animalId)
    end

    local done = progress(actionCfg)
    if not done then
        lib.callback.await('rodz-fazenda:server:cancelAction', false, animalId, started.token, action)
        if action == 'milk_cow' then
            releaseAnimalStill(animalId)
        end
        resumeAnimalRoaming(animalId)
        notify('Ação cancelada.', 'error')
        return
    end

    local result = lib.callback.await('rodz-fazenda:server:completeAction', false,
        animalId, started.token, action)
    if action == 'milk_cow' then
        releaseAnimalStill(animalId)
    end
    resumeAnimalRoaming(animalId)

    if result and result.ok then
        notify(result.msg or 'Concluído!', 'success')
        if result.snapshots then animalData = result.snapshots end
    else
        notify(result and result.msg or 'Falha.', 'error')
    end
end

-- ─── Targets de animais ───────────────────────────────────────────────────────

local function animalTargets(animalId, animalType, farmId)
    local function canLoadIntoTruck()
        if not TruckSaleState.active or not TruckSaleState.arrived or not TruckSaleState.farmId then return false end
        if TruckSaleState.animalType ~= animalType then return false end
        if TruckSaleState.loadedAnimals[animalId] then return false end
        if TruckSaleState.loadedCount >= (TruckSaleState.maxLoad or 0) then return false end
        return animalId:sub(1, #(TruckSaleState.farmId .. '_')) == (TruckSaleState.farmId .. '_')
    end

    local targets = {
        {
            name     = 'rfz_inspect_' .. animalId,
            icon     = 'circle-info',
            label    = 'Ver status',
            distance = Config.TargetDistance,
            onSelect = function()
                local snap = animalData[animalId]
                showAnimalStatus(farmId, snap)
            end,
        },
        {
            name     = 'rfz_medicine_' .. animalId,
            icon     = 'syringe',
            label    = 'Medicar animal',
            distance = Config.TargetDistance,
            onSelect = function() doAnimalAction(animalId, 'use_medicine', Config.Actions.useMedicine) end,
        },
    }

    if animalType ~= 'cow' then
        targets[#targets + 1] = {
            name     = 'rfz_feed_' .. animalId,
            icon     = 'wheat-awn',
            label    = 'Alimentar porco',
            distance = Config.TargetDistance,
            onSelect = function() doAnimalAction(animalId, 'feed_animal', Config.Actions.feedAnimal) end,
        }
    end

    if animalType == 'cow' then
        targets[#targets + 1] = {
            name     = 'rfz_milk_' .. animalId,
            icon     = 'glass-water',
            label    = 'Ordenhar vaca',
            distance = Config.TargetDistance,
            onSelect = function() doAnimalAction(animalId, 'milk_cow', Config.Actions.milkCow) end,
        }
    end

    targets[#targets + 1] = {
        name        = 'rfz_load_truck_' .. animalId,
        icon        = 'truck-ramp-box',
        label       = animalType == 'cow' and 'Colocar vaca no caminhao' or 'Colocar porco no caminhao',
        distance    = Config.TargetDistance,
        canInteract = canLoadIntoTruck,
        onSelect    = function()
            TriggerEvent('rodz-fazenda:client:loadAnimalIntoTruck', animalId)
        end,
    }

    return targets
end

getSupplyZoneCenter = function(zoneData)
    if not zoneData or not zoneData.x then return nil end
    return vec3(zoneData.x, zoneData.y, zoneData.z)
end

getAnimalNeedZone = function(animalId, corral)
    local snap = animalData[animalId]
    if not snap or not corral then return nil end

    local animalCfg = Config.Animals[snap.type or corral.type] or {}
    if (snap.thirst or 100.0) <= (animalCfg.autoDrinkThreshold or 65.0) and corral.water_zone then
        return corral.water_zone, 'water'
    end
    if (snap.hunger or 100.0) <= (animalCfg.autoFeedThreshold or 65.0) and corral.feed_zone then
        return corral.feed_zone, 'feed'
    end

    return nil, nil
end

travelAnimalToNeedZone = function(animalId, ped, corral)
    local zoneData = getAnimalNeedZone(animalId, corral)
    if not zoneData then return false end

    local center = getSupplyZoneCenter(zoneData)
    if not center then return false end

    local groundZ = resolveGroundZ(center.x, center.y, center.z)
    ClearPedTasks(ped)
    TaskGoStraightToCoord(ped, center.x, center.y, groundZ, 1.0, 5000, zoneData.w or GetEntityHeading(ped), 0.1)

    CreateThread(function()
        Wait(5000)
        if DoesEntityExist(ped) and spawnedAnimals[animalId] then
            ClearPedTasks(ped)
        end
    end)

    return true
end

-- ─── Spawn / despawn de animais ───────────────────────────────────────────────

local function spawnAnimal(animalId, animalType, coords, corral, farmId)
    if spawnedAnimals[animalId] then return end

    local animalCfg = Config.Animals[animalType] or {}
    local model = animalCfg.model or 'a_c_cow'
    local pedType = animalCfg.pedType or 28
    local hash  = joaat(model)
    lib.requestModel(hash, 10000)

    local groundZ = resolveGroundZ(coords.x, coords.y, coords.z or 0.0)
    local ped = CreatePed(pedType, hash, coords.x, coords.y, groundZ, coords.w or 0.0, false, false)
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetEntityInvincible(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetPedCanBeTargetted(ped, true)
    SetPedKeepTask(ped, true)
    SetEntityHeading(ped, coords.w or 0.0)

    exports.ox_target:addLocalEntity(ped, animalTargets(animalId, animalType, farmId))
    spawnedAnimals[animalId] = {
        entity = ped,
        targetAdded = true,
        roaming = startAnimalRoaming(animalId, ped, corral, animalType),
    }
end

local function despawnAnimal(animalId)
    local entry = spawnedAnimals[animalId]
    if not entry then return end
    if entry.roaming then entry.roaming.active = false end
    if entry.targetAdded then exports.ox_target:removeLocalEntity(entry.entity) end
    if DoesEntityExist(entry.entity) then DeleteEntity(entry.entity) end
    spawnedAnimals[animalId] = nil
end

local function spawnAnimalsForFarm(farmId)
    local farm = Farms[farmId]
    if not farm then return end

    for _, corral in ipairs(farm.corrals or {}) do
        for slot, point in ipairs(corral.spawn_points or {}) do
            local animalId = farmId .. '_' .. corral.id .. '_' .. slot
            local snap     = animalData[animalId]
            if snap and snap.active then
                spawnAnimal(animalId, corral.type, point, corral, farmId)
            end
        end
    end
end

local function despawnAnimalsForFarm(farmId)
    local farm = Farms[farmId]
    if not farm then return end
    for _, corral in ipairs(farm.corrals or {}) do
        for slot = 1, #(corral.spawn_points or {}) do
            despawnAnimal(farmId .. '_' .. corral.id .. '_' .. slot)
        end
    end
end

local function clearCorralSupplyZones(farmId)
    local zones = corralSupplyZones[farmId]
    if not zones then return end

    for _, zone in ipairs(zones) do
        if zone then
            exports.ox_target:removeZone(zone)
        end
    end

    corralSupplyZones[farmId] = nil
end

local function openCorralSupplyStash(farmId, corrId, supplyType)
    local result = lib.callback.await('rodz-fazenda:server:getCorralSupplyStash', false, farmId, corrId, supplyType)
    if not result or not result.ok or not result.id then
        notify(result and result.msg or 'Nao foi possivel abrir o abastecimento.', 'error')
        return
    end

    exports.ox_inventory:openInventory('stash', { id = result.id })
end

local function createSupplyZone(farmId, corrId, supplyType, zoneData)
    if not zoneData or not zoneData.x then return nil end

    local label = supplyType == 'water' and 'Bebedouro' or 'Comedouro'
    return exports.ox_target:addSphereZone({
        coords = vec3(zoneData.x, zoneData.y, zoneData.z),
        radius = 3.5,
        debug = Config.Debug,
        options = {
            {
                name = ('rfz_supply_%s_%s_%s'):format(farmId, corrId, supplyType),
                icon = supplyType == 'water' and 'glass-water' or 'wheat-awn',
                label = ('Abrir %s'):format(label),
                distance = 3.5,
                canInteract = function()
                    if isCartel() then return true end
                    local f = Farms[farmId]
                    if not f or not f.owner_citizenid then return false end
                    local pd = exports.qbx_core:GetPlayerData()
                    return pd ~= nil and pd.citizenid == f.owner_citizenid
                end,
                onSelect = function()
                    openCorralSupplyStash(farmId, corrId, supplyType)
                end,
            }
        }
    })
end

local function buildCorralSupplyZones(farmId)
    clearCorralSupplyZones(farmId)

    local farm = Farms[farmId]
    if not farm then return end

    corralSupplyZones[farmId] = {}
    for _, corral in ipairs(farm.corrals or {}) do
        if corral.feed_zone then
            corralSupplyZones[farmId][#corralSupplyZones[farmId] + 1] = createSupplyZone(farmId, corral.id, 'feed', corral.feed_zone)
        end
        if corral.water_zone then
            corralSupplyZones[farmId][#corralSupplyZones[farmId] + 1] = createSupplyZone(farmId, corral.id, 'water', corral.water_zone)
        end
    end
end

-- ─── Buyer NPC (fazendeiro) ───────────────────────────────────────────────────

local pedSpawning = {}   -- guard: [farmId] = true enquanto lib.requestModel está pendente

local function despawnBuyerPed(farmId)
    local ped = buyerPeds[farmId]
    if not ped then return end
    if DoesEntityExist(ped) then
        exports.ox_target:removeLocalEntity(ped)
        DeleteEntity(ped)
    end
    buyerPeds[farmId] = nil
end

local function spawnBuyerPed(farmId)
    -- Evita duas calls concorrentes para o mesmo farmId (race no lib.requestModel)
    if pedSpawning[farmId] then return end
    pedSpawning[farmId] = true

    despawnBuyerPed(farmId)

    local farm = Farms[farmId]
    if not farm or not farm.npc_coords then
        pedSpawning[farmId] = nil
        return
    end

    local coords = farm.npc_coords
    if not coords.x then
        pedSpawning[farmId] = nil
        return
    end

    local hash = joaat('a_m_m_farmer_01')
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        pedSpawning[farmId] = nil
        return
    end
    lib.requestModel(hash, 10000)  -- yield até o model carregar
    if not HasModelLoaded(hash) then
        pedSpawning[farmId] = nil
        return
    end

    -- Checa se ainda faz sentido spawnar (pode ter sido cancelado durante o yield)
    if not Farms[farmId] then
        pedSpawning[farmId] = nil
        return
    end

    -- Se outra call criou o ped durante o yield, deleta o órfão antes
    despawnBuyerPed(farmId)

    local spawnZ = coords.z or 0.0
    local ped = CreatePed(4, hash, coords.x, coords.y, spawnZ, coords.w or 0.0, false, false)
    SetEntityAsMissionEntity(ped, true, true)
    SetEntityHeading(ped, coords.w or 0.0)
    SetEntityVisible(ped, true, false)
    SetEntityAlpha(ped, 255, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetPedDefaultComponentVariation(ped)

    exports.ox_target:addLocalEntity(ped, {
        {
            name  = 'rfz_buy_farm_' .. farmId,
            icon  = 'hand-holding-dollar',
            label = (function()
                local f = Farms[farmId]
                local p = f and (tonumber(f.price) or 0) or 0
                return p > 0 and ('Comprar Fazenda ($%s)'):format(p) or 'Comprar Fazenda'
            end)(),
            distance = Config.TargetDistance,
            canInteract = function()
                local f = Farms[farmId]
                return f ~= nil and not f.owner_citizenid
            end,
            onSelect = function()
                local f = Farms[farmId]
                if not f then return end
                local price = tonumber(f.price) or 0
                local msg = price > 0
                    and ('Comprar a fazenda **%s** por **$%s**?'):format(f.name or farmId, price)
                    or  ('Tornar-se dono da fazenda **%s**?'):format(f.name or farmId)
                local ok = lib.alertDialog({
                    header   = 'Comprar Fazenda',
                    content  = msg,
                    centered = true,
                    cancel   = true,
                })
                if ok ~= 'confirm' then return end
                local res = lib.callback.await('rodz-fazenda:server:buyFarm', false, farmId)
                lib.notify({ title = 'Fazenda', description = res.msg, type = res.ok and 'success' or 'error' })
            end,
        },
        {
            name     = 'rfz_buy_listed_' .. farmId,
            icon     = 'handshake',
            label    = 'Comprar Fazenda (proprietário)',
            distance = Config.TargetDistance,
            canInteract = function()
                local f = Farms[farmId]
                if not f or not f.owner_citizenid or not f.sale_price then return false end
                local cid = exports.qbx_core:GetPlayerData().citizenid
                return f.owner_citizenid ~= cid
            end,
            onSelect = function()
                local f = Farms[farmId]
                if not f then return end
                local price = tonumber(f.sale_price) or 0
                local ok = lib.alertDialog({
                    header   = 'Comprar Fazenda',
                    content  = ('Comprar a fazenda **%s** do proprietário atual por **$%s**?'):format(f.name or farmId, price),
                    centered = true,
                    cancel   = true,
                })
                if ok ~= 'confirm' then return end
                local res = lib.callback.await('rodz-fazenda:server:buyFarm', false, farmId)
                lib.notify({ title = 'Fazenda', description = res.msg, type = res.ok and 'success' or 'error' })
            end,
        },
        {
            name     = 'rfz_tablet_' .. farmId,
            icon     = 'tablet-screen-button',
            label    = 'Abrir Tablet da Fazenda',
            distance = Config.TargetDistance,
            canInteract = function()
                local f = Farms[farmId]
                if not f then return false end
                local cid = exports.qbx_core:GetPlayerData().citizenid
                return f.owner_citizenid == cid
            end,
            onSelect = function()
                openFarmTablet(farmId, 'overview')
            end,
        },
    })

    buyerPeds[farmId] = ped
    pedSpawning[farmId] = nil
end

-- ─── Zonas e blips ────────────────────────────────────────────────────────────

local function removeZone(farmId)
    if farmZones[farmId] then
        farmZones[farmId]:remove()
        farmZones[farmId] = nil
    end
    clearCorralSupplyZones(farmId)
    if farmBlips[farmId] then
        RemoveBlip(farmBlips[farmId])
        farmBlips[farmId] = nil
    end
end

local function buildZone(farmId, farm)
    if farmZones[farmId] then return end
    if not farm.area or not farm.area.points or #farm.area.points < 3 then return end

    local pts = {}
    for _, p in ipairs(farm.area.points) do
        pts[#pts + 1] = vec3(p.x, p.y, p.z)
    end

    farmZones[farmId] = lib.zones.poly({
        points    = pts,
        thickness = farm.area.thickness or 8.0,
        debug     = Config.Debug,
        onEnter   = function()
            local data = lib.callback.await('rodz-fazenda:server:getAnimalData', false)
            if data then animalData = data end
            buildCorralSupplyZones(farmId)
            spawnAnimalsForFarm(farmId)
        end,
        onExit    = function()
            clearCorralSupplyZones(farmId)
            despawnAnimalsForFarm(farmId)
        end,
    })

    local center = farm.area.points[1]
    local blip   = AddBlipForCoord(center.x, center.y, center.z)
    SetBlipSprite(blip, 141)
    SetBlipScale(blip,  0.8)
    SetBlipColour(blip, 52)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(farm.name or farmId)
    EndTextCommandSetBlipName(blip)
    farmBlips[farmId] = blip
end

-- ─── Carrega todas as fazendas ────────────────────────────────────────────────

local loadAllPending = false   -- debounce: impede re-entrada enquanto loadAll ainda corre

local function loadAll()
    if loadAllPending then return end
    loadAllPending = true

    for farmId in pairs(farmZones) do
        despawnAnimalsForFarm(farmId)
        despawnBuyerPed(farmId)
        removeZone(farmId)
    end

    local data = lib.callback.await('rodz-fazenda:server:getAnimalData', false)
    if data then animalData = data end

    for farmId, farm in pairs(Farms) do
        buildZone(farmId, farm)
        spawnBuyerPed(farmId)
        spawnAnimalsForFarm(farmId)
        buildCorralSupplyZones(farmId)
    end

    loadAllPending = false
end

-- ─── NUI Tablet ──────────────────────────────────────────────────────────────

openFarmTablet = function(farmId, tab)
    print('[rfz-debug][1] openFarmTablet | farmId=' .. tostring(farmId) .. ' tab=' .. tostring(tab))

    local farm = Farms[farmId]
    if not farm then
        local keys = ''
        for k in pairs(Farms) do keys = keys .. k .. ',' end
        print('[rfz-debug][1-FAIL] farm nao existe em Farms | Farms keys={' .. keys .. '}')
        return
    end
    print('[rfz-debug][2] farm ok | label=' .. tostring(farm.label))

    local data = lib.callback.await('rodz-fazenda:server:getTabletFarmData', false, farmId)
    if not data then
        print('[rfz-debug][3-FAIL] getTabletFarmData retornou nil (timeout ou erro no server)')
        notify('Não foi possível carregar os dados da fazenda.', 'error')
        return
    end
    if not data.ok then
        print('[rfz-debug][3-FAIL] getTabletFarmData ok=false | cowCount=' .. tostring(data.cowCount))
        notify('Não foi possível carregar os dados da fazenda.', 'error')
        return
    end
    print('[rfz-debug][3] getTabletFarmData ok | corrals=#' .. tostring(#(data.corrals or {})) .. ' cows=' .. tostring(data.cowCount) .. ' pigs=' .. tostring(data.pigCount))

    local snapshots = lib.callback.await('rodz-fazenda:server:getAnimalData', false)
    print('[rfz-debug][4] getAnimalData | nil=' .. tostring(snapshots == nil))
    local animals   = {}
    if snapshots then
        for animalId, snap in pairs(snapshots) do
            if animalId:sub(1, #farmId + 1) == farmId .. '_' then
                animals[animalId] = snap
            end
        end
    end
    local animalCount = 0
    for _ in pairs(animals) do animalCount = animalCount + 1 end
    print('[rfz-debug][5] animais desta fazenda=' .. animalCount)

    local playerInv    = lib.callback.await('rodz-fazenda:server:getPlayerInventoryItems', false)
    print('[rfz-debug][6] getPlayerInventoryItems | nil=' .. tostring(playerInv == nil) .. (playerInv and (' milk=' .. tostring(playerInv.milk) .. ' medicine=' .. tostring(playerInv.medicine)) or ''))
    local milkCount    = 0
    local medicineCount = 0
    if playerInv then
        milkCount     = playerInv.milk     or 0
        medicineCount = playerInv.medicine or 0
    end

    currentFarmId = farmId
    nuiOpen       = true

    local accentColor = GetConvar('mri:color', '#00E699')
    print('[rfz-debug][7] SetNuiFocus + SendNUIMessage{type=show} | accentColor=' .. accentColor)
    SetNuiFocus(true, true)
    SendNUIMessage({
        type          = 'show',
        accentColor   = accentColor,
        farmId        = farmId,
        farmName      = farm.name or farm.id or farmId,
        farmPrice     = farm.price or 0,
        salePrice     = farm.sale_price or nil,
        employees     = farm.employees or {},
        isOwner       = farm.owner_citizenid ~= nil and exports.qbx_core:GetPlayerData().citizenid == farm.owner_citizenid,
        corrals       = data.corrals       or {},
        animals       = animals,
        cowCount      = data.cowCount      or 0,
        pigCount      = data.pigCount      or 0,
        milkCount     = milkCount,
        medicineCount = medicineCount,
        prices        = {
            cowBuy           = Config.Payments.cowBuy,
            pigBuy           = Config.Payments.pigBuy,
            feedBuy          = Config.Payments.feedBuy,
            waterBuy         = Config.Payments.waterBuy,
            medicineBuy      = Config.Payments.medicineBuy,
            milkSell         = Config.Payments.milkSell,
            cowSell          = Config.Payments.cowSellStart,
            cowSellStart     = Config.Payments.cowSellStart,
            cowSellMax       = Config.Payments.cowSellMax,
            cowSellAgeStepHours = Config.Payments.cowSellAgeStepHours,
            cowSellAgeStepValue = Config.Payments.cowSellAgeStepValue,
            pigSell          = Config.Payments.pigSell,
        },
        tab = tab or 'overview',
    })
end

RegisterNUICallback('notify', function(data, cb)
    local t = data.type or 'inform'
    lib.notify({
        title       = data.title or 'Fazenda',
        description = data.description or '',
        type        = t == 'inform' and 'info' or t,
    })
    cb({})
end)

RegisterNUICallback('closeMenu', function(_, cb)
    nuiOpen       = false
    currentFarmId = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'hide' })
    cb({})
end)

RegisterNUICallback('getCorrals', function(data, cb)
    local farmId   = currentFarmId
    local farmData = farmId and Farms[farmId]
    if not farmData then cb({ ok = false, corrals = {} }) return end

    local result = {}
    for _, corral in ipairs(farmData.corrals or {}) do
        if corral.type == data.type then
            local totalSlots  = #(corral.spawn_points or {})
            local activeCount = 0
            for animalId, snap in pairs(animalData) do
                if snap and snap.active and animalId:sub(1, #farmId + 1) == farmId .. '_' then
                    local corralPrefix = farmId .. '_' .. corral.id .. '_'
                    if animalId:sub(1, #corralPrefix) == corralPrefix then
                        activeCount = activeCount + 1
                    end
                end
            end
            local available = totalSlots - activeCount
            local typeName  = corral.type == 'cow' and 'Vacas' or 'Porcos'
            local idx       = 0
            for _, c2 in ipairs(farmData.corrals or {}) do
                if c2.type == corral.type then idx = idx + 1 end
                if c2.id == corral.id then break end
            end
            local cLabel = ('Curral de %s %d'):format(typeName, idx)
            result[#result + 1] = {
                value     = corral.id,
                label     = ('%s (%d/%d livres)'):format(cLabel, available, totalSlots),
                available = available,
            }
        end
    end
    cb({ ok = true, corrals = result })
end)

RegisterNUICallback('buyAnimal', function(data, cb)
    local farmId = currentFarmId
    if not farmId then cb({ ok = false, msg = 'Sem fazenda ativa.' }) return end
    local res = lib.callback.await('rodz-fazenda:server:buyAnimalV2', false, farmId, data.type, data.qty, data.corralId)
    if res then
        if res.ok then
            TriggerEvent('rodz-fazenda:client:reloadAnimals', farmId)
        end
        cb(res)
    else
        cb({ ok = false, msg = 'Erro interno.' })
    end
end)

RegisterNUICallback('buyFeed', function(data, cb)
    local res = lib.callback.await('rodz-fazenda:server:buyFeed', false, data.qty)
    cb(res or { ok = false, msg = 'Erro.' })
end)

RegisterNUICallback('buyWater', function(data, cb)
    local res = lib.callback.await('rodz-fazenda:server:buyWater', false, data.qty)
    cb(res or { ok = false, msg = 'Erro.' })
end)

RegisterNUICallback('buyMedicine', function(data, cb)
    local res = lib.callback.await('rodz-fazenda:server:buyMedicine', false, data.qty)
    cb(res or { ok = false, msg = 'Erro.' })
end)

RegisterNUICallback('sellMilk', function(_, cb)
    local res = lib.callback.await('rodz-fazenda:server:sellMilk', false, currentFarmId)
    cb(res or { ok = false, msg = 'Erro.' })
end)

RegisterNUICallback('hireEmployee', function(data, cb)
    local farmId = currentFarmId
    if not farmId then cb({ ok = false, msg = 'Sem fazenda ativa.' }) return end
    local res = lib.callback.await('rodz-fazenda:server:hireEmployee', false, farmId, data.target, data.role, data.salary)
    cb(res or { ok = false, msg = 'Erro interno.' })
end)

RegisterNUICallback('fireEmployee', function(data, cb)
    local farmId = currentFarmId
    if not farmId then cb({ ok = false, msg = 'Sem fazenda ativa.' }) return end
    local res = lib.callback.await('rodz-fazenda:server:fireEmployee', false, farmId, data.citizenid)
    cb(res or { ok = false, msg = 'Erro interno.' })
end)

RegisterNUICallback('updateEmployee', function(data, cb)
    local farmId = currentFarmId
    if not farmId then cb({ ok = false, msg = 'Sem fazenda ativa.' }) return end
    local res = lib.callback.await('rodz-fazenda:server:updateEmployee', false, farmId, data.citizenid, data.role, data.salary)
    cb(res or { ok = false, msg = 'Erro interno.' })
end)

RegisterNUICallback('listFarmForSale', function(data, cb)
    local farmId = currentFarmId
    if not farmId then cb({ ok = false, msg = 'Sem fazenda ativa.' }) return end
    local res = lib.callback.await('rodz-fazenda:server:listFarmForSale', false, farmId, data.price)
    cb(res or { ok = false, msg = 'Erro interno.' })
end)

RegisterNUICallback('cancelFarmListing', function(_, cb)
    local farmId = currentFarmId
    if not farmId then cb({ ok = false, msg = 'Sem fazenda ativa.' }) return end
    local res = lib.callback.await('rodz-fazenda:server:cancelFarmListing', false, farmId)
    cb(res or { ok = false, msg = 'Erro interno.' })
end)

RegisterNUICallback('requestTruck', function(data, cb)
    local farmId = currentFarmId
    if not farmId then cb({ ok = false, msg = 'Sem fazenda ativa.' }) return end
    local res = lib.callback.await('rodz-fazenda:server:requestTruck', false, farmId, data.type, data.qty)
    if res and res.ok then
        TriggerEvent('rodz-fazenda:client:startTruck', res)
        cb({ ok = true })
    else
        cb(res or { ok = false, msg = 'Não foi possível chamar o caminhão.' })
    end
end)

-- ─── Eventos ──────────────────────────────────────────────────────────────────

RegisterNetEvent('rodz-fazenda:client:syncFarms', function(data)
    Farms = data or {}
    loadAll()
end)

-- Abre o tablet de qualquer fazenda como admin (cross-file: creator.lua → main.lua)
AddEventHandler('rodz-fazenda:client:openFarmTabletAdmin', function(farmId)
    openFarmTablet(farmId, 'overview')
end)

-- Limpeza imediata de uma fazenda deletada (chega antes do syncFarms/loadAll)
RegisterNetEvent('rodz-fazenda:client:cleanupFarm', function(farmId)
    if not farmId then return end
    despawnAnimalsForFarm(farmId)
    despawnBuyerPed(farmId)
    removeZone(farmId)
    Farms[farmId] = nil  -- remove localmente para loadAll não a recriar
end)

RegisterNetEvent('rodz-fazenda:client:reloadAnimals')
AddEventHandler('rodz-fazenda:client:reloadAnimals', function(farmId)
    despawnAnimalsForFarm(farmId)
    local data = lib.callback.await('rodz-fazenda:server:getAnimalData', false)
    if data then animalData = data end
    spawnAnimalsForFarm(farmId)

    if nuiOpen and currentFarmId == farmId then
        local farmAnimals = {}
        local cowCount, pigCount = 0, 0
        for animalId, snap in pairs(animalData) do
            if snap and animalId:sub(1, #farmId + 1) == farmId .. '_' then
                farmAnimals[animalId] = snap
                if snap.active then
                    if snap.type == 'cow' then cowCount = cowCount + 1
                    elseif snap.type == 'pig' then pigCount = pigCount + 1 end
                end
            end
        end
        SendNUIMessage({
            type     = 'updateAnimals',
            animals  = farmAnimals,
            cowCount = cowCount,
            pigCount = pigCount,
        })
    end
end)

AddEventHandler('rodz-fazenda:client:markAnimalLoaded', function(animalId)
    local snap = animalData[animalId]
    if snap then
        snap.active = false
    end
    despawnAnimal(animalId)
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(1500)
        TriggerServerEvent('rodz-fazenda:server:requestSync')
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if nuiOpen then
        nuiOpen = false
        currentFarmId = nil
        SetNuiFocus(false, false)
    end
    for farmId in pairs(Farms) do
        despawnAnimalsForFarm(farmId)
        despawnBuyerPed(farmId)
        removeZone(farmId)
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    CreateThread(function()
        Wait(1500)
        TriggerServerEvent('rodz-fazenda:server:requestSync')
    end)
end)
