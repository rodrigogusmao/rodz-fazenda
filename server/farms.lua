-- ─── Fazendas — CRUD e sincronização ─────────────────────────────────────────

Farms = {}  -- tabela global em memória, sincronizada com todos os clientes

-- ─── Helpers internos ─────────────────────────────────────────────────────────

local function syncAll(reason)
    Dbg('farms', 'syncAll reason=' .. (reason or '?'))
    TriggerClientEvent('rodz-fazenda:client:syncFarms', -1, Farms)
end

local function syncPlayer(src, reason)
    Dbg('farms', 'syncPlayer src=' .. src .. ' reason=' .. (reason or '?'))
    TriggerClientEvent('rodz-fazenda:client:syncFarms', src, Farms)
end

local function uniqueFarmId()
    local id
    local attempts = 0
    repeat
        id       = 'FARM_' .. RandId(6)
        attempts = attempts + 1
    until not Farms[id] or attempts > 30
    return (not Farms[id]) and id or nil
end

local function uniqueCorrId()
    return 'COR_' .. RandId(6)
end

local function findCorral(farmId, corrId)
    local farm = Farms[farmId]
    if not farm then return nil, nil end

    for index, corral in ipairs(farm.corrals or {}) do
        if corral.id == corrId then
            return corral, index
        end
    end

    return nil, nil
end

local function updateCorralSupplyStock(farmId, corrId, supplyType, delta)
    local corral = findCorral(farmId, corrId)
    if not corral then return nil end

    local stockKey = supplyType == 'water' and 'water_stock' or 'feed_stock'
    local current = tonumber(corral[stockKey]) or 0
    local nextValue = math.max(0, current + math.floor(tonumber(delta) or 0))

    corral[stockKey] = nextValue
    MySQL.update.await(('UPDATE `rfz_corrals` SET `%s` = ? WHERE `id` = ?'):format(stockKey), {
        nextValue,
        corrId,
    })

    return nextValue, corral
end

local function getCorralSupplyStashId(farmId, corrId, supplyType)
    return ('rfz_%s_%s_%s'):format(farmId, corrId, supplyType)
end

local function buildFeedItemAliases()
    local aliases = {}
    local seen = {}
    local function push(name)
        if type(name) ~= 'string' or name == '' or seen[name] then
            return
        end
        seen[name] = true
        aliases[#aliases + 1] = name
    end

    push(Config.Items and Config.Items.feed)
    push('racao')
    push('racao_animal')

    return aliases
end

local FEED_ITEM_ALIASES = buildFeedItemAliases()

local function syncCorralSupplyStock(farmId, corrId, supplyType)
    local corral = findCorral(farmId, corrId)
    if not corral then return 0 end

    local stockKey = supplyType == 'water' and 'water_stock' or 'feed_stock'
    local stashId = getCorralSupplyStashId(farmId, corrId, supplyType)
    local count = 0

    if GetResourceState('ox_inventory') == 'started' then
        if supplyType == 'feed' then
            for i = 1, #FEED_ITEM_ALIASES do
                local ok, result = pcall(function()
                    return exports.ox_inventory:GetItemCount(stashId, FEED_ITEM_ALIASES[i])
                end)
                if ok then
                    count = count + (tonumber(result) or 0)
                end
            end
        else
            local ok, result = pcall(function()
                return exports.ox_inventory:GetItemCount(stashId, Config.Items.water)
            end)
            if ok then
                count = tonumber(result) or 0
            end
        end
    end

    corral[stockKey] = count
    MySQL.update.await(('UPDATE `rfz_corrals` SET `%s` = ? WHERE `id` = ?'):format(stockKey), {
        count,
        corrId,
    })

    return count, corral
end

-- Retorna "Curral de Vacas N" / "Curral de Porcos N" com base na posição
-- do curral no array da fazenda (apenas currais do mesmo tipo contam).
local function corralLabel(farmId, corrId, corrType)
    local farm = Farms[farmId]
    if not farm then return corrId end
    local idx = 0
    for _, c in ipairs(farm.corrals or {}) do
        if c.type == corrType then idx = idx + 1 end
        if c.id == corrId then break end
    end
    local typeName = corrType == 'cow' and 'Vacas' or 'Porcos'
    return ('Curral de %s %d'):format(typeName, idx)
end

exports('CorralLabel', function(farmId, corrId, corrType)
    return corralLabel(farmId, corrId, corrType)
end)

local function registerCorralSupplyStashes(farmId, corral)
    if GetResourceState('ox_inventory') ~= 'started' or not corral then return end
    local supplyCfg = Config.CorralSupply or {}
    local feedMaxWeight  = math.max(1000, math.floor((tonumber(supplyCfg.feedCapacityKg)       or 1000) * 1000))
    local waterMaxWeight = math.max(1000, math.floor((tonumber(supplyCfg.waterCapacityLiters)  or 1000) * 1000))
    local stashSlots = 20
    local label = corralLabel(farmId, corral.id, corral.type)

    exports.ox_inventory:RegisterStash(
        getCorralSupplyStashId(farmId, corral.id, 'feed'),
        ('Comedouro — %s'):format(label),
        stashSlots,
        feedMaxWeight,
        nil,
        nil,
        corral.feed_zone and vec3(corral.feed_zone.x, corral.feed_zone.y, corral.feed_zone.z) or nil
    )

    exports.ox_inventory:RegisterStash(
        getCorralSupplyStashId(farmId, corral.id, 'water'),
        ('Bebedouro — %s'):format(label),
        stashSlots,
        waterMaxWeight,
        nil,
        nil,
        corral.water_zone and vec3(corral.water_zone.x, corral.water_zone.y, corral.water_zone.z) or nil
    )
end

-- ─── Carga inicial ────────────────────────────────────────────────────────────

local function loadFarms()
    Farms = {}

    local rows = MySQL.query.await('SELECT * FROM `rfz_farms`')
    for _, row in ipairs(rows or {}) do
        Farms[row.id] = {
            id               = row.id,
            name             = row.name,
            area             = json.decode(row.area)        or {},
            npc_coords       = json.decode(row.npc_coords)  or {},
            truck_point      = json.decode(row.truck_point) or {},
            created_by       = row.created_by,
            price            = tonumber(row.price) or 0,
            owner_citizenid  = row.owner_citizenid or nil,
            sale_price       = tonumber(row.sale_price) or nil,
            corrals          = {},
            employees        = {},
        }
    end

    local corrals = MySQL.query.await('SELECT * FROM `rfz_corrals`')
    for _, row in ipairs(corrals or {}) do
        local farm = Farms[row.farm_id]
        if farm then
            farm.corrals[#farm.corrals + 1] = {
                id           = row.id,
                farm_id      = row.farm_id,
                type         = row.type,
                area         = json.decode(row.area)         or {},
                spawn_points = json.decode(row.spawn_points) or {},
                feed_zone    = row.feed_zone and json.decode(row.feed_zone) or nil,
                water_zone   = row.water_zone and json.decode(row.water_zone) or nil,
                feed_stock   = tonumber(row.feed_stock) or 0,
                water_stock  = tonumber(row.water_stock) or 0,
            }
            registerCorralSupplyStashes(row.farm_id, farm.corrals[#farm.corrals])
        end
    end

    local employees = MySQL.query.await('SELECT * FROM `rfz_employees`')
    for _, row in ipairs(employees or {}) do
        local farm = Farms[row.farm_id]
        if farm then
            farm.employees[#farm.employees + 1] = {
                id        = row.id,
                citizenid = row.citizenid,
                name      = row.name or row.citizenid,
                role      = row.role or 'ajudante',
                salary    = tonumber(row.salary) or 0,
                hired_at  = tonumber(row.hired_at) or 0,
            }
        end
    end

    local total = 0
    for _ in pairs(Farms) do total = total + 1 end
    Dbg('farms', 'loadFarms total=' .. total)
end

-- ─── Eventos de rede ──────────────────────────────────────────────────────────

local function createFarmInternal(src, data)
    if not IsAdmin(src) then
        return { ok = false, msg = 'Sem permissao para criar fazendas.' }
    end

    if not data or not data.name or not data.area or not data.npc_coords or not data.truck_point then
        return { ok = false, msg = 'Dados incompletos para criar fazenda.' }
    end

    local farmId  = uniqueFarmId()
    if not farmId then
        return { ok = false, msg = 'Nao foi possivel gerar um ID unico para a fazenda. Tente novamente.' }
    end
    local citizen = GetCitizenId(src) or 'unknown'

    local price = math.max(0, math.floor(tonumber(data.price) or 0))

    MySQL.insert.await(
        'INSERT INTO `rfz_farms` (`id`,`name`,`area`,`npc_coords`,`truck_point`,`created_by`,`price`) VALUES (?,?,?,?,?,?,?)',
        {
            farmId,
            data.name,
            json.encode(data.area),
            json.encode(data.npc_coords),
            json.encode(data.truck_point),
            citizen,
            price,
        }
    )
    MySQL.insert.await(
        'INSERT INTO `rfz_inventory` (`farm_id`) VALUES (?)',
        { farmId }
    )

    Farms[farmId] = {
        id              = farmId,
        name            = data.name,
        area            = data.area,
        npc_coords      = data.npc_coords,
        truck_point     = data.truck_point,
        created_by      = citizen,
        price           = price,
        owner_citizenid = nil,
        corrals         = {},
    }

    syncAll('createFarm')
    Notify(src, ('Fazenda "%s" criada! ID: %s'):format(data.name, farmId), 'success')
    TriggerEvent('rodz-fazenda:server:rebuildAnimals')

    return {
        ok = true,
        farmId = farmId,
        msg = ('Fazenda "%s" criada! ID: %s'):format(data.name, farmId),
    }
end

lib.callback.register('rodz-fazenda:server:createFarm', function(src, data)
    return createFarmInternal(src, data)
end)

-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent('rodz-fazenda:server:deleteFarm', function(farmId)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissão.', 'error')
        return
    end
    if not Farms[farmId] then return end

    -- 1. Purga DB e memória de animais/currais/inventário antes de remover a fazenda
    TriggerEvent('rodz-fazenda:server:purgeFarmAnimals', farmId)

    -- 2. Remove a fazenda do DB e da memória
    MySQL.query.await('DELETE FROM `rfz_farms` WHERE `id` = ?', { farmId })
    Farms[farmId] = nil

    -- 3. Força limpeza imediata em todos os clientes (sem depender do loadAll)
    TriggerClientEvent('rodz-fazenda:client:cleanupFarm', -1, farmId)

    -- 4. Sincroniza a lista de fazendas (dispara loadAll nos clientes)
    syncAll('deleteFarm')
    Notify(src, 'Fazenda deletada.', 'success')
    TriggerEvent('rodz-fazenda:server:rebuildAnimals')
end)

-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent('rodz-fazenda:server:createCorral', function(farmId, data)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissão.', 'error')
        return
    end

    local farm = Farms[farmId]
    if not farm then
        Notify(src, 'Fazenda não encontrada.', 'error')
        return
    end
    if #farm.corrals >= Config.MaxCorrals then
        Notify(src, 'Máximo de ' .. Config.MaxCorrals .. ' currais por fazenda.', 'error')
        return
    end
    if not data or not data.type or not data.area or not data.spawn_points then
        Notify(src, 'Dados do curral incompletos.', 'error')
        return
    end

    local corrId = uniqueCorrId()

    MySQL.insert.await(
        'INSERT INTO `rfz_corrals` (`id`,`farm_id`,`type`,`area`,`spawn_points`,`feed_zone`,`water_zone`,`feed_stock`,`water_stock`) VALUES (?,?,?,?,?,?,?,?,?)',
        {
            corrId,
            farmId,
            data.type,
            json.encode(data.area),
            json.encode(data.spawn_points),
            data.feed_zone and json.encode(data.feed_zone) or nil,
            data.water_zone and json.encode(data.water_zone) or nil,
            0,
            0,
        }
    )

    local corral = {
        id           = corrId,
        farm_id      = farmId,
        type         = data.type,
        area         = data.area,
        spawn_points = data.spawn_points,
        feed_zone    = data.feed_zone,
        water_zone   = data.water_zone,
        feed_stock   = 0,
        water_stock  = 0,
    }
    farm.corrals[#farm.corrals + 1] = corral
    registerCorralSupplyStashes(farmId, corral)

    syncAll('createCorral')
    Notify(src, ('Curral criado! ID: %s | Vagas: %d'):format(corrId, #data.spawn_points), 'success')
    TriggerEvent('rodz-fazenda:server:rebuildAnimals')
end)

RegisterNetEvent('rodz-fazenda:server:updateCorralFeedZone', function(farmId, corrId, zoneData)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissao.', 'error')
        return
    end

    local corral = findCorral(farmId, corrId)
    if not corral then
        Notify(src, 'Curral nao encontrado.', 'error')
        return
    end
    if not zoneData or not zoneData.x then
        Notify(src, 'Zona do comedouro invalida.', 'error')
        return
    end

    MySQL.update.await('UPDATE `rfz_corrals` SET `feed_zone` = ? WHERE `id` = ?', {
        json.encode(zoneData),
        corrId,
    })

    corral.feed_zone = zoneData
    registerCorralSupplyStashes(farmId, corral)
    syncAll('updateCorralFeedZone')
    Notify(src, 'Comedouro atualizado.', 'success')
end)

RegisterNetEvent('rodz-fazenda:server:updateCorralWaterZone', function(farmId, corrId, zoneData)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissao.', 'error')
        return
    end

    local corral = findCorral(farmId, corrId)
    if not corral then
        Notify(src, 'Curral nao encontrado.', 'error')
        return
    end
    if not zoneData or not zoneData.x then
        Notify(src, 'Zona do bebedouro invalida.', 'error')
        return
    end

    MySQL.update.await('UPDATE `rfz_corrals` SET `water_zone` = ? WHERE `id` = ?', {
        json.encode(zoneData),
        corrId,
    })

    corral.water_zone = zoneData
    registerCorralSupplyStashes(farmId, corral)
    syncAll('updateCorralWaterZone')
    Notify(src, 'Bebedouro atualizado.', 'success')
end)

-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent('rodz-fazenda:server:deleteCorral', function(farmId, corrId)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissão.', 'error')
        return
    end

    local farm = Farms[farmId]
    if not farm then return end

    MySQL.query.await('DELETE FROM `rfz_corrals` WHERE `id` = ?', { corrId })

    for i, c in ipairs(farm.corrals) do
        if c.id == corrId then
            table.remove(farm.corrals, i)
            break
        end
    end

    syncAll('deleteCorral')
    Notify(src, 'Curral deletado.', 'success')
    TriggerEvent('rodz-fazenda:server:rebuildAnimals')
end)

RegisterNetEvent('rodz-fazenda:server:updateTruckPoint', function(farmId, truckPoint)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissao.', 'error')
        return
    end

    local farm = Farms[farmId]
    if not farm then
        Notify(src, 'Fazenda nao encontrada.', 'error')
        return
    end
    if not truckPoint or not truckPoint.x then
        Notify(src, 'Ponto do caminhao invalido.', 'error')
        return
    end

    MySQL.update.await('UPDATE `rfz_farms` SET `truck_point` = ? WHERE `id` = ?', {
        json.encode(truckPoint),
        farmId,
    })

    farm.truck_point = truckPoint
    syncAll('updateTruckPoint')
    Notify(src, 'Ponto de parada do caminhao atualizado.', 'success')
end)

RegisterNetEvent('rodz-fazenda:server:updateFarmArea', function(farmId, area)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissao.', 'error')
        return
    end

    local farm = Farms[farmId]
    if not farm then
        Notify(src, 'Fazenda nao encontrada.', 'error')
        return
    end
    if not area or not area.points or #area.points < 3 then
        Notify(src, 'Area invalida (minimo 3 pontos).', 'error')
        return
    end

    MySQL.update.await('UPDATE `rfz_farms` SET `area` = ? WHERE `id` = ?', {
        json.encode(area),
        farmId,
    })

    farm.area = area
    syncAll('updateFarmArea')
    Notify(src, 'Area da fazenda atualizada.', 'success')
end)

RegisterNetEvent('rodz-fazenda:server:updateFarmNpc', function(farmId, coords)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissao.', 'error')
        return
    end

    local farm = Farms[farmId]
    if not farm then
        Notify(src, 'Fazenda nao encontrada.', 'error')
        return
    end
    if not coords or not coords.x then
        Notify(src, 'Coordenadas do NPC invalidas.', 'error')
        return
    end

    MySQL.update.await('UPDATE `rfz_farms` SET `npc_coords` = ? WHERE `id` = ?', {
        json.encode(coords),
        farmId,
    })

    farm.npc_coords = coords
    syncAll('updateFarmNpc')
    Notify(src, 'Posicao do NPC atualizada.', 'success')
end)

RegisterNetEvent('rodz-fazenda:server:renameFarm', function(farmId, newName)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissao.', 'error')
        return
    end

    local farm = Farms[farmId]
    if not farm then
        Notify(src, 'Fazenda nao encontrada.', 'error')
        return
    end
    if not newName or newName == '' then
        Notify(src, 'Nome invalido.', 'error')
        return
    end

    MySQL.update.await('UPDATE `rfz_farms` SET `name` = ? WHERE `id` = ?', {
        newName,
        farmId,
    })

    farm.name = newName
    syncAll('renameFarm')
    Notify(src, ('Fazenda renomeada para "%s".'):format(newName), 'success')
end)

RegisterNetEvent('rodz-fazenda:server:updateCorralArea', function(farmId, corrId, area)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissao.', 'error')
        return
    end

    local corral = findCorral(farmId, corrId)
    if not corral then
        Notify(src, 'Curral nao encontrado.', 'error')
        return
    end
    if not area or not area.points or #area.points < 3 then
        Notify(src, 'Area do curral invalida.', 'error')
        return
    end

    MySQL.update.await('UPDATE `rfz_corrals` SET `area` = ? WHERE `id` = ?', {
        json.encode(area),
        corrId,
    })

    corral.area = area
    syncAll('updateCorralArea')
    Notify(src, 'Tamanho do curral atualizado.', 'success')
    TriggerEvent('rodz-fazenda:server:rebuildAnimals')
end)

RegisterNetEvent('rodz-fazenda:server:updateCorralSpawnPoints', function(farmId, corrId, spawnPoints)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissao.', 'error')
        return
    end

    local corral = findCorral(farmId, corrId)
    if not corral then
        Notify(src, 'Curral nao encontrado.', 'error')
        return
    end
    if not spawnPoints or #spawnPoints < 1 then
        Notify(src, 'Defina pelo menos 1 vaga para o curral.', 'error')
        return
    end

    MySQL.update.await('UPDATE `rfz_corrals` SET `spawn_points` = ? WHERE `id` = ?', {
        json.encode(spawnPoints),
        corrId,
    })

    corral.spawn_points = spawnPoints
    syncAll('updateCorralSpawnPoints')
    Notify(src, ('Capacidade do curral atualizada para %d animal(is).'):format(#spawnPoints), 'success')
    TriggerEvent('rodz-fazenda:server:rebuildAnimals')
end)

-- ─── Sincronização ────────────────────────────────────────────────────────────

-- ─── Propriedade ──────────────────────────────────────────────────────────────

lib.callback.register('rodz-fazenda:server:buyFarm', function(src, farmId)
    local farm = Farms[farmId]
    if not farm then
        return { ok = false, msg = 'Fazenda não encontrada.' }
    end

    local cid = GetCitizenId(src)

    -- Compra de fazenda sem dono (do sistema)
    if not farm.owner_citizenid then
        local price = tonumber(farm.price) or 0
        if price > 0 and not RemoveMoney(src, price, 'rodz-fazenda-compra') then
            return { ok = false, msg = ('Você precisa de $%s para comprar esta fazenda.'):format(price) }
        end

        MySQL.update.await('UPDATE `rfz_farms` SET `owner_citizenid` = ? WHERE `id` = ?', { cid, farmId })
        farm.owner_citizenid = cid
        syncAll('buyFarm')
        return { ok = true, msg = ('Você é o novo dono da fazenda "%s"!'):format(farm.name or farmId) }
    end

    -- Compra de fazenda listada pelo dono (player-to-player)
    if not farm.sale_price then
        return { ok = false, msg = 'Esta fazenda não está à venda.' }
    end
    if cid == farm.owner_citizenid then
        return { ok = false, msg = 'Você já é o dono desta fazenda.' }
    end

    local salePrice = tonumber(farm.sale_price)
    if salePrice and salePrice > 0 and not RemoveMoney(src, salePrice, 'rodz-fazenda-compra-dono') then
        return { ok = false, msg = ('Você precisa de $%s para comprar esta fazenda.'):format(salePrice) }
    end

    -- Pagar o dono anterior
    if salePrice and salePrice > 0 then
        local prevOwnerSrc = GetSourceByCitizenId(farm.owner_citizenid)
        if prevOwnerSrc then
            AddMoney(prevOwnerSrc, salePrice, 'rodz-fazenda-venda-fazenda')
            Notify(prevOwnerSrc, ('Sua fazenda "%s" foi comprada por $%s!'):format(farm.name or farmId, salePrice), 'success')
        else
            return { ok = false, msg = 'O dono precisa estar online para receber o pagamento.' }
        end
    end

    local prevOwner = farm.owner_citizenid
    MySQL.update.await('UPDATE `rfz_farms` SET `owner_citizenid` = ?, `sale_price` = NULL WHERE `id` = ?', { cid, farmId })
    farm.owner_citizenid = cid
    farm.sale_price      = nil
    syncAll('buyFarm')

    return { ok = true, msg = ('Você é o novo dono da fazenda "%s"! (comprado de %s)'):format(farm.name or farmId, prevOwner) }
end)

RegisterNetEvent('rodz-fazenda:server:updateFarmPrice', function(farmId, price)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissão.', 'error')
        return
    end
    local farm = Farms[farmId]
    if not farm then return end

    price = math.max(0, math.floor(tonumber(price) or 0))
    MySQL.update.await('UPDATE `rfz_farms` SET `price` = ? WHERE `id` = ?', { price, farmId })
    farm.price = price
    syncAll('updateFarmPrice')
    Notify(src, ('Preço atualizado para $%s.'):format(price), 'success')
end)

RegisterNetEvent('rodz-fazenda:server:removeFarmOwner', function(farmId)
    local src = source
    if not IsAdmin(src) then
        Notify(src, 'Sem permissão.', 'error')
        return
    end
    local farm = Farms[farmId]
    if not farm then return end

    MySQL.update.await('UPDATE `rfz_farms` SET `owner_citizenid` = NULL WHERE `id` = ?', { farmId })
    farm.owner_citizenid = nil
    syncAll('removeFarmOwner')
    Notify(src, 'Dono da fazenda removido.', 'success')
end)

lib.callback.register('rodz-fazenda:server:listFarmForSale', function(src, farmId, price)
    if not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Você não é o dono desta fazenda.' }
    end

    local farm = Farms[farmId]
    if not farm then return { ok = false, msg = 'Fazenda não encontrada.' } end

    price = math.floor(math.max(1, tonumber(price) or 0))
    if price <= 0 then
        return { ok = false, msg = 'Preço inválido.' }
    end

    farm.sale_price = price
    MySQL.update('UPDATE `rfz_farms` SET `sale_price` = ? WHERE `id` = ?', { price, farmId })
    syncAll('listFarmForSale')

    return { ok = true, msg = ('Fazenda listada por $%s. Aguardando comprador.'):format(price) }
end)

lib.callback.register('rodz-fazenda:server:cancelFarmListing', function(src, farmId)
    if not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Você não é o dono desta fazenda.' }
    end

    local farm = Farms[farmId]
    if not farm then return { ok = false, msg = 'Fazenda não encontrada.' } end

    farm.sale_price = nil
    MySQL.update('UPDATE `rfz_farms` SET `sale_price` = NULL WHERE `id` = ?', { farmId })
    syncAll('cancelFarmListing')

    return { ok = true, msg = 'Venda cancelada. A fazenda foi removida do mercado.' }
end)

RegisterNetEvent('rodz-fazenda:server:requestSync', function()
    syncPlayer(source, 'requestSync')
end)

lib.callback.register('rodz-fazenda:server:getCorralSupplyStatus', function(_, farmId, corrId)
    local corral = findCorral(farmId, corrId)
    if not corral then
        return { ok = false, msg = 'Curral nao encontrado.' }
    end

    local feed = syncCorralSupplyStock(farmId, corrId, 'feed')
    local water = syncCorralSupplyStock(farmId, corrId, 'water')

    return {
        ok = true,
        feed = tonumber(feed) or 0,
        water = tonumber(water) or 0,
    }
end)

lib.callback.register('rodz-fazenda:server:getCorralSupplyStash', function(src, farmId, corrId, supplyType)
    if not IsAdmin(src) and not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Sem permissao.' }
    end

    local corral = findCorral(farmId, corrId)
    if not corral then
        return { ok = false, msg = 'Curral nao encontrado.' }
    end

    if supplyType ~= 'feed' and supplyType ~= 'water' then
        return { ok = false, msg = 'Tipo de abastecimento invalido.' }
    end

    registerCorralSupplyStashes(farmId, corral)

    return {
        ok = true,
        id = getCorralSupplyStashId(farmId, corrId, supplyType),
        label = supplyType == 'water' and ('Bebedouro %s'):format(corrId) or ('Comedouro %s'):format(corrId),
    }
end)

-- ─── Funcionários ─────────────────────────────────────────────────────────────

local ValidRoles = { ajudante = true, vaqueiro = true, capataz = true, supervisor = true, gerente = true }

local function resolveTarget(target)
    local num = tonumber(target)
    if num then
        local cid  = GetCitizenId(num)
        local pl   = GetQPlayer(num)
        local ci   = pl and pl.PlayerData.charinfo or {}
        local name = ci.firstname and (ci.firstname .. ' ' .. (ci.lastname or '')) or tostring(target)
        return cid, name
    end
    -- citizenid string
    local cid = tostring(target):upper()
    local src2 = GetSourceByCitizenId(cid)
    if src2 then
        local pl = GetQPlayer(src2)
        local ci = pl and pl.PlayerData.charinfo or {}
        local name = ci.firstname and (ci.firstname .. ' ' .. (ci.lastname or '')) or cid
        return cid, name
    end
    -- offline — busca no banco
    local row = MySQL.single.await('SELECT `charinfo` FROM `players` WHERE `citizenid` = ?', { cid })
    if not row then return nil, nil end
    local ci = json.decode(row.charinfo) or {}
    local name = ci.firstname and (ci.firstname .. ' ' .. (ci.lastname or '')) or cid
    return cid, name
end

lib.callback.register('rodz-fazenda:server:hireEmployee', function(src, farmId, target, role, salary)
    if not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Você não é o dono desta fazenda.' }
    end
    local farm = Farms[farmId]
    if not farm then return { ok = false, msg = 'Fazenda não encontrada.' } end
    if #(farm.employees or {}) >= (Config.MaxEmployees or 10) then
        return { ok = false, msg = ('Limite de %d funcionários atingido.'):format(Config.MaxEmployees or 10) }
    end
    if not ValidRoles[role] then
        return { ok = false, msg = 'Cargo inválido.' }
    end

    local targetCid, targetName = resolveTarget(target)
    if not targetCid then
        return { ok = false, msg = 'Jogador não encontrado.' }
    end
    if targetCid == GetCitizenId(src) then
        return { ok = false, msg = 'Você não pode se contratar.' }
    end
    for _, emp in ipairs(farm.employees) do
        if emp.citizenid == targetCid then
            return { ok = false, msg = 'Este jogador já é funcionário desta fazenda.' }
        end
    end

    salary = math.floor(math.max(0, tonumber(salary) or 0))
    local hiredAt = Now()
    local empId = MySQL.insert.await(
        'INSERT INTO `rfz_employees` (`farm_id`,`citizenid`,`name`,`role`,`salary`,`hired_at`) VALUES (?,?,?,?,?,?)',
        { farmId, targetCid, targetName, role, salary, hiredAt }
    )
    if not empId then return { ok = false, msg = 'Erro ao salvar no banco.' } end

    local emp = { id = empId, citizenid = targetCid, name = targetName, role = role, salary = salary, hired_at = hiredAt }
    farm.employees[#farm.employees + 1] = emp
    syncAll('hireEmployee')

    local empSrc = GetSourceByCitizenId(targetCid)
    if empSrc then
        Notify(empSrc, ('Você foi contratado como %s na fazenda "%s".'):format(role, farm.name or farmId), 'success')
    end
    return { ok = true, msg = ('"%s" contratado como %s.'):format(targetName, role), employee = emp }
end)

lib.callback.register('rodz-fazenda:server:fireEmployee', function(src, farmId, employeeCid)
    if not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Você não é o dono desta fazenda.' }
    end
    local farm = Farms[farmId]
    if not farm then return { ok = false, msg = 'Fazenda não encontrada.' } end

    local empName = employeeCid
    local found   = false
    for i, emp in ipairs(farm.employees) do
        if emp.citizenid == employeeCid then
            empName = emp.name or employeeCid
            table.remove(farm.employees, i)
            found = true
            break
        end
    end
    if not found then return { ok = false, msg = 'Funcionário não encontrado.' } end

    MySQL.update('DELETE FROM `rfz_employees` WHERE `farm_id` = ? AND `citizenid` = ?', { farmId, employeeCid })
    syncAll('fireEmployee')

    local empSrc = GetSourceByCitizenId(employeeCid)
    if empSrc then
        Notify(empSrc, ('Você foi demitido da fazenda "%s".'):format(farm.name or farmId), 'error')
    end
    return { ok = true, msg = ('"%s" demitido.'):format(empName), citizenid = employeeCid }
end)

lib.callback.register('rodz-fazenda:server:updateEmployee', function(src, farmId, employeeCid, role, salary)
    if not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Você não é o dono desta fazenda.' }
    end
    local farm = Farms[farmId]
    if not farm then return { ok = false, msg = 'Fazenda não encontrada.' } end
    if role and not ValidRoles[role] then return { ok = false, msg = 'Cargo inválido.' } end

    local emp = nil
    for _, e in ipairs(farm.employees) do
        if e.citizenid == employeeCid then emp = e break end
    end
    if not emp then return { ok = false, msg = 'Funcionário não encontrado.' } end

    if role   then emp.role   = role   end
    if salary then emp.salary = math.floor(math.max(0, tonumber(salary) or 0)) end

    MySQL.update('UPDATE `rfz_employees` SET `role` = ?, `salary` = ? WHERE `farm_id` = ? AND `citizenid` = ?',
        { emp.role, emp.salary, farmId, employeeCid })
    syncAll('updateEmployee')
    return { ok = true, msg = 'Funcionário atualizado.', citizenid = employeeCid, role = emp.role, salary = emp.salary }
end)

-- ─── Timer de salários ────────────────────────────────────────────────────────

CreateThread(function()
    local intervalMs = (Config.SalaryIntervalMinutes or 60) * 60 * 1000
    Wait(intervalMs)
    while true do
        for farmId, farm in pairs(Farms or {}) do
            if farm.owner_citizenid and #(farm.employees or {}) > 0 then
                local ownerSrc = GetSourceByCitizenId(farm.owner_citizenid)
                for _, emp in ipairs(farm.employees) do
                    if emp.salary > 0 then
                        local paid = false
                        if ownerSrc then
                            paid = RemoveMoney(ownerSrc, emp.salary, 'rodz-fazenda-salario')
                            if not paid then
                                Notify(ownerSrc, ('Saldo insuficiente para pagar salário de %s ($%s).'):format(emp.name or emp.citizenid, emp.salary), 'error')
                            end
                        end
                        if paid then
                            local empSrc = GetSourceByCitizenId(emp.citizenid)
                            if empSrc then
                                AddMoney(empSrc, emp.salary, 'rodz-fazenda-salario')
                                Notify(empSrc, ('Salário recebido: $%s da fazenda "%s".'):format(emp.salary, farm.name or farmId), 'success')
                            end
                        end
                    end
                end
            end
        end
        Wait(intervalMs)
    end
end)

-- ─── Startup ──────────────────────────────────────────────────────────────────

AddEventHandler('rodz-fazenda:server:ready', function()
    loadFarms()
    syncAll('onResourceStart')
    TriggerEvent('rodz-fazenda:server:rebuildAnimals')
end)

-- ─── Exports ──────────────────────────────────────────────────────────────────

exports('GetFarms',     function() return Farms end)
exports('SyncAllFarms', function(reason) syncAll(reason) end)
exports('ChangeCorralSupplyStock', updateCorralSupplyStock)
exports('SyncCorralSupplyStock', syncCorralSupplyStock)
