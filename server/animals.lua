-- ─── Animais — estado, persistência e ações ───────────────────────────────────

AnimalStates  = {}   -- [animalId] = { hunger, thirst, health, last_fed, ... }
AnimalConfigs = {}   -- [animalId] = { farm_id, corral_id, type, slot, cfg }
FarmAnimalInventory = {} -- [farmId] = { cows = number, pigs = number }

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
local COW_FEED_ITEM_QTY = math.max(1, math.floor(tonumber((Config.CowAutoFeed and Config.CowAutoFeed.itemQtyPerCycle) or 1) or 1))
local COW_FEED_HUNGER_GAIN = math.max(0.1, tonumber((Config.CowAutoFeed and Config.CowAutoFeed.hungerGainPercentPerCycle) or 5) or 5)
local COW_FEED_ITEM_KG = math.max(0.1, tonumber((Config.CowAutoFeed and Config.CowAutoFeed.itemKgUnit) or 0.5) or 0.5)
local PendingOwnerFeedNotifications = {} -- [farmId:corralId] = { farmId, corralId, consumptions, itemQty, remainingStock }

local function removeFeedFromStash(stashId, qty)
    if GetResourceState('ox_inventory') ~= 'started' then
        return false
    end

    for i = 1, #FEED_ITEM_ALIASES do
        local ok, removed = pcall(function()
            return exports.ox_inventory:RemoveItem(stashId, FEED_ITEM_ALIASES[i], qty)
        end)
        if ok and removed then
            return true
        end
    end

    return false
end

local function resolveCartelLeaderSources()
    local leaders = {}
    for _, src in ipairs(GetPlayers()) do
        local playerSrc = tonumber(src)
        if playerSrc and IsCartelBoss(playerSrc) then
            leaders[#leaders + 1] = playerSrc
        end
    end
    return leaders
end

local function queueFarmFeedConsumptionNotice(farmId, corralId, itemQty, remainingStock)
    if not farmId or not corralId then return end
    itemQty = math.max(0, math.floor(tonumber(itemQty) or 0))
    if itemQty <= 0 then return end

    local key = ('%s:%s'):format(farmId, corralId)
    local entry = PendingOwnerFeedNotifications[key]
    if not entry then
        entry = {
            farmId = farmId,
            corralId = corralId,
            consumptions = 0,
            itemQty = 0,
            remainingStock = 0,
        }
        PendingOwnerFeedNotifications[key] = entry
    end

    entry.consumptions = entry.consumptions + 1
    entry.itemQty = entry.itemQty + itemQty
    entry.remainingStock = math.max(0, math.floor(tonumber(remainingStock) or entry.remainingStock or 0))
end

local function flushFarmFeedConsumptionNotices()
    for key, entry in pairs(PendingOwnerFeedNotifications) do
        local leaders = resolveCartelLeaderSources()
        if #leaders > 0 then
            local farmId = entry.farmId
            local farmName = (Farms and Farms[farmId] and Farms[farmId].name) or farmId
            local consumedKg = entry.itemQty * COW_FEED_ITEM_KG
            local msg = ('As vacas da fazenda %s consumiram %.1fkg de ração no comedouro %s (%dx). Restante: %d saco(s).')
                :format(farmName, consumedKg, entry.corralId, entry.consumptions, entry.remainingStock)
            for i = 1, #leaders do
                Notify(leaders[i], msg, 'inform')
            end
        end

        PendingOwnerFeedNotifications[key] = nil
    end
end

local function getCorralBounds(area)
    local points = area and area.points
    if not points or #points == 0 then return nil, nil end

    local sumX, sumY, sumZ = 0.0, 0.0, 0.0
    for _, point in ipairs(points) do
        sumX = sumX + point.x
        sumY = sumY + point.y
        sumZ = sumZ + point.z
    end

    local center = {
        x = sumX / #points,
        y = sumY / #points,
        z = sumZ / #points,
    }

    local radius = 0.0
    for _, point in ipairs(points) do
        local dist = #(vec3(point.x, point.y, center.z) - vec3(center.x, center.y, center.z))
        if dist > radius then
            radius = dist
        end
    end

    return center, radius
end

local function canInteractWithAnimal(src, animalCfg)
    if WithinDistance(src, animalCfg.coords, Config.Security.actionDistance) then
        return true
    end

    if animalCfg.corral_center then
        local maxDistance = (animalCfg.corral_radius or 0.0) + Config.Security.actionDistance + 2.0
        return WithinDistance(src, animalCfg.corral_center, maxDistance)
    end

    return false
end

local function ensureFarmInventoryRow(farmId)
    MySQL.insert.await(
        'INSERT INTO `rfz_inventory` (`farm_id`) VALUES (?) ON DUPLICATE KEY UPDATE `farm_id` = VALUES(`farm_id`)',
        { farmId }
    )
end

local function loadFarmInventory()
    FarmAnimalInventory = {}

    local rows = MySQL.query.await('SELECT `farm_id`, `cows`, `pigs` FROM `rfz_inventory`') or {}
    for _, row in ipairs(rows) do
        FarmAnimalInventory[row.farm_id] = {
            cows = tonumber(row.cows) or 0,
            pigs = tonumber(row.pigs) or 0,
        }
    end

    for farmId in pairs(Farms or {}) do
        if not FarmAnimalInventory[farmId] then
            ensureFarmInventoryRow(farmId)
            FarmAnimalInventory[farmId] = { cows = 0, pigs = 0 }
        end
    end
end

local function setFarmAnimalCount(farmId, animalType, count)
    if not farmId or (animalType ~= 'cow' and animalType ~= 'pig') then return end

    local key = animalType == 'cow' and 'cows' or 'pigs'
    local safeCount = math.max(0, math.floor(tonumber(count) or 0))

    FarmAnimalInventory[farmId] = FarmAnimalInventory[farmId] or { cows = 0, pigs = 0 }
    FarmAnimalInventory[farmId][key] = safeCount

    ensureFarmInventoryRow(farmId)
    MySQL.update.await(('UPDATE `rfz_inventory` SET `%s` = ? WHERE `farm_id` = ?'):format(key), {
        safeCount, farmId
    })
end

local function changeFarmAnimalCount(farmId, animalType, delta)
    if not farmId or (animalType ~= 'cow' and animalType ~= 'pig') then return 0 end

    local key = animalType == 'cow' and 'cows' or 'pigs'
    local current = (FarmAnimalInventory[farmId] and FarmAnimalInventory[farmId][key]) or 0
    local nextValue = math.max(0, current + math.floor(tonumber(delta) or 0))
    setFarmAnimalCount(farmId, animalType, nextValue)
    return nextValue
end

-- ─── Índice de animais ────────────────────────────────────────────────────────

local function buildIndex()
    AnimalConfigs = {}
    for farmId, farm in pairs(Farms or {}) do
        for _, corral in ipairs(farm.corrals or {}) do
            local cfg = Config.Animals[corral.type]
            local corralCenter, corralRadius = getCorralBounds(corral.area)
            for slot, point in ipairs(corral.spawn_points or {}) do
                local id = farmId .. '_' .. corral.id .. '_' .. slot
                AnimalConfigs[id] = {
                    id       = id,
                    farm_id  = farmId,
                    corral_id = corral.id,
                    type     = corral.type,
                    slot     = slot,
                    coords   = point,
                    corral_area = corral.area,
                    corral_center = corralCenter,
                    corral_radius = corralRadius,
                    feed_zone = corral.feed_zone,
                    water_zone = corral.water_zone,
                    cfg      = cfg,
                }
            end
        end
    end
    Dbg('animals', 'buildIndex total=' .. (function()
        local c = 0
        for _ in pairs(AnimalConfigs) do c = c + 1 end
        return c
    end)())
end

-- ─── Persistência ─────────────────────────────────────────────────────────────

function SaveAnimalState(id)
    local s = AnimalStates[id]
    local c = AnimalConfigs[id]
    if not s or not c then return end
    MySQL.insert.await(
        [[INSERT INTO `rfz_animals`
            (`id`,`farm_id`,`corral_id`,`slot`,`type`,`hunger`,`thirst`,`health`,`last_fed`,`last_drank`,`last_milked`,`born_at`,`active`)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
          ON DUPLICATE KEY UPDATE
            `hunger`=VALUES(`hunger`),`thirst`=VALUES(`thirst`),`health`=VALUES(`health`),
            `last_fed`=VALUES(`last_fed`),`last_drank`=VALUES(`last_drank`),`last_milked`=VALUES(`last_milked`),
            `active`=VALUES(`active`)]],
        { id, c.farm_id, c.corral_id, c.slot, c.type,
          s.hunger, s.thirst, s.health, s.last_fed, s.last_drank, s.last_milked, s.born_at, s.active and 1 or 0 }
    )
end

local function SaveAllAnimalStates()
    local rows, params = {}, {}
    for id, s in pairs(AnimalStates) do
        local c = AnimalConfigs[id]
        if s and c then
            rows[#rows + 1] = '(?,?,?,?,?,?,?,?,?,?,?,?,?)'
            local p = { id, c.farm_id, c.corral_id, c.slot, c.type,
                        s.hunger, s.thirst, s.health, s.last_fed, s.last_drank,
                        s.last_milked, s.born_at, s.active and 1 or 0 }
            for i = 1, #p do params[#params + 1] = p[i] end
        end
    end
    if #rows == 0 then return end
    MySQL.insert.await(
        'INSERT INTO `rfz_animals` (`id`,`farm_id`,`corral_id`,`slot`,`type`,`hunger`,`thirst`,`health`,`last_fed`,`last_drank`,`last_milked`,`born_at`,`active`) VALUES '
        .. table.concat(rows, ',')
        .. ' ON DUPLICATE KEY UPDATE `hunger`=VALUES(`hunger`),`thirst`=VALUES(`thirst`),`health`=VALUES(`health`),'
        .. '`last_fed`=VALUES(`last_fed`),`last_drank`=VALUES(`last_drank`),`last_milked`=VALUES(`last_milked`),`active`=VALUES(`active`)',
        params
    )
end

local function defaultState(id)
    return {
        id         = id,
        hunger     = 100.0,
        thirst     = 100.0,
        health     = 100.0,
        last_fed   = 0,
        last_drank = 0,
        last_milked = 0,
        born_at    = Now(),
        active     = false,
        busy       = nil,
    }
end

local function loadStates()
    loadFarmInventory()

    local rows = MySQL.query.await('SELECT * FROM `rfz_animals`')
    local persisted = {}
    local persistedActiveCounts = {}
    for _, row in ipairs(rows or {}) do
        persisted[row.id] = {
            id          = row.id,
            hunger      = row.hunger,
            thirst      = row.thirst or 100.0,
            health      = row.health,
            last_fed    = row.last_fed,
            last_drank  = row.last_drank or 0,
            last_milked = row.last_milked,
            born_at     = row.born_at,
            active      = row.active == 1,
            busy        = nil,
        }

        if row.active == 1 then
            persistedActiveCounts[row.farm_id] = persistedActiveCounts[row.farm_id] or { cows = 0, pigs = 0 }
            local countKey = row.type == 'cow' and 'cows' or 'pigs'
            persistedActiveCounts[row.farm_id][countKey] = (persistedActiveCounts[row.farm_id][countKey] or 0) + 1
        end
    end
    for id in pairs(AnimalConfigs) do
        AnimalStates[id] = persisted[id] or defaultState(id)
    end

    for farmId, counts in pairs(persistedActiveCounts) do
        local inventory = FarmAnimalInventory[farmId] or { cows = 0, pigs = 0 }
        if (inventory.cows or 0) <= 0 and (counts.cows or 0) > 0 then
            setFarmAnimalCount(farmId, 'cow', counts.cows)
        end
        if (inventory.pigs or 0) <= 0 and (counts.pigs or 0) > 0 then
            setFarmAnimalCount(farmId, 'pig', counts.pigs)
        end
    end

    for farmId in pairs(Farms or {}) do
        for _, animalType in ipairs({ 'cow', 'pig' }) do
            local inventory = FarmAnimalInventory[farmId] or { cows = 0, pigs = 0 }
            local desiredCount = animalType == 'cow' and inventory.cows or inventory.pigs
            local candidates = {}

            for id, cfg in pairs(AnimalConfigs) do
                if cfg.farm_id == farmId and cfg.type == animalType then
                    local state = AnimalStates[id]
                    candidates[#candidates + 1] = {
                        id = id,
                        state = state,
                    }
                end
            end

            table.sort(candidates, function(a, b)
                local aActive = a.state and a.state.active and 1 or 0
                local bActive = b.state and b.state.active and 1 or 0
                if aActive ~= bActive then
                    return aActive > bActive
                end

                local aBorn = a.state and a.state.born_at or 0
                local bBorn = b.state and b.state.born_at or 0
                if aBorn ~= bBorn then
                    return aBorn < bBorn
                end

                return a.id < b.id
            end)

            local clampedDesired = math.min(desiredCount, #candidates)
            if clampedDesired ~= desiredCount then
                setFarmAnimalCount(farmId, animalType, clampedDesired)
            end

            for index, entry in ipairs(candidates) do
                local state = entry.state
                state.active = index <= clampedDesired
                if state.active and (not state.born_at or state.born_at <= 0) then
                    state.born_at = Now()
                end
                SaveAnimalState(entry.id)
            end
        end
    end
    Dbg('animals', 'loadStates done')
end

-- ─── Tick de estado (decaimento de fome e saúde) ──────────────────────────────

local function tickState(id)
    local s = AnimalStates[id]
    local c = AnimalConfigs[id]
    if not s or not c or not s.active then return end

    local elapsed = math.max(0, Now() - (s._lastTick or Now()))
    if elapsed <= 0 then
        s._lastTick = Now()
        return
    end

    local hours = elapsed / 3600
    local cfg   = c.cfg

    s.hunger = Clamp(s.hunger - cfg.hungerDecayPerHour * hours, 0, 100)
    s.thirst = Clamp(s.thirst - (cfg.thirstDecayPerHour or cfg.hungerDecayPerHour) * hours, 0, 100)

    if s.hunger <= cfg.criticalHunger or s.thirst <= (cfg.criticalThirst or cfg.criticalHunger) then
        s.health = Clamp(s.health - cfg.healthDecayPerHour * hours, 0, 100)
    elseif s.hunger >= 60 and s.thirst >= 60 then
        s.health = Clamp(s.health + cfg.healthRegenPerHour * hours, 0, 100)
    end

    local farmData = Farms[c.farm_id]
    local corral = nil
    for _, farmCorral in ipairs(farmData and farmData.corrals or {}) do
        if farmCorral.id == c.corral_id then
            corral = farmCorral
            break
        end
    end

    if corral then
        local autoDrinkThreshold = cfg.autoDrinkThreshold or 65.0
        local feedStock = exports['rodz-fazenda']:SyncCorralSupplyStock(c.farm_id, c.corral_id, 'feed')
        local waterStock = exports['rodz-fazenda']:SyncCorralSupplyStock(c.farm_id, c.corral_id, 'water')
        feedStock = tonumber(feedStock) or 0
        waterStock = tonumber(waterStock) or 0

        if c.type == 'cow'
            and feedStock > 0
            and s.hunger <= (100.0 - COW_FEED_HUNGER_GAIN)
        then
            if removeFeedFromStash(('rfz_%s_%s_feed'):format(c.farm_id, c.corral_id), COW_FEED_ITEM_QTY) then
                local remainingFeedStock = exports['rodz-fazenda']:SyncCorralSupplyStock(c.farm_id, c.corral_id, 'feed')
                remainingFeedStock = tonumber(remainingFeedStock) or 0
                s.hunger = Clamp(s.hunger + COW_FEED_HUNGER_GAIN, 0, 100)
                s.health = Clamp(s.health + (cfg.autoFeedHealthGain or cfg.feedHealthGain or 5.0), 0, 100)
                s.last_fed = Now()
                queueFarmFeedConsumptionNotice(c.farm_id, c.corral_id, COW_FEED_ITEM_QTY, remainingFeedStock)
            end
        end

        if s.thirst <= autoDrinkThreshold and waterStock > 0 and (Now() - (s.last_drank or 0)) >= 300 then
            if GetResourceState('ox_inventory') == 'started' and exports.ox_inventory:RemoveItem(('rfz_%s_%s_water'):format(c.farm_id, c.corral_id), Config.Items.water, 1) then
                exports['rodz-fazenda']:SyncCorralSupplyStock(c.farm_id, c.corral_id, 'water')
                s.thirst = Clamp(s.thirst + (cfg.drinkThirstGain or 40.0), 0, 100)
                s.health = Clamp(s.health + (cfg.drinkHealthGain or 4.0), 0, 100)
                s.last_drank = Now()
            end
        end
    end

    s._lastTick = Now()
end

local function syncAll(id)
    tickState(id)
    return AnimalStates[id]
end

-- ─── Lock / unlock para ações concorrentes ────────────────────────────────────

local function lock(src, id, action)
    local s = AnimalStates[id]
    if not s then return false, 'Animal não encontrado.' end
    if s.busy and (s.busy.expiresAt or 0) > Now() then
        return false, 'Animal já está em uso.'
    end
    local token = ('%s-%s-%s'):format(src, Now(), math.random(100000, 999999))
    s.busy = { source = src, token = token, action = action, expiresAt = Now() + Config.Security.actionTimeoutSeconds }
    return true, token
end

local function unlock(id)
    if AnimalStates[id] then AnimalStates[id].busy = nil end
end

local function validateLock(src, id, token, action)
    local s = AnimalStates[id]
    if not s or not s.busy then return false, 'Ação não disponível.' end
    if s.busy.source ~= src or s.busy.token ~= token or s.busy.action ~= action then
        return false, 'Validação falhou.'
    end
    if s.busy.expiresAt < Now() then
        unlock(id)
        return false, 'Ação expirou.'
    end
    return true
end

-- ─── Snapshot público para o cliente ──────────────────────────────────────────

local function snapshot(id)
    local s = syncAll(id)
    local c = AnimalConfigs[id]
    if not s or not c then return nil end

    local snap = {
        id       = id,
        type     = c.type,
        active   = s.active,
        ageDays  = math.floor(math.max(0, Now() - (tonumber(s.born_at) or 0)) / 86400),
        hunger   = RoundN(s.hunger, 1),
        thirst   = RoundN(s.thirst or 100.0, 1),
        health   = RoundN(s.health, 1),
        last_fed = s.last_fed,
        last_drank = s.last_drank,
        busy     = s.busy ~= nil,
    }

    if c.type == 'cow' then
        local cooldown  = (c.cfg.milkCooldown or 30) * 60
        snap.canMilk    = s.active and s.hunger >= 60 and s.health >= 50
            and (Now() - (s.last_milked or 0)) >= cooldown
    end

    return snap
end

local function allSnapshots()
    local result = {}
    for id in pairs(AnimalConfigs) do
        result[id] = snapshot(id)
    end
    return result
end

local function getAnimalLabel(animalType)
    if animalType == 'pig' then
        return 'porco', 'porcos'
    end

    return 'vaca', 'vacas'
end

local function fetchSellableAnimals(farmId, animalType, limit)
    local query = [[
        SELECT `id`, `born_at`, `health`
        FROM `rfz_animals`
        WHERE `farm_id` = ? AND `type` = ? AND `active` = 1
        ORDER BY `born_at` ASC
    ]]

    local params = { farmId, animalType }
    if limit and limit > 0 then
        query = query .. ' LIMIT ?'
        params[#params + 1] = limit
    end

    return MySQL.query.await(query, params) or {}
end

local function getAvailableSlotsForCorral(farmId, corralId, animalType)
    local total = 0
    local active = 0

    for id, cfg in pairs(AnimalConfigs) do
        if cfg.farm_id == farmId and cfg.corral_id == corralId and cfg.type == animalType then
            total = total + 1
            local state = AnimalStates[id]
            if state and state.active then
                active = active + 1
            end
        end
    end

    return total, math.max(0, total - active)
end

local function findFirstAvailableAnimalSlot(farmId, animalType, preferredCorralId)
    for id, cfg in pairs(AnimalConfigs) do
        if cfg.farm_id == farmId and cfg.type == animalType then
            if not preferredCorralId or cfg.corral_id == preferredCorralId then
                local state = AnimalStates[id]
                if state and not state.active then
                    return id, cfg, state
                end
            end
        end
    end

    return nil, nil, nil
end

-- ─── Callbacks ────────────────────────────────────────────────────────────────

lib.callback.register('rodz-fazenda:server:getAnimalData', function(src)
    return allSnapshots()
end)

lib.callback.register('rodz-fazenda:server:getPurchaseCorrals', function(src, farmId, animalType)
    local farm = Farms[farmId]
    if not farm then
        return { ok = false, msg = 'Fazenda invalida.' }
    end

    local corrals = {}
    for _, corral in ipairs(farm.corrals or {}) do
        if corral.type == animalType then
            local totalSlots, availableSlots = getAvailableSlotsForCorral(farmId, corral.id, animalType)
            local cLabel = exports['rodz-fazenda']:CorralLabel(farmId, corral.id, animalType)
            corrals[#corrals + 1] = {
                value     = corral.id,
                label     = ('%s (%d/%d vagas)'):format(cLabel, availableSlots, totalSlots),
                available = availableSlots,
                total     = totalSlots,
            }
        end
    end

    table.sort(corrals, function(a, b) return a.label < b.label end)

    if #corrals == 0 then
        return { ok = false, msg = 'Nao ha currais desse tipo nessa fazenda.' }
    end

    return { ok = true, corrals = corrals }
end)

lib.callback.register('rodz-fazenda:server:beginAction', function(src, id, action)
    local c = AnimalConfigs[id]
    local s = AnimalStates[id]
    if not c or not s then return { ok = false, msg = 'Animal inválido.' } end

    if not canInteractWithAnimal(src, c) then
        return { ok = false, msg = 'Longe demais do animal.' }
    end
    if not s.active then
        return { ok = false, msg = 'Esse animal não está ativo.' }
    end

    local actionMap = {
        feed_animal  = { needFeed = true  },
        milk_cow     = { cowOnly  = true  },
        use_medicine = { needMed  = true  },
    }
    local entry = actionMap[action]
    if not entry then return { ok = false, msg = 'Ação inválida.' } end
    if entry.cowOnly and c.type ~= 'cow' then
        return { ok = false, msg = 'Apenas vacas podem ser ordenhadas.' }
    end
    if action == 'feed_animal' and c.type == 'cow' then
        return { ok = false, msg = 'A vaca se alimenta automaticamente no comedouro.' }
    end
    if entry.needFeed and not HasItem(src, Config.Items.feed, 1) then
        return { ok = false, msg = 'Você precisa de ração.' }
    end
    if entry.needMed and not HasItem(src, Config.Items.medicine, 1) then
        return { ok = false, msg = 'Você precisa de remédio.' }
    end
    if action == 'milk_cow' then
        local cooldown = (c.cfg.milkCooldown or 30) * 60
        if (Now() - (s.last_milked or 0)) < cooldown then
            return { ok = false, msg = 'Essa vaca ainda não pode ser ordenhada.' }
        end
    end

    local ok, tokenOrMsg = lock(src, id, action)
    if not ok then return { ok = false, msg = tokenOrMsg } end

    return { ok = true, token = tokenOrMsg }
end)

lib.callback.register('rodz-fazenda:server:cancelAction', function(src, id, token, action)
    if validateLock(src, id, token, action) then unlock(id) end
    return true
end)

lib.callback.register('rodz-fazenda:server:completeAction', function(src, id, token, action)
    local c = AnimalConfigs[id]
    local s = AnimalStates[id]
    if not c or not s then return { ok = false, msg = 'Animal inválido.' } end

    local valid, msg = validateLock(src, id, token, action)
    if not valid then return { ok = false, msg = msg } end

    local result = { ok = false }

    if action == 'feed_animal' then
        if c.type == 'cow' then
            unlock(id)
            return { ok = false, msg = 'A vaca se alimenta automaticamente no comedouro.' }
        end
        if not TakeItem(src, Config.Items.feed, 1) then
            unlock(id)
            return { ok = false, msg = 'Falha ao remover ração.' }
        end
        s.hunger   = Clamp(s.hunger + c.cfg.feedHungerGain, 0, 100)
        s.health   = Clamp(s.health + c.cfg.feedHealthGain, 0, 100)
        s.last_fed = Now()
        result     = { ok = true, msg = 'Animal alimentado!' }

    elseif action == 'milk_cow' then
        local cfg    = Config.Animals.cow
        local amount = math.random(cfg.milkYield.min, cfg.milkYield.max)
        if not GiveItem(src, Config.Items.milk, amount) then
            unlock(id)
            return { ok = false, msg = 'Sem espaço no inventário.' }
        end
        s.last_milked = Now()
        result        = { ok = true, msg = ('Você coletou %dx leite.'):format(amount) }

    elseif action == 'use_medicine' then
        if not TakeItem(src, Config.Items.medicine, 1) then
            unlock(id)
            return { ok = false, msg = 'Falha ao remover remédio.' }
        end
        s.health = Clamp(s.health + 30, 0, 100)
        result   = { ok = true, msg = ('Animal medicado. Saúde: %d%%'):format(math.floor(s.health)) }
    end

    unlock(id)
    SaveAnimalState(id)
    local okSnapshots, snapshots = pcall(allSnapshots)
    if okSnapshots then
        result.snapshots = snapshots
    end
    return result
end)

-- ─── Compra de itens ──────────────────────────────────────────────────────────

lib.callback.register('rodz-fazenda:server:buyFeed', function(src, qty)
    qty = math.max(1, math.min(50, math.floor(tonumber(qty) or 1)))
    local total = Config.Payments.feedBuy * qty
    if not RemoveMoney(src, total, 'rodz-fazenda-buy-feed') then
        return { ok = false, msg = ('Você precisa de $%s.'):format(total) }
    end
    if not GiveItem(src, Config.Items.feed, qty) then
        AddMoney(src, total, 'rodz-fazenda-refund-feed')
        return { ok = false, msg = 'Sem espaço no inventário.' }
    end
    return { ok = true, msg = ('Você comprou %dx ração por $%s.'):format(qty, total) }
end)

lib.callback.register('rodz-fazenda:server:buyWater', function(src, qty)
    qty = math.max(1, math.min(50, math.floor(tonumber(qty) or 1)))
    local total = Config.Payments.waterBuy * qty
    if not RemoveMoney(src, total, 'rodz-fazenda-buy-water') then
        return { ok = false, msg = ('Você precisa de $%s.'):format(total) }
    end
    if not GiveItem(src, Config.Items.water, qty) then
        AddMoney(src, total, 'rodz-fazenda-refund-water')
        return { ok = false, msg = 'Sem espaço no inventário.' }
    end
    return { ok = true, msg = ('Você comprou %dx água por $%s.'):format(qty, total) }
end)

lib.callback.register('rodz-fazenda:server:buyMedicine', function(src, qty)
    qty = math.max(1, math.min(20, math.floor(tonumber(qty) or 1)))
    local total = Config.Payments.medicineBuy * qty
    if not RemoveMoney(src, total, 'rodz-fazenda-buy-medicine') then
        return { ok = false, msg = ('Você precisa de $%s.'):format(total) }
    end
    if not GiveItem(src, Config.Items.medicine, qty) then
        AddMoney(src, total, 'rodz-fazenda-refund-medicine')
        return { ok = false, msg = 'Sem espaço no inventário.' }
    end
    return { ok = true, msg = ('Você comprou %dx remédio por $%s.'):format(qty, total) }
end)

lib.callback.register('rodz-fazenda:server:sellMilk', function(src, farmId)
    local farm = Farms[farmId]
    if farm and farm.owner_citizenid then
        if GetCitizenId(src) ~= farm.owner_citizenid then
            return { ok = false, msg = 'Apenas o dono da fazenda pode vender leite.' }
        end
    end
    local qty = 0
    if GetResourceState('ox_inventory') == 'started' then
        local ok, count = pcall(function()
            return exports.ox_inventory:Search(src, 'count', Config.Items.milk)
        end)
        if ok then qty = tonumber(count) or 0 end
    else
        local player = GetQPlayer(src)
        if not player then return { ok = false, msg = 'Jogador inválido.' } end
        for _, item in pairs(player.PlayerData.items or {}) do
            if item and item.name == Config.Items.milk then qty = qty + (item.amount or 0) end
        end
    end

    if qty <= 0 then return { ok = false, msg = 'Você não tem leite para vender.' } end

    if not TakeItem(src, Config.Items.milk, qty) then
        return { ok = false, msg = 'Falha ao remover leite.' }
    end
    local total = qty * Config.Payments.milkSell
    AddMoney(src, total, 'rodz-fazenda-sell-milk')
    return { ok = true, msg = ('Você vendeu %dx leite por $%s.'):format(qty, total) }
end)

-- ─── Reconstrução após mudança de fazendas ────────────────────────────────────

local function getSellableAnimals(src, farmId, animalType)
    local farm = Farms[farmId]
    local singular = getAnimalLabel(animalType)
    if not farm then
        return { ok = false, msg = 'Fazenda invalida.' }
    end

    if not IsLafuente(src) then
        return { ok = false, msg = ('Apenas o Lafuente pode vender os %s da fazenda.'):format(select(2, getAnimalLabel(animalType))) }
    end

    if not farm.npc_coords or not WithinDistance(src, farm.npc_coords, Config.Security.saleDistance) then
        return { ok = false, msg = 'Voce precisa estar perto do fazendeiro.' }
    end

    local rows = fetchSellableAnimals(farmId, animalType)
    local count = #rows
    if count <= 0 then
        return { ok = false, msg = ('Voce nao tem %s para vender nessa fazenda.'):format(select(2, getAnimalLabel(animalType))) }
    end

    local oldestPrice = GetAnimalSalePrice(animalType, rows[1].born_at or 0)
    local youngestPrice = GetAnimalSalePrice(animalType, rows[#rows].born_at or 0)

    return {
        ok = true,
        count = count,
        oldestPrice = oldestPrice,
        youngestPrice = youngestPrice,
        animalType = animalType,
        animalLabel = singular,
    }
end

local function sellAnimals(src, farmId, animalType, qty)
    local farm = Farms[farmId]
    local singular, plural = getAnimalLabel(animalType)
    if not farm then
        return { ok = false, msg = 'Fazenda invalida.' }
    end

    if not IsLafuente(src) then
        return { ok = false, msg = ('Apenas o Lafuente pode vender os %s da fazenda.'):format(plural) }
    end

    if not farm.npc_coords or not WithinDistance(src, farm.npc_coords, Config.Security.saleDistance) then
        return { ok = false, msg = 'Voce precisa estar perto do fazendeiro.' }
    end

    qty = math.max(1, math.floor(tonumber(qty) or 0))

    local availableRows = fetchSellableAnimals(farmId, animalType)
    local availableCount = #availableRows
    if availableCount <= 0 then
        return { ok = false, msg = ('Voce nao tem %s para vender nessa fazenda.'):format(plural) }
    end

    if qty > availableCount then
        return { ok = false, msg = ('Voce possui %d %s.'):format(availableCount, plural) }
    end

    local rows = fetchSellableAnimals(farmId, animalType, qty)
    local payout = 0
    local sold = 0

    for _, row in ipairs(rows) do
        local state = AnimalStates[row.id]
        if state then
            local salePrice = GetAnimalSalePrice(animalType, row.born_at or state.born_at or 0)
            payout = payout + salePrice
            sold = sold + 1

            state.active = false
            state.hunger = 100.0
            state.thirst = 100.0
            state.health = 100.0
            state.born_at = Now()
            state.last_fed = 0
            state.last_drank = 0
            state.last_milked = 0
            state.busy = nil
            SaveAnimalState(row.id)
        end
    end

    if sold <= 0 then
        return { ok = false, msg = ('Nenhum %s pode ser vendido.'):format(singular) }
    end

    changeFarmAnimalCount(farmId, animalType, -sold)
    AddMoney(src, payout, ('rodz-fazenda-sell-%s'):format(plural))
    TriggerClientEvent('rodz-fazenda:client:reloadAnimals', -1, farmId)

    return {
        ok = true,
        sold = sold,
        payout = payout,
        msg = ('Voce vendeu %d %s por $%s.'):format(sold, sold == 1 and singular or plural, payout),
        snapshots = allSnapshots(),
    }
end

lib.callback.register('rodz-fazenda:server:getSellableCows', function(src, farmId)
    return getSellableAnimals(src, farmId, 'cow')
end)

lib.callback.register('rodz-fazenda:server:getSellablePigs', function(src, farmId)
    return getSellableAnimals(src, farmId, 'pig')
end)

lib.callback.register('rodz-fazenda:server:sellCows', function(src, farmId, qty)
    if not IsAdmin(src) and not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Você não é o dono desta fazenda.' }
    end
    return sellAnimals(src, farmId, 'cow', qty)
end)

lib.callback.register('rodz-fazenda:server:sellPigs', function(src, farmId, qty)
    if not IsAdmin(src) and not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Você não é o dono desta fazenda.' }
    end
    return sellAnimals(src, farmId, 'pig', qty)
end)

lib.callback.register('rodz-fazenda:server:buyAnimalV2', function(src, farmId, animalType, qty, corralId)
    qty = math.max(1, math.floor(tonumber(qty) or 1))

    local farm = Farms[farmId]
    if not farm then
        return { ok = false, msg = 'Fazenda invalida.' }
    end
    if not IsAdmin(src) and not IsFarmOwner(src, farmId) then
        return { ok = false, msg = 'Você não é o dono desta fazenda.' }
    end

    if corralId then
        local totalSlots, availableSlots = getAvailableSlotsForCorral(farmId, corralId, animalType)
        if totalSlots <= 0 then
            return { ok = false, msg = 'Curral invalido para esse tipo de animal.' }
        end
        if qty > availableSlots then
            return { ok = false, msg = ('Esse curral possui apenas %d vaga(s) disponiveis.'):format(availableSlots) }
        end
    end

    local isCow = animalType == 'cow'
    local isPig = animalType == 'pig'
    local unitPrice = isCow and (Config.Payments.cowBuy or 5000) or Config.Payments.pigBuy
    local totalPrice = unitPrice * qty
    local dirtyItem = Config.Payments.animalBuyDirtyItem or Config.Payments.cowBuyDirtyItem or 'black_money'
    local animalLabelPlural = isCow and 'vacas' or (isPig and 'porcos' or 'animais')
    local useDirtyMoney = isCow or isPig

    if useDirtyMoney then
        if not TakeItem(src, dirtyItem, totalPrice) then
            return { ok = false, msg = ('Voce nao tem dinheiro sujo suficiente para comprar %s (%d).'):format(animalLabelPlural, totalPrice) }
        end
    elseif not RemoveMoney(src, totalPrice, 'rodz-fazenda-buy-animal') then
        return { ok = false, msg = ('Voce precisa de $%s.'):format(totalPrice) }
    end

    local bought = 0
    for _ = 1, qty do
        local id, _, state = findFirstAvailableAnimalSlot(farmId, animalType, corralId)
        if not id or not state then
            break
        end

        state.active = true
        state.hunger = 100.0
        state.thirst = 100.0
        state.health = 100.0
        state.born_at = Now()
        state.last_fed = 0
        state.last_drank = 0
        state.last_milked = 0
        SaveAnimalState(id)
        bought = bought + 1
    end

    if bought <= 0 then
        if useDirtyMoney then
            GiveItem(src, dirtyItem, totalPrice)
        else
            AddMoney(src, totalPrice, 'rodz-fazenda-refund-animal')
        end
        return { ok = false, msg = 'Nao ha vagas disponiveis nessa fazenda.' }
    end

    if bought < qty then
        local refund = (qty - bought) * unitPrice
        if useDirtyMoney then
            GiveItem(src, dirtyItem, refund)
        else
            AddMoney(src, refund, 'rodz-fazenda-refund-animal')
        end
    end

    changeFarmAnimalCount(farmId, animalType, bought)
    return {
        ok = true,
        msg = ('%d animal(is) comprado(s) com sucesso!'):format(bought),
        snapshots = allSnapshots(),
    }
end)

AddEventHandler('rodz-fazenda:server:rebuildAnimals', function()
    buildIndex()
    loadStates()
    Dbg('animals', 'rebuildAnimals done')
end)

-- Purga completa de uma fazenda deletada: DB + memória servidor
AddEventHandler('rodz-fazenda:server:purgeFarmAnimals', function(farmId)
    if not farmId then return end

    -- Limpa AnimalStates e AnimalConfigs das entradas desta fazenda
    for id, cfg in pairs(AnimalConfigs or {}) do
        if cfg.farm_id == farmId then
            AnimalStates[id]  = nil
            AnimalConfigs[id] = nil
        end
    end

    -- Limpa inventário em memória
    FarmAnimalInventory[farmId] = nil

    -- Remove do DB: animais, currais, inventário
    MySQL.query.await('DELETE FROM `rfz_animals`   WHERE `farm_id` = ?', { farmId })
    MySQL.query.await('DELETE FROM `rfz_corrals`   WHERE `farm_id` = ?', { farmId })
    MySQL.query.await('DELETE FROM `rfz_inventory` WHERE `farm_id` = ?', { farmId })

    Dbg('animals', 'purgeFarmAnimals done farmId=' .. tostring(farmId))
end)

CreateThread(function()
    while true do
        Wait(30000)

        for id in pairs(AnimalConfigs) do
            tickState(id)
        end

        SaveAllAnimalStates()
        flushFarmFeedConsumptionNotices()
    end
end)

-- ─── Callbacks do Tablet NUI ──────────────────────────────────────────────────

lib.callback.register('rodz-fazenda:server:getTabletFarmData', function(src, farmId)
    print('[rfz-debug][S1] getTabletFarmData | src=' .. tostring(src) .. ' farmId=' .. tostring(farmId))

    local farm = Farms[farmId]
    if not farm then
        local keys = ''
        for k in pairs(Farms) do keys = keys .. k .. ',' end
        print('[rfz-debug][S1-FAIL] Farms nao tem farmId=' .. tostring(farmId) .. ' | keys={' .. keys .. '}')
        return { ok = false }
    end
    print('[rfz-debug][S2] farm encontrado | corrals=#' .. tostring(#(farm.corrals or {})))

    local inventory   = FarmAnimalInventory[farmId] or { cows = 0, pigs = 0 }
    print('[rfz-debug][S3] inventory | cows=' .. tostring(inventory.cows) .. ' pigs=' .. tostring(inventory.pigs))

    local corralsData = {}
    for _, corral in ipairs(farm.corrals or {}) do
        local totalSlots  = #(corral.spawn_points or {})
        local activeCount = 0
        for id, cfg in pairs(AnimalConfigs) do
            if cfg.farm_id == farmId and cfg.corral_id == corral.id then
                local st = AnimalStates[id]
                if st and st.active then activeCount = activeCount + 1 end
            end
        end
        local feedStock  = exports['rodz-fazenda']:SyncCorralSupplyStock(farmId, corral.id, 'feed')
        local waterStock = exports['rodz-fazenda']:SyncCorralSupplyStock(farmId, corral.id, 'water')
        feedStock  = tonumber(feedStock)  or 0
        waterStock = tonumber(waterStock) or 0

        corralsData[#corralsData + 1] = {
            id          = corral.id,
            label       = exports['rodz-fazenda']:CorralLabel(farmId, corral.id, corral.type),
            type        = corral.type,
            totalSlots  = totalSlots,
            activeCount = activeCount,
            feedStock   = feedStock,
            waterStock  = waterStock,
        }
    end

    print('[rfz-debug][S4] retornando ok=true | corrals=#' .. tostring(#corralsData))
    return {
        ok       = true,
        cowCount = inventory.cows or 0,
        pigCount = inventory.pigs or 0,
        corrals  = corralsData,
    }
end)

lib.callback.register('rodz-fazenda:server:getPlayerInventoryItems', function(src)
    print('[rfz-debug][S5] getPlayerInventoryItems | src=' .. tostring(src))
    local ok1, milk     = pcall(function() return exports.ox_inventory:GetItem(src, Config.Items.milk,     nil, false) end)
    local ok2, medicine = pcall(function() return exports.ox_inventory:GetItem(src, Config.Items.medicine, nil, false) end)
    if not ok1 then print('[rfz-debug][S5-WARN] ox_inventory:GetItem milk erro: ' .. tostring(milk)) milk = nil end
    if not ok2 then print('[rfz-debug][S5-WARN] ox_inventory:GetItem medicine erro: ' .. tostring(medicine)) medicine = nil end
    local result = {
        milk     = milk     and milk.count     or 0,
        medicine = medicine and medicine.count or 0,
    }
    print('[rfz-debug][S6] retornando milk=' .. result.milk .. ' medicine=' .. result.medicine)
    return result
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    Wait(500)
    buildIndex()
    loadStates()
end)

exports('GetAnimalStates',  function() return AnimalStates  end)
exports('GetAnimalConfigs', function() return AnimalConfigs end)
exports('GetFarmAnimalInventory', function() return FarmAnimalInventory end)
exports('AllSnapshots',     allSnapshots)
exports('SetFarmAnimalCount', setFarmAnimalCount)
exports('ChangeFarmAnimalCount', changeFarmAnimalCount)
exports('SaveAnimalState',  SaveAnimalState)
