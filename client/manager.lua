-- Manager - Cartel F9: gerenciar currais

local PolyZone = require 'modules.polyzone'
local Preview  = require 'modules.preview'

local function notify(description, notifyType, title)
    lib.notify({
        title = title or 'Fazenda',
        description = description,
        type = notifyType or 'inform',
    })
end

local function isCartel()
    local player = exports.qbx_core:GetPlayerData()
    if not player or not player.gang then return false end
    if player.gang.name ~= Config.CartelGang then return false end
    return player.gang.grade and player.gang.grade.level >= 0
end

local function togglePolyzoneDebug()
    Config.Debug = not Config.Debug
    TriggerServerEvent('rodz-fazenda:server:requestSync')
    notify(
        Config.Debug and 'Debug visual das polyzones ativado.' or 'Debug visual das polyzones desativado.',
        'success'
    )
end

local function showSpawnPointUI(totalPoints)
    lib.showTextUI(table.concat({
        'Posicionamento de vagas',
        '',
        '[Espaco] adicionar vaga',
        '[Scroll Mouse] aproximar / afastar',
        '[Seta Dir / Esq] girar',
        '[Seta Cima / Baixo] ajustar altura',
        '[Enter] confirmar',
        '[Backspace] remover ultima',
        '[X] cancelar',
        '',
        ('Vagas adicionadas: %d'):format(totalPoints or 0),
    }, '\n'), {
        position = 'right-center',
        icon     = '',
        style    = {
            borderRadius = 6,
            padding = '14px 16px',
            maxWidth = '380px',
            width = '380px',
            lineHeight = 1.45,
            textAlign = 'left',
        },
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

local function placeSpawnPoints(corrType, onDone)
    local animalCfg = Config.Animals[corrType] or {}
    local modelName = animalCfg.model or 'a_c_cow'
    local pedType   = animalCfg.pedType or 28
    local points    = {}
    local busy      = true

    showSpawnPointUI(#points)

    local hash = joaat(modelName)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        lib.hideTextUI()
        notify(('Modelo invalido para o preview: %s'):format(modelName), 'error')
        return nil
    end

    local ok, err = pcall(function()
        lib.requestModel(hash, 10000)
    end)

    if not ok then
        lib.hideTextUI()
        notify(('Nao foi possivel carregar o preview do animal (%s).'):format(err or modelName), 'error')
        return nil
    end

    local playerCoords = GetEntityCoords(cache.ped)
    local playerHeading = GetEntityHeading(cache.ped)
    local cursor = CreatePed(pedType, hash, playerCoords.x, playerCoords.y, playerCoords.z, playerHeading, false, false)
    if not DoesEntityExist(cursor) then
        lib.hideTextUI()
        notify('Falha ao criar o preview do animal.', 'error')
        return nil
    end

    SetEntityAlpha(cursor, 180, false)
    SetEntityInvincible(cursor, true)
    SetEntityCollision(cursor, false, false)
    FreezeEntityPosition(cursor, true)
    SetBlockingOfNonTemporaryEvents(cursor, true)

    local previews = {}
    local heading  = playerHeading
    local prefixZ  = 0.0
    local distance = 4.0

    local p = promise.new()

    CreateThread(function()
        while busy do
            Wait(0)

            local playerPos = GetEntityCoords(cache.ped)
            local camRot = GetGameplayCamRot(2)
            local rad = math.rad(camRot.z)
            local nx = playerPos.x - math.sin(rad) * distance
            local ny = playerPos.y + math.cos(rad) * distance
            local baseZ = resolveGroundZ(nx, ny, playerPos.z)
            local nz = baseZ + prefixZ

            FreezeEntityPosition(cursor, false)
            SetEntityCoords(cursor, nx, ny, nz, false, false, false, false)
            SetEntityHeading(cursor, heading)
            FreezeEntityPosition(cursor, true)

            DisableControlAction(0, 174, true)
            DisableControlAction(0, 175, true)
            DisableControlAction(0, 172, true)
            DisableControlAction(0, 173, true)
            DisableControlAction(0, 22, true)
            DisableControlAction(0, 176, true)
            DisableControlAction(0, 194, true)
            DisableControlAction(0, 73, true)
            DisableControlAction(0, 14, true)
            DisableControlAction(0, 15, true)

            if IsDisabledControlPressed(0, 174) then heading = (heading + 1.0) % 360 end
            if IsDisabledControlPressed(0, 175) then heading = (heading - 1.0 + 360) % 360 end
            if IsDisabledControlJustPressed(0, 172) then prefixZ = prefixZ + 0.1 end
            if IsDisabledControlJustPressed(0, 173) then prefixZ = prefixZ - 0.1 end
            if IsDisabledControlJustPressed(0, 14) then distance = math.min(distance + 0.5, 12.0) end
            if IsDisabledControlJustPressed(0, 15) then distance = math.max(distance - 0.5, 1.5) end

            if IsDisabledControlJustPressed(0, 22) then
                local c = GetEntityCoords(cursor)
                local pv = CreatePed(pedType, hash, c.x, c.y, c.z, heading, false, false)
                SetEntityAlpha(pv, 100, false)
                SetEntityInvincible(pv, true)
                SetEntityCollision(pv, false, false)
                FreezeEntityPosition(pv, true)
                SetBlockingOfNonTemporaryEvents(pv, true)
                points[#points + 1] = { x = c.x, y = c.y, z = c.z, w = heading }
                previews[#previews + 1] = pv
                lib.notify({ description = 'Vaga ' .. #points .. ' adicionada.', type = 'inform' })
                showSpawnPointUI(#points)
            end

            if IsDisabledControlJustPressed(0, 194) and #points > 0 then
                if DoesEntityExist(previews[#previews]) then DeleteEntity(previews[#previews]) end
                table.remove(previews, #previews)
                table.remove(points, #points)
                lib.notify({ description = 'Ultima vaga removida.', type = 'inform' })
                showSpawnPointUI(#points)
            end

            if IsDisabledControlJustPressed(0, 176) then
                if #points < 1 then
                    lib.notify({ description = 'Adicione pelo menos 1 vaga.', type = 'error' })
                else
                    busy = false
                    lib.hideTextUI()
                    if DoesEntityExist(cursor) then DeleteEntity(cursor) end
                    for _, pv in ipairs(previews) do
                        if DoesEntityExist(pv) then DeleteEntity(pv) end
                    end
                    p:resolve(points)
                end
            end

            if IsDisabledControlJustPressed(0, 73) then
                busy = false
                lib.hideTextUI()
                if DoesEntityExist(cursor) then DeleteEntity(cursor) end
                for _, pv in ipairs(previews) do
                    if DoesEntityExist(pv) then DeleteEntity(pv) end
                end
                p:resolve(nil)
            end
        end
    end)

    return Citizen.Await(p)
end

local openManager

local function editTruckPoint(farmId)
    notify('Posicione o novo ponto de parada do caminhao.')
    local truckPoint = Preview.placeVehicle(Config.Truck.vehicle or 'benson', 'Ponto do caminhao')
    if not truckPoint then
        notify('Edicao cancelada.', 'error')
        return
    end

    TriggerServerEvent('rodz-fazenda:server:updateTruckPoint', farmId, {
        x = truckPoint.x,
        y = truckPoint.y,
        z = truckPoint.z,
        w = truckPoint.w,
    })
end

function editCorralArea(farmId, corral)
    notify('Redesenhe a nova area do curral.')
    local area = PolyZone.create()
    if not area then
        notify('Edicao cancelada.', 'error')
        return
    end

    TriggerServerEvent('rodz-fazenda:server:updateCorralArea', farmId, corral.id, area)
end

function editCorralCapacity(farmId, corral)
    notify('Reposicione as vagas do curral para definir a nova capacidade maxima.')
    local spawnPoints = placeSpawnPoints(corral.type)
    if not spawnPoints or #spawnPoints == 0 then
        notify('Edicao cancelada.', 'error')
        return
    end

    TriggerServerEvent('rodz-fazenda:server:updateCorralSpawnPoints', farmId, corral.id, spawnPoints)
end

function editCorralFeedZone(farmId, corral)
    notify('Posicione a zona do comedouro do curral.')
    local zoneData = PolyZone.createPoint('Ponto do Comedouro')
    if not zoneData then
        notify('Edicao cancelada.', 'error')
        return
    end

    TriggerServerEvent('rodz-fazenda:server:updateCorralFeedZone', farmId, corral.id, zoneData)
end

function editCorralWaterZone(farmId, corral)
    notify('Posicione a zona do bebedouro do curral.')
    local zoneData = PolyZone.createPoint('Ponto do Bebedouro')
    if not zoneData then
        notify('Edicao cancelada.', 'error')
        return
    end

    TriggerServerEvent('rodz-fazenda:server:updateCorralWaterZone', farmId, corral.id, zoneData)
end

local function openCorralManager(farmId, farm, corral)
    lib.registerContext({
        id = 'rfz_corral_manager_' .. corral.id,
        title = ('Curral %s'):format(corral.id),
        menu = 'rfz_manager_' .. farmId,
        options = {
            {
                title = 'Editar tamanho do curral',
                icon = 'draw-polygon',
                description = 'Redesenhar a area do curral.',
                onSelect = function()
                    editCorralArea(farmId, corral)
                end,
            },
            {
                title = 'Editar quantidade maxima',
                icon = 'hashtag',
                description = ('Capacidade atual: %d animal(is).'):format(#(corral.spawn_points or {})),
                onSelect = function()
                    editCorralCapacity(farmId, corral)
                end,
            },
            {
                title = 'Editar comedouro',
                icon = 'wheat-awn',
                description = corral.feed_zone and ('Racao armazenada: %d'):format(tonumber(corral.feed_stock) or 0) or 'Definir a zona do comedouro.',
                onSelect = function()
                    editCorralFeedZone(farmId, corral)
                end,
            },
            {
                title = 'Editar bebedouro',
                icon = 'glass-water',
                description = corral.water_zone and ('Agua armazenada: %d'):format(tonumber(corral.water_stock) or 0) or 'Definir a zona do bebedouro.',
                onSelect = function()
                    editCorralWaterZone(farmId, corral)
                end,
            },
            {
                title = 'Deletar curral',
                icon = 'trash',
                description = 'Remove o curral por completo.',
                onSelect = function()
                    local alert = lib.alertDialog({
                        header   = 'Deletar Curral',
                        content  = ('Deletar o curral %s?'):format(corral.id),
                        centered = true,
                        cancel   = true,
                    })
                    if alert == 'confirm' then
                        TriggerServerEvent('rodz-fazenda:server:deleteCorral', farmId, corral.id)
                        notify('Curral deletado.', 'success')
                    end
                end,
            },
        },
    })
    lib.showContext('rfz_corral_manager_' .. corral.id)
end

function createCorral(farmId, farm)
    local currals = farm.corrals or {}
    if #currals >= Config.MaxCorrals then
        notify('Maximo de ' .. Config.MaxCorrals .. ' currais por fazenda.', 'error')
        return
    end

    local input = lib.inputDialog('Novo Curral', {
        { type = 'select', label = 'Tipo de animal', options = {
            { value = 'cow', label = 'Vacas' },
            { value = 'pig', label = 'Porcos' },
        }, required = true },
    })
    if not input or not input[1] then return end
    local corrType = input[1]

    notify('Desenhe a area do curral.')
    local area = PolyZone.create()
    if not area then
        notify('Cancelado.', 'error')
        return
    end

    notify('Posicione as vagas dos animais. A caixa de instrucoes fica na lateral.')
    local spawnPoints = placeSpawnPoints(corrType)
    if not spawnPoints or #spawnPoints == 0 then
        notify('Nenhuma vaga criada. Cancelado.', 'error')
        return
    end

    TriggerServerEvent('rodz-fazenda:server:createCorral', farmId, {
        type         = corrType,
        area         = area,
        spawn_points = spawnPoints,
    })
end

openManager = function(farmId, farm)
    local currals = farm.corrals or {}
    local options = {
        {
            title       = Config.Debug and 'Desligar Debug da PolyZone' or 'Ligar Debug da PolyZone',
            icon        = Config.Debug and 'eye-slash' or 'eye',
            description = Config.Debug and 'Oculta o contorno visual das zonas.' or 'Mostra o contorno visual das zonas.',
            onSelect    = togglePolyzoneDebug,
        },
        {
            title       = 'Adicionar Curral',
            icon        = 'plus',
            description = (#currals) .. '/' .. Config.MaxCorrals .. ' currais',
            onSelect    = function()
                createCorral(farmId, farm)
            end,
        },
        {
            title       = 'Editar parada do caminhao',
            icon        = 'truck-ramp-box',
            description = 'Alterar o ponto onde o caminhao deve parar na fazenda.',
            onSelect    = function()
                editTruckPoint(farmId)
            end,
        }
    }

    for _, corral in ipairs(currals) do
        local c = corral
        options[#options + 1] = {
            title       = ('Curral %s'):format(c.id),
            icon        = c.type == 'cow' and 'cow' or 'piggybank',
            description = ('%s - %d vaga(s)'):format(
                c.type == 'cow' and 'Vacas' or 'Porcos', #(c.spawn_points or {})),
            onSelect    = function()
                openCorralManager(farmId, farm, c)
            end,
        }
    end

    lib.registerContext({
        id      = 'rfz_manager_' .. farmId,
        title   = (farm.name or farmId) .. ' - Currais',
        menu    = 'rfz_manager_list',
        options = options,
    })
    lib.showContext('rfz_manager_' .. farmId)
end

local function openFarmList()
    if not isCartel() then
        notify('Apenas membros do cartel podem acessar.', 'error')
        return
    end

    local options = {}
    for id, farm in pairs(Farms or {}) do
        local fid = id
        local f = farm
        options[#options + 1] = {
            title       = farm.name or id,
            icon        = 'tractor',
            description = (#(farm.corrals or {})) .. ' curral(is)',
            onSelect    = function() openManager(fid, f) end,
        }
    end

    if #options == 0 then
        notify('Nenhuma fazenda disponivel.', 'inform')
        return
    end

    lib.registerContext({
        id      = 'rfz_manager_list',
        title   = 'Gerenciar Currais',
        options = options,
    })
    lib.showContext('rfz_manager_list')
end

RegisterNetEvent('rodz-fazenda:client:openFarmManager')
AddEventHandler('rodz-fazenda:client:openFarmManager', function()
    openFarmList()
end)
