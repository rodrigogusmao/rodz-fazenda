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

local activeScene = nil  -- { vehicle, driver, farmId, eventId, blip }

local function removeTruckBlip()
    if activeScene and activeScene.blip and DoesBlipExist(activeScene.blip) then
        RemoveBlip(activeScene.blip)
        activeScene.blip = nil
    end
end

local function notify(description, notifyType, title)
    lib.notify({
        title       = title or 'Fazenda',
        description = description,
        type        = notifyType or 'inform',
    })
end

local function resetTruckSaleState()
    TruckSaleState.active = false
    TruckSaleState.arrived = false
    TruckSaleState.farmId = nil
    TruckSaleState.eventId = nil
    TruckSaleState.animalType = nil
    TruckSaleState.loadedAnimals = {}
    TruckSaleState.loadedCount = 0
    TruckSaleState.maxLoad = 0
end

local function getTruckAnimalLabel()
    if TruckSaleState.animalType == 'pig' then
        return 'porco', 'porcos'
    end

    return 'vaca', 'vacas'
end

AddEventHandler('rodz-fazenda:client:loadAnimalIntoTruck', function(animalId)
    if not activeScene or not TruckSaleState.active or not TruckSaleState.arrived then
        return
    end

    if not animalId or TruckSaleState.loadedAnimals[animalId] then
        return
    end

    local result = lib.callback.await('rodz-fazenda:server:loadTruckAnimal', false,
        activeScene.farmId, activeScene.eventId, animalId)

    if not result or not result.ok then
        notify(result and result.msg or 'Nao foi possivel carregar o animal.', 'error')
        return
    end

    TruckSaleState.loadedAnimals[animalId] = true
    TruckSaleState.loadedCount = result.loadedCount or (TruckSaleState.loadedCount + 1)
    TruckSaleState.maxLoad = result.maxLoad or TruckSaleState.maxLoad
    TriggerEvent('rodz-fazenda:client:markAnimalLoaded', animalId)
    notify(result.msg or 'Animal carregado no caminhao.', 'success')
end)

local function cleanScene()
    if not activeScene then
        resetTruckSaleState()
        return
    end

    removeTruckBlip()

    if activeScene.driver and DoesEntityExist(activeScene.driver) then
        exports.ox_target:removeLocalEntity(activeScene.driver)
        DeleteEntity(activeScene.driver)
    end

    if activeScene.vehicle and DoesEntityExist(activeScene.vehicle) then
        exports.ox_target:removeLocalEntity(activeScene.vehicle)
        DeleteEntity(activeScene.vehicle)
    end

    activeScene = nil
    resetTruckSaleState()
end

local function createTruckBlip(coords)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 67)
    SetBlipColour(blip, 5)
    SetBlipScale(blip, 0.9)
    SetBlipDisplay(blip, 4)
    SetBlipAsShortRange(blip, false)
    SetBlipFlashes(blip, true)
    SetBlipRoute(blip, true)
    SetBlipRouteColour(blip, 5)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Caminhao boiadeiro')
    EndTextCommandSetBlipName(blip)
    return blip
end

local function startTruckBlipTracker(vehicle)
    CreateThread(function()
        while activeScene and activeScene.vehicle == vehicle and DoesEntityExist(vehicle) and activeScene.blip do
            local coords = GetEntityCoords(vehicle)
            SetBlipCoords(activeScene.blip, coords.x, coords.y, coords.z)
            Wait(500)
        end
    end)
end

local function resolveSpawnZ(x, y, fallbackZ)
    local heights = { fallbackZ + 1.0, fallbackZ + 5.0, fallbackZ + 15.0, fallbackZ + 30.0 }
    for i = 1, #heights do
        local ok, groundZ = GetGroundZFor_3dCoord(x, y, heights[i], false)
        if ok then
            return groundZ
        end
    end
    return fallbackZ
end

local function resolveVehicleModel(cfg)
    local requestedName = (cfg and cfg.vehicle) or 'benson'
    local requestedHash = joaat(requestedName)
    if IsModelInCdimage(requestedHash) and IsModelAVehicle(requestedHash) then
        return requestedHash, requestedName, false
    end

    local fallbackName = 'mule'
    return joaat(fallbackName), fallbackName, true
end

local function driveAway(vehicle, driver)
    local returnPoint = Config.TruckSpawn or { x = 1326.78, y = 1189.36, z = 107.76, w = 271.83 }
    local cfg         = Config.Truck
    local leaveSpeed  = cfg.speedLeaving or cfg.speed or 16.0
    local style       = cfg.driveStyle or 675

    FreezeEntityPosition(vehicle, false)
    SetVehicleDoorsLocked(vehicle, 1)
    if DoesEntityExist(driver) then
        FreezeEntityPosition(driver, false)
        SetBlockingOfNonTemporaryEvents(driver, true)
        exports.ox_target:removeLocalEntity(driver)
    end
    TaskEnterVehicle(driver, vehicle, 10000, -1, 1.0, 1, 0)

    CreateThread(function()
        local enterDeadline = GetGameTimer() + 10000
        while DoesEntityExist(driver) and DoesEntityExist(vehicle)
            and not IsPedInVehicle(driver, vehicle, false)
            and GetGameTimer() < enterDeadline do
            Wait(250)
        end

        if DoesEntityExist(driver) and DoesEntityExist(vehicle) then
            SetDriveTaskDrivingStyle(driver, style)
            SetDriveTaskCruiseSpeed(driver, leaveSpeed)
            TaskVehicleDriveToCoordLongrange(driver, vehicle,
                returnPoint.x, returnPoint.y, returnPoint.z,
                leaveSpeed, style, 20.0)
        end

        local arriveDeadline = GetGameTimer() + (cfg.despawnDelay or 30000)
        while DoesEntityExist(vehicle) and GetGameTimer() < arriveDeadline do
            local coords = GetEntityCoords(vehicle)
            if #(coords - vec3(returnPoint.x, returnPoint.y, returnPoint.z)) <= 20.0 then
                break
            end
            Wait(1000)
        end

        cleanScene()
    end)
end

local function getNearbyRoadSpawn(destination, distance)
    local desired = vec3(destination.x, destination.y, destination.z)
    local found, outPos, outHeading = GetClosestVehicleNodeWithHeading(desired.x, desired.y, desired.z, 1, distance or 60.0, 0)
    if found then
        return { x = outPos.x, y = outPos.y, z = outPos.z, w = outHeading }
    end
    return { x = desired.x, y = desired.y, z = desired.z, w = 0.0 }
end

local function stopTruckAtDestination(vehicle, destination)
    local z = resolveSpawnZ(destination.x, destination.y, destination.z or 0.0)
    SetEntityCoordsNoOffset(vehicle, destination.x, destination.y, z, false, false, false)
    SetVehicleOnGroundProperly(vehicle)
    SetEntityHeading(vehicle, destination.w or GetEntityHeading(vehicle))
    SetVehicleForwardSpeed(vehicle, 0.0)
    FreezeEntityPosition(vehicle, true)
end

local function syncStateFromResult(result)
    if not result then return end
    for _, animalId in ipairs(result.soldIds or {}) do
        TriggerEvent('rodz-fazenda:client:markAnimalLoaded', animalId)
    end
    if result.snapshots then
        TriggerEvent('rodz-fazenda:client:reloadAnimals', TruckSaleState.farmId)
    end
end

local function cancelSaleWithDriver()
    if not activeScene then return end

    local result = lib.callback.await('rodz-fazenda:server:cancelTruck', false,
        activeScene.farmId, activeScene.eventId, true)

    if not result or not result.ok then
        notify(result and result.msg or 'Nao foi possivel cancelar a venda.', 'error')
        return
    end

    notify(result.msg or 'Venda cancelada.', 'inform')
    cleanScene()
end

local function finalizeTruckSale()
    if not activeScene then return end

    local result = lib.callback.await('rodz-fazenda:server:finalizeTruck', false, activeScene.farmId, activeScene.eventId)
    if result and result.ok then
        local singular, plural = getTruckAnimalLabel()
        local animalName = (result.sold or 0) == 1 and singular or plural
        notify(result.msg or ('Vendidos %d %s!'):format(result.sold or 0, animalName), 'success')
        syncStateFromResult(result)
        driveAway(activeScene.vehicle, activeScene.driver)
    else
        notify(result and result.msg or 'Falha na finalizacao.', 'error')
    end
end

local function registerDriverTargets(driver)
    local _, plural = getTruckAnimalLabel()

    exports.ox_target:addLocalEntity(driver, {
        {
            name = 'rfz_driver_take_cows',
            icon = 'truck-ramp-box',
            label = ('Pode levar os %s'):format(plural),
            distance = 2.5,
            canInteract = function()
                return TruckSaleState.active and TruckSaleState.arrived
            end,
            onSelect = function()
                finalizeTruckSale()
            end,
        },
        {
            name = 'rfz_driver_cancel_sale',
            icon = 'ban',
            label = ('Cancelar venda ($%d)'):format(Config.Truck.cancelFee or 1500),
            distance = 2.5,
            canInteract = function()
                return TruckSaleState.active and TruckSaleState.arrived
            end,
            onSelect = function()
                cancelSaleWithDriver()
            end,
        },
    })
end

local function makeDriverExitVehicle(driver, vehicle)
    if not DoesEntityExist(driver) or not DoesEntityExist(vehicle) then return end

    ClearPedTasks(driver)
    FreezeEntityPosition(vehicle, false)
    SetVehicleDoorsLocked(vehicle, 1)
    TaskLeaveVehicle(driver, vehicle, 0)

    CreateThread(function()
        local timeout = GetGameTimer() + 7000
        while DoesEntityExist(driver) and IsPedInAnyVehicle(driver, false) and GetGameTimer() < timeout do
            Wait(100)
        end

        if DoesEntityExist(driver) and IsPedInAnyVehicle(driver, false) then
            ClearPedTasksImmediately(driver)
            TaskLeaveVehicle(driver, vehicle, 16)
            Wait(500)
        end

        if DoesEntityExist(driver) and IsPedInAnyVehicle(driver, false) then
            TaskWarpPedOutOfVehicle(driver, vehicle)
            Wait(100)
        end

        if not DoesEntityExist(driver) or not activeScene then
            return
        end

        local baseCoords = GetEntityCoords(vehicle)
        local sideOffset = GetOffsetFromEntityInWorldCoords(vehicle, -2.5, -4.0, 0.0)
        if IsPedInAnyVehicle(driver, false) then
            SetEntityCoordsNoOffset(driver, sideOffset.x, sideOffset.y, baseCoords.z, false, false, false)
        end
        FreezeEntityPosition(vehicle, true)
        SetEntityHeading(driver, GetEntityHeading(vehicle) + 90.0)
        FreezeEntityPosition(driver, false)
        SetBlockingOfNonTemporaryEvents(driver, true)
        TaskStartScenarioInPlace(driver, 'WORLD_HUMAN_CLIPBOARD', 0, true)
        registerDriverTargets(driver)
    end)
end

AddEventHandler('rodz-fazenda:client:startTruck', function(res)
    if activeScene then
        notify('Ja existe um caminhao em andamento.', 'error')
        return
    end

    local dest = res.destination
    local cfg = res.truck or Config.Truck
    local spawn = Config.TruckSpawn or getNearbyRoadSpawn(dest, cfg.spawnDistance or 60.0)
    local spawnZ = resolveSpawnZ(spawn.x, spawn.y, spawn.z or 0.0)

    local truckHash, truckModelName, usedFallbackVehicle = resolveVehicleModel(cfg)
    local driverHash = joaat(cfg.driver or 's_m_m_trucker_01')
    lib.requestModel(truckHash, 10000)
    lib.requestModel(driverHash, 10000)

    if usedFallbackVehicle then
        notify(('Modelo %s indisponivel, usando %s.'):format(cfg.vehicle or 'desconhecido', truckModelName), 'inform')
    end

    local vehicle = CreateVehicle(truckHash, spawn.x, spawn.y, spawnZ, spawn.w or 0.0, true, true)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        notify('Falha ao spawnar o caminhao boiadeiro.', 'error')
        return
    end

    local driver = CreatePedInsideVehicle(vehicle, 4, driverHash, -1, true, true)
    if not driver or driver == 0 or not DoesEntityExist(driver) then
        DeleteEntity(vehicle)
        notify('Falha ao spawnar o motorista do caminhao.', 'error')
        return
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetEntityAsMissionEntity(driver, true, true)
    SetEntityCoordsNoOffset(vehicle, spawn.x, spawn.y, spawnZ, false, false, false)
    SetEntityHeading(vehicle, spawn.w or 0.0)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleDoorsLocked(vehicle, 2)
    SetBlockingOfNonTemporaryEvents(driver, true)
    SetEntityInvincible(driver, true)
    SetDriverAbility(driver, 0.85)
    SetDriverAggressiveness(driver, 0.0)
    SetPedKeepTask(driver, true)

    activeScene = {
        vehicle = vehicle,
        driver = driver,
        farmId = res.farmId,
        eventId = res.eventId,
        blip = createTruckBlip(spawn),
    }

    TruckSaleState.active = true
    TruckSaleState.arrived = false
    TruckSaleState.farmId = res.farmId
    TruckSaleState.eventId = res.eventId
    TruckSaleState.animalType = res.animalType or 'cow'
    TruckSaleState.loadedAnimals = {}
    TruckSaleState.loadedCount = 0
    TruckSaleState.maxLoad = res.maxLoad or 10

    startTruckBlipTracker(vehicle)

    local _, plural = getTruckAnimalLabel()
    notify(('Caminhao boiadeiro a caminho. Limite desta viagem: %d %s.'):format(TruckSaleState.maxLoad, plural), 'inform')

    local arriveStyle = cfg.driveStyle or 675
    local arriveSpeed = cfg.speed or 16.0
    TaskVehicleDriveToCoordLongrange(driver, vehicle,
        dest.x, dest.y, dest.z,
        arriveSpeed, arriveStyle,
        math.max(1.5, (cfg.arrivalDistance or 4.0) * 0.5))
    SetDriveTaskDrivingStyle(driver, arriveStyle)
    SetDriveTaskCruiseSpeed(driver, arriveSpeed)

    CreateThread(function()
        local timeout = GetGameTimer() + (cfg.arrivalTimeout or 120000)
        local arrived = false

        while activeScene and GetGameTimer() < timeout do
            local vehPos = GetEntityCoords(vehicle)
            local planarDist = #(vec2(vehPos.x, vehPos.y) - vec2(dest.x, dest.y))
            if planarDist <= (cfg.arrivalDistance or 4.0) then
                arrived = true
                break
            end
            Wait(1000)
        end

        if not activeScene then return end
        if not arrived then
            notify('O caminhao nao conseguiu chegar a fazenda.', 'error')
            cleanScene()
            return
        end

        stopTruckAtDestination(vehicle, dest)
        removeTruckBlip()
        TruckSaleState.arrived = true
        makeDriverExitVehicle(driver, vehicle)
        notify('O caminhão boiadeiro chegou', 'success')
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    cleanScene()
end)
