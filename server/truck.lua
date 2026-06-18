local activeTrucks = {}   -- [farmId] = { source, eventId, createdAt, loadedAnimals, loadedOrder, loadedCount, maxLoad }
local truckCooldowns = {} -- [farmId] = timestamp da ultima entrega

local function isCooldownActive(farmId)
    local last = truckCooldowns[farmId] or 0
    return (Now() - last) < Config.Truck.cooldown
end

local function cooldownRemaining(farmId)
    local last = truckCooldowns[farmId] or 0
    return math.max(0, Config.Truck.cooldown - (Now() - last))
end

local function newEventId(src)
    return ('%s-%s-%s'):format(src, Now(), math.random(100000, 999999))
end

local function getAnimalLabel(animalType)
    if animalType == 'pig' then
        return 'porco', 'porcos'
    end

    return 'vaca', 'vacas'
end

local function getTruckRecordForSource(src, farmId, eventId)
    local record = activeTrucks[farmId]
    if not record then
        return nil, 'Nao existe um caminhao ativo para essa fazenda.'
    end
    if record.eventId ~= eventId or record.source ~= src then
        return nil, 'Evento de entrega invalido.'
    end
    return record
end

local function isAnimalSellable(farmId, animalType, animalId)
    local cfg = AnimalConfigs and AnimalConfigs[animalId]
    local state = AnimalStates and AnimalStates[animalId]
    local singular = getAnimalLabel(animalType)

    if not cfg or not state then
        return false, 'Animal nao encontrado.'
    end
    if cfg.farm_id ~= farmId or cfg.type ~= animalType then
        return false, ('Esse %s nao pertence a essa fazenda.'):format(singular)
    end
    if not state.active then
        return false, ('Esse %s nao esta disponivel para venda.'):format(singular)
    end
    if animalType ~= 'cow' and (state.health or 0) < 60 then
        return false, ('Esse %s nao esta em condicoes de venda.'):format(singular)
    end

    return true, nil, cfg, state
end

local function fetchAutoSellRows(farmId, animalType, limit)
    local rows = {}

    for animalId, cfg in pairs(AnimalConfigs or {}) do
        if cfg.farm_id == farmId and cfg.type == animalType then
            local ok, _, _, state = isAnimalSellable(farmId, animalType, animalId)
            if ok and state then
                rows[#rows + 1] = {
                    id = animalId,
                    born_at = state.born_at or 0,
                    health = state.health or 100,
                }
            end
        end
    end

    table.sort(rows, function(a, b)
        return (a.born_at or 0) < (b.born_at or 0)
    end)

    if limit and #rows > limit then
        local limited = {}
        for i = 1, limit do
            limited[i] = rows[i]
        end
        return limited
    end

    return rows
end

local function buildLoadedAnimalsFromAvailable(record, farmId)
    if (record.loadedCount or 0) > 0 then
        return
    end

    local rows = fetchAutoSellRows(farmId, record.animalType or 'cow', record.maxLoad or 0)
    for _, row in ipairs(rows) do
        local price, ageDays = GetAnimalSalePrice(record.animalType or 'cow', row.born_at)
        record.loadedAnimals[row.id] = {
            price = price,
            ageDays = ageDays,
        }
        record.loadedOrder[#record.loadedOrder + 1] = row.id
        record.loadedCount = (record.loadedCount or 0) + 1
    end
end

lib.callback.register('rodz-fazenda:server:requestTruck', function(src, farmId, animalType, requestedQty)
    local farm = Farms[farmId]
    animalType = animalType == 'pig' and 'pig' or 'cow'
    local singular, plural = getAnimalLabel(animalType)
    if not farm then
        return { ok = false, msg = 'Fazenda nao encontrada.' }
    end
    if not IsAdmin(src) and not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Você não é o dono desta fazenda.' }
    end
    if not farm.truck_point or not farm.truck_point.x then
        return { ok = false, msg = 'Ponto de entrega nao configurado nessa fazenda.' }
    end
    if activeTrucks[farmId] then
        return { ok = false, msg = 'Ja existe um caminhao em venda nessa fazenda. Aguarde terminar para chamar outro.' }
    end
    if isCooldownActive(farmId) then
        local mins = math.ceil(cooldownRemaining(farmId) / 60)
        return { ok = false, msg = ('Aguarde %d minuto(s) para chamar outro caminhao.'):format(mins) }
    end

    local sellable = 0
    for animalId, cfg in pairs(AnimalConfigs or {}) do
        if cfg.farm_id == farmId and cfg.type == animalType then
            local state = AnimalStates and AnimalStates[animalId]
            if state and state.active and (animalType == 'cow' or (state.health or 0) >= 60) then
                sellable = sellable + 1
            end
        end
    end

    if sellable <= 0 then
        return { ok = false, msg = ('Nenhum %s em condicoes de venda foi encontrado.'):format(singular) }
    end

    requestedQty = math.max(1, math.floor(tonumber(requestedQty) or 1))

    local eventId = newEventId(src)
    activeTrucks[farmId] = {
        source = src,
        eventId = eventId,
        createdAt = Now(),
        loadedAnimals = {},
        loadedOrder = {},
        loadedCount = 0,
        animalType = animalType,
        maxLoad = math.min(sellable, requestedQty),
    }

    return {
        ok = true,
        eventId = eventId,
        farmId = farmId,
        animalType = animalType,
        destination = farm.truck_point,
        truck = Config.Truck,
        available = sellable,
        animalLabel = singular,
        animalLabelPlural = plural,
        maxLoad = activeTrucks[farmId].maxLoad,
    }
end)

lib.callback.register('rodz-fazenda:server:cancelTruck', function(src, farmId, eventId, chargeFee)
    local record = activeTrucks[farmId]
    if not record then return { ok = true, msg = 'Caminhao cancelado.' } end
    if record.eventId ~= eventId or record.source ~= src then
        return { ok = false, msg = 'Evento de entrega invalido.' }
    end

    if chargeFee then
        local fee = Config.Truck.cancelFee or 1500
        if fee > 0 and not RemoveMoney(src, fee, 'rodz-fazenda-truck-cancel-fee') then
            return { ok = false, msg = ('Voce precisa de $%s para pagar o deslocamento do motorista.'):format(fee) }
        end
    end

    activeTrucks[farmId] = nil
    return {
        ok = true,
        fee = chargeFee and (Config.Truck.cancelFee or 1500) or 0,
        msg = chargeFee and ('Venda cancelada. Taxa de deslocamento: $%s.'):format(Config.Truck.cancelFee or 1500) or 'Venda cancelada.',
    }
end)

lib.callback.register('rodz-fazenda:server:loadTruckAnimal', function(src, farmId, eventId, animalId)
    local record, err = getTruckRecordForSource(src, farmId, eventId)
    if not record then
        return { ok = false, msg = err }
    end
    local singular, plural = getAnimalLabel(record.animalType or 'cow')

    if record.loadedCount >= (record.maxLoad or 10) then
        return { ok = false, msg = ('Esse caminhao suporta no maximo %d %s.'):format(record.maxLoad or 10, plural) }
    end

    if record.loadedAnimals[animalId] then
        return { ok = false, msg = ('Esse %s ja foi carregado nesse caminhao.'):format(singular) }
    end

    local ok, reason, _, state = isAnimalSellable(farmId, record.animalType or 'cow', animalId)
    if not ok then
        return { ok = false, msg = reason }
    end

    local price, ageDays = GetAnimalSalePrice(record.animalType or 'cow', state.born_at)
    record.loadedAnimals[animalId] = {
        price = price,
        ageDays = ageDays,
    }
    record.loadedOrder[#record.loadedOrder + 1] = animalId
    record.loadedCount = record.loadedCount + 1

    return {
        ok = true,
        msg = ('%s carregado no caminhao (%d/%d).'):format(singular:gsub('^%l', string.upper), record.loadedCount, record.maxLoad or 10),
        loadedCount = record.loadedCount,
        maxLoad = record.maxLoad or 10,
        price = price,
        ageDays = ageDays,
    }
end)

lib.callback.register('rodz-fazenda:server:finalizeTruck', function(src, farmId, eventId)
    local record, err = getTruckRecordForSource(src, farmId, eventId)
    if not record then
        return { ok = false, msg = err }
    end
    local singular, plural = getAnimalLabel(record.animalType or 'cow')

    local farm = Farms[farmId]
    if not farm then
        return { ok = false, msg = 'Fazenda nao encontrada.' }
    end

    local stop = farm.truck_point
    if stop and not WithinDistance(src, stop, Config.Security.saleDistance + 10) then
        return { ok = false, msg = 'Voce precisa estar no ponto de parada do caminhao.' }
    end

    buildLoadedAnimalsFromAvailable(record, farmId)

    if (record.loadedCount or 0) <= 0 then
        return { ok = false, msg = ('Nenhum %s em condicoes de venda foi encontrado para esse caminhao.'):format(singular) }
    end

    local sold = 0
    local payout = 0
    local failed = 0
    local soldIds = {}

    for _, animalId in ipairs(record.loadedOrder or {}) do
        local loadedInfo = record.loadedAnimals[animalId]
        local ok, _, _, state = isAnimalSellable(farmId, record.animalType or 'cow', animalId)
        if ok and loadedInfo then
            payout = payout + (loadedInfo.price or 0)
            sold = sold + 1
            state.active = false
            state.hunger = 100.0
            state.thirst = 100.0
            state.health = 100.0
            state.born_at = Now()
            state.last_fed = 0
            state.last_drank = 0
            state.last_milked = 0
            SaveAnimalState(animalId)
            soldIds[#soldIds + 1] = animalId
        else
            failed = failed + 1
        end
    end

    activeTrucks[farmId] = nil
    truckCooldowns[farmId] = Now()

    if sold == 0 then
        return { ok = false, msg = ('Nenhum %s carregado permaneceu valido para venda.'):format(singular) }
    end

    exports['rodz-fazenda']:ChangeFarmAnimalCount(farmId, record.animalType or 'cow', -sold)
    AddMoney(src, payout, 'rodz-fazenda-truck-sale')
    TriggerClientEvent('rodz-fazenda:client:reloadAnimals', -1, farmId)

    return {
        ok = true,
        msg = ('Voce recebeu $%s pela venda de %d %s.'):format(payout, sold, sold == 1 and singular or plural),
        sold = sold,
        soldIds = soldIds,
        payout = payout,
        failed = failed,
        snapshots = exports['rodz-fazenda']:AllSnapshots(),
    }
end)

CreateThread(function()
    while true do
        Wait(60000)
        local cutoff = Now() - (Config.Truck.arrivalTimeout / 1000 + 300)
        for farmId, record in pairs(activeTrucks) do
            if record.createdAt < cutoff then
                activeTrucks[farmId] = nil
            end
        end
    end
end)

exports('GetActiveTrucks', function() return activeTrucks end)
exports('GetTruckCooldowns', function() return truckCooldowns end)
