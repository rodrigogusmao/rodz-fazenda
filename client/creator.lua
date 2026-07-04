-- Creator - Admin F10: criar fazenda

local PolyZone = require 'modules.polyzone'
local Preview  = require 'modules.preview'

local activePreview = { cursor = nil, list = nil }

local function notify(description, notifyType, title)
    lib.notify({
        title = title or 'Fazenda',
        description = description,
        type = notifyType or 'inform',
    })
end

local function waitPreviewConfirmRelease()
    local deadline = GetGameTimer() + 300

    while GetGameTimer() < deadline do
        DisableControlAction(0, 176, true)
        DisableControlAction(0, 177, true)
        Wait(0)
    end
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
        icon = '',
        style = {
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

local function placeSpawnPoints(corrType)
    local animalCfg = Config.Animals[corrType] or {}
    local modelName = animalCfg.model or 'a_c_cow'
    local pedType = animalCfg.pedType or 28
    local points = {}
    local busy = true

    showSpawnPointUI(#points)

    local hash = joaat(modelName)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        lib.hideTextUI()
        notify(('Modelo invalido para o preview: %s'):format(modelName), 'error')
        return nil
    end

    lib.requestModel(hash, 10000)

    local playerCoords = GetEntityCoords(cache.ped)
    local playerHeading = GetEntityHeading(cache.ped)
    local cursor = CreatePed(pedType, hash, playerCoords.x, playerCoords.y, playerCoords.z, playerHeading, false, false)
    if not DoesEntityExist(cursor) then
        lib.hideTextUI()
        SetModelAsNoLongerNeeded(hash)
        notify('Falha ao criar o preview do animal.', 'error')
        return nil
    end

    SetModelAsNoLongerNeeded(hash)
    SetEntityAsMissionEntity(cursor, true, true)
    SetEntityAlpha(cursor, 180, false)
    SetEntityInvincible(cursor, true)
    SetEntityCollision(cursor, false, false)
    FreezeEntityPosition(cursor, true)
    SetBlockingOfNonTemporaryEvents(cursor, true)

    local previews = {}
    activePreview.cursor = cursor
    activePreview.list = previews
    local heading = playerHeading
    local prefixZ = 0.0
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
                SetEntityAsMissionEntity(pv, true, true)
                SetEntityAlpha(pv, 100, false)
                SetEntityInvincible(pv, true)
                SetEntityCollision(pv, false, false)
                FreezeEntityPosition(pv, true)
                SetBlockingOfNonTemporaryEvents(pv, true)
                points[#points + 1] = { x = c.x, y = c.y, z = c.z, w = heading }
                previews[#previews + 1] = pv
                showSpawnPointUI(#points)
            end

            if IsDisabledControlJustPressed(0, 194) and #points > 0 then
                if DoesEntityExist(previews[#previews]) then DeleteEntity(previews[#previews]) end
                table.remove(previews, #previews)
                table.remove(points, #points)
                showSpawnPointUI(#points)
            end

            if IsDisabledControlJustPressed(0, 176) then
                if #points < 1 then
                    notify('Adicione pelo menos 1 vaga.', 'error')
                else
                    busy = false
                    lib.hideTextUI()
                    if DoesEntityExist(cursor) then DeleteEntity(cursor) end
                    for _, pv in ipairs(previews) do
                        if DoesEntityExist(pv) then DeleteEntity(pv) end
                    end
                    activePreview.cursor = nil
                    activePreview.list = nil
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
                activePreview.cursor = nil
                activePreview.list = nil
                p:resolve(nil)
            end
        end
    end)

    return Citizen.Await(p)
end

local function createInitialCorral(farmId)
    local input = lib.inputDialog('Novo Curral Inicial', {
        { type = 'select', label = 'Tipo de animal', options = {
            { value = 'cow', label = 'Vacas' },
            { value = 'pig', label = 'Porcos' },
        }, required = true },
    })
    if not input or not input[1] then return false end

    local corrType = input[1]

    notify('Desenhe a area do curral.')
    local area = PolyZone.create()
    if not area then
        notify('Criacao do curral cancelada.', 'error')
        return false
    end

    notify('Posicione as vagas dos animais.')
    local spawnPoints = placeSpawnPoints(corrType)
    if not spawnPoints or #spawnPoints == 0 then
        notify('Criacao do curral cancelada.', 'error')
        return false
    end

    notify('Posicione a zona do comedouro.')
    local feedZone = PolyZone.createPoint('Ponto do Comedouro')
    if not feedZone then
        notify('Criacao do curral cancelada.', 'error')
        return false
    end

    Wait(200)

    notify('Posicione a zona do bebedouro.')
    local waterZone = PolyZone.createPoint('Ponto do Bebedouro')
    if not waterZone then
        notify('Criacao do curral cancelada.', 'error')
        return false
    end

    TriggerServerEvent('rodz-fazenda:server:createCorral', farmId, {
        type = corrType,
        area = area,
        spawn_points = spawnPoints,
        feed_zone = feedZone,
        water_zone = waterZone,
    })

    return true
end

local function createFarm()
    notify('Desenhe a area da fazenda. Espaco = ponto, Enter = confirmar.')
    local area = PolyZone.create()
    if not area then
        notify('Criacao cancelada.', 'error')
        return
    end

    local input = lib.inputDialog('Nova Fazenda', {
        { type = 'input',  label = 'Nome da fazenda',      placeholder = 'Fazenda Santa Rita', required = true },
        { type = 'number', label = 'Preço de venda ($)',   placeholder = '50000',              required = true, min = 0 },
    })
    if not input or not input[1] or input[1] == '' then
        notify('Criacao cancelada.', 'error')
        return
    end
    local farmName  = input[1]
    local farmPrice = math.max(0, math.floor(tonumber(input[2]) or 0))

    notify('Posicione o NPC fazendeiro.')
    local npcCoords = Preview.placePed('a_m_m_farmer_01', 'NPC Fazendeiro')
    if not npcCoords then
        notify('NPC nao posicionado. Criacao cancelada.', 'error')
        return
    end

    notify('Posicione o ponto de parada do caminhao boiadeiro.')
    local truckPoint = Preview.placeVehicle('benson', 'Parada do Caminhao')
    if not truckPoint then
        notify('Ponto do caminhao cancelado. Criacao cancelada.', 'error')
        return
    end

    waitPreviewConfirmRelease()

    local confirm = lib.alertDialog({
        header   = 'Confirmar Fazenda',
        content  = ('Nome: **%s**\nPontos da area: %d\nConfirmar criacao?'):format(farmName, #area.points),
        centered = true,
        cancel   = true,
    })
    if confirm ~= 'confirm' then
        notify('Criacao cancelada.', 'error')
        return
    end

    local result = lib.callback.await('rodz-fazenda:server:createFarm', false, {
        name        = farmName,
        price       = farmPrice,
        area        = area,
        npc_coords  = { x = npcCoords.x, y = npcCoords.y, z = npcCoords.z, w = npcCoords.w },
        truck_point = { x = truckPoint.x, y = truckPoint.y, z = truckPoint.z, w = truckPoint.w },
    })
    if not result or not result.ok or not result.farmId then
        notify(result and result.msg or 'Falha ao criar fazenda.', 'error')
        return
    end

    while true do
        local nextStep = lib.alertDialog({
            header = 'Setup Inicial',
            content = 'Deseja criar um curral inicial com comedouro e bebedouro agora?',
            centered = true,
            cancel = true,
        })

        if nextStep ~= 'confirm' then
            break
        end

        local created = createInitialCorral(result.farmId)
        if not created then
            break
        end
    end
end

local listFarms

local function editFarmArea(farmId, farm)
    notify('Redesenhe a nova area da fazenda.')
    local area = PolyZone.create()
    if not area then
        notify('Edicao cancelada.', 'error')
        return
    end

    local confirm = lib.alertDialog({
        header   = 'Confirmar nova area',
        content  = ('Fazenda: **%s**\nNova area com %d pontos. Confirmar?'):format(
            farm.name or farmId, #area.points),
        centered = true,
        cancel   = true,
    })
    if confirm ~= 'confirm' then
        notify('Edicao cancelada.', 'error')
        return
    end

    TriggerServerEvent('rodz-fazenda:server:updateFarmArea', farmId, area)
end

local function editFarmNpc(farmId)
    notify('Reposicione o NPC fazendeiro.')
    local npcCoords = Preview.placePed('a_m_m_farmer_01', 'NPC Fazendeiro')
    if not npcCoords then
        notify('Edicao cancelada.', 'error')
        return
    end

    TriggerServerEvent('rodz-fazenda:server:updateFarmNpc', farmId, {
        x = npcCoords.x, y = npcCoords.y, z = npcCoords.z, w = npcCoords.w,
    })
end

local function renameFarm(farmId, farm)
    local input = lib.inputDialog('Renomear Fazenda', {
        { type = 'input', label = 'Novo nome', placeholder = farm.name or farmId, required = true },
    })
    if not input or not input[1] or input[1] == '' then return end
    TriggerServerEvent('rodz-fazenda:server:renameFarm', farmId, input[1])
end

local function openCorralDetailAdmin(farmId, corral)
    lib.registerContext({
        id      = 'rfz_corral_admin_' .. farmId .. '_' .. corral.id,
        title   = ('Curral %s'):format(corral.id),
        menu    = 'rfz_corral_admin_' .. farmId,
        options = {
            {
                title       = 'Editar tamanho do curral',
                icon        = 'draw-polygon',
                description = 'Redesenhar a area do curral.',
                onSelect    = function()
                    lib.hideContext(true)
                    Wait(200)
                    editCorralArea(farmId, corral)
                end,
            },
            {
                title       = 'Editar vagas (capacidade)',
                icon        = 'hashtag',
                description = ('Capacidade atual: %d animal(is).'):format(#(corral.spawn_points or {})),
                onSelect    = function()
                    lib.hideContext(true)
                    Wait(200)
                    editCorralCapacity(farmId, corral)
                end,
            },
            {
                title       = 'Editar comedouro',
                icon        = 'wheat-awn',
                description = corral.feed_zone and ('Racao armazenada: %d'):format(tonumber(corral.feed_stock) or 0) or 'Definir o comedouro.',
                onSelect    = function()
                    lib.hideContext(true)
                    Wait(200)
                    editCorralFeedZone(farmId, corral)
                end,
            },
            {
                title       = 'Editar bebedouro',
                icon        = 'glass-water',
                description = corral.water_zone and ('Agua armazenada: %d'):format(tonumber(corral.water_stock) or 0) or 'Definir o bebedouro.',
                onSelect    = function()
                    lib.hideContext(true)
                    Wait(200)
                    editCorralWaterZone(farmId, corral)
                end,
            },
            {
                title     = 'Deletar Curral',
                icon      = 'trash',
                iconColor = 'red',
                onSelect  = function()
                    local alert = lib.alertDialog({
                        header   = 'Deletar Curral',
                        content  = ('Deletar o curral %s?'):format(corral.id),
                        centered = true,
                        cancel   = true,
                    })
                    if alert == 'confirm' then
                        TriggerServerEvent('rodz-fazenda:server:deleteCorral', farmId, corral.id)
                        notify('Curral deletado.', 'success')
                        listFarms()
                    end
                end,
            },
        },
    })
    lib.showContext('rfz_corral_admin_' .. farmId .. '_' .. corral.id)
end

local function openCorralListAdmin(farmId, farm)
    local corrals = (Farms[farmId] and Farms[farmId].corrals) or farm.corrals or {}
    local options = {
        {
            title       = 'Criar Curral',
            icon        = 'plus',
            description = (#corrals) .. '/' .. Config.MaxCorrals .. ' currais',
            onSelect    = function()
                lib.hideContext(true)
                Wait(200)
                createCorral(farmId, farm)
            end,
        },
    }

    for _, corral in ipairs(corrals) do
        local c = corral
        options[#options + 1] = {
            title       = ('Curral %s'):format(c.id),
            icon        = c.type == 'cow' and 'cow' or 'piggybank',
            description = ('%s - %d vaga(s)'):format(
                c.type == 'cow' and 'Vacas' or 'Porcos', #(c.spawn_points or {})),
            onSelect    = function()
                openCorralDetailAdmin(farmId, c)
            end,
        }
    end

    lib.registerContext({
        id      = 'rfz_corral_admin_' .. farmId,
        title   = (farm.name or farmId) .. ' - Currais',
        menu    = 'rfz_farm_detail_' .. farmId,
        options = options,
    })
    lib.showContext('rfz_corral_admin_' .. farmId)
end

local function openFarmMenu(farmId, farm)
    local price    = tonumber(farm.price) or 0
    local owner    = farm.owner_citizenid
    local ownerStr = owner and ('CID: ' .. owner) or 'Sem dono'

    local options = {
        {
            title       = 'ID: ' .. farmId,
            icon        = 'tag',
            description = ('%d curral(is) | Dono: %s'):format(#(farm.corrals or {}), ownerStr),
            readOnly    = true,
        },
        {
            title       = 'Preço: $' .. price,
            icon        = 'dollar-sign',
            description = 'Clique para alterar o preço de venda.',
            onSelect    = function()
                local input = lib.inputDialog('Definir Preço', {
                    { type = 'number', label = 'Novo preço ($)', placeholder = tostring(price), required = true, min = 0 },
                })
                if not input or not input[1] then return end
                TriggerServerEvent('rodz-fazenda:server:updateFarmPrice', farmId, math.floor(tonumber(input[1]) or 0))
            end,
        },
        {
            title       = 'Abrir Tablet (Admin)',
            icon        = 'tablet-screen-button',
            description = 'Abrir o tablet desta fazenda como administrador.',
            onSelect    = function()
                TriggerEvent('rodz-fazenda:client:openFarmTabletAdmin', farmId)
            end,
        },
        {
            title       = 'Editar area da fazenda',
            icon        = 'draw-polygon',
            description = ('Area com %d pontos.'):format(#((farm.area or {}).points or {})),
            onSelect    = function()
                lib.hideContext(true)
                Wait(200)
                editFarmArea(farmId, farm)
            end,
        },
        {
            title       = 'Reposicionar NPC',
            icon        = 'person',
            description = 'Mover o fazendeiro para outro lugar.',
            onSelect    = function()
                lib.hideContext(true)
                Wait(200)
                editFarmNpc(farmId)
            end,
        },
        {
            title       = 'Gerenciar Currais',
            icon        = 'pen-ruler',
            description = ('%d curral(is) cadastrado(s).'):format(#(farm.corrals or {})),
            onSelect    = function()
                openCorralListAdmin(farmId, farm)
            end,
        },
        {
            title       = 'Renomear fazenda',
            icon        = 'pen',
            description = 'Alterar o nome exibido.',
            onSelect    = function()
                renameFarm(farmId, farm)
            end,
        },
        {
            title       = 'Remover dono',
            icon        = 'user-slash',
            description = owner and ('Remove o dono atual (%s).'):format(owner) or 'Sem dono para remover.',
            disabled    = not owner,
            onSelect    = function()
                local alert = lib.alertDialog({
                    header   = 'Remover dono',
                    content  = ('Remover o dono **%s** da fazenda **%s**?'):format(owner or '', farm.name or farmId),
                    centered = true,
                    cancel   = true,
                })
                if alert == 'confirm' then
                    TriggerServerEvent('rodz-fazenda:server:removeFarmOwner', farmId)
                    listFarms()
                end
            end,
        },
        {
            title     = 'Deletar Fazenda',
            icon      = 'trash',
            iconColor = 'red',
            onSelect  = function()
                local alert = lib.alertDialog({
                    header   = 'Deletar fazenda',
                    content  = ('Deletar "%s"? Esta acao nao pode ser desfeita.'):format(farm.name or farmId),
                    centered = true,
                    cancel   = true,
                })
                if alert == 'confirm' then
                    TriggerServerEvent('rodz-fazenda:server:deleteFarm', farmId)
                    listFarms()
                end
            end,
        },
    }

    lib.registerContext({
        id      = 'rfz_farm_detail_' .. farmId,
        title   = farm.name or farmId,
        menu    = 'rfz_farm_list',
        options = options,
    })
    lib.showContext('rfz_farm_detail_' .. farmId)
end

listFarms = function()
    local options = {
        {
            title    = 'Criar Nova Fazenda',
            icon     = 'plus',
            onSelect = createFarm,
        },
        {
            title       = 'Atualizar lista',
            icon        = 'arrows-rotate',
            description = 'Sincroniza os dados com o servidor.',
            onSelect    = function()
                TriggerServerEvent('rodz-fazenda:server:requestSync')
                Wait(300)
                listFarms()
            end,
        },
    }

    for id, farm in pairs(Farms or {}) do
        local fid = id
        local f = farm
        options[#options + 1] = {
            title       = farm.name or id,
            icon        = 'tractor',
            description = (#(farm.corrals or {})) .. ' curral(is) - ID: ' .. id,
            onSelect    = function() openFarmMenu(fid, f) end,
        }
    end

    lib.registerContext({
        id      = 'rfz_farm_list',
        title   = 'Gerenciar Fazendas',
        menu    = 'menu_admin',
        options = options,
    })
    lib.showContext('rfz_farm_list')
end

CreateThread(function()
    while GetResourceState('mri_Qbox') ~= 'started' do
        Wait(1000)
    end

    exports.mri_Qbox:AddItemToMenu('management', {
        title            = 'Fazendas',
        icon             = 'tractor',
        iconAnimation    = 'fade',
        description      = 'Criar e gerenciar fazendas',
        onSelectFunction = function()
            lib.registerContext({
                id      = 'rfz_fazendas_menu',
                title   = 'Fazendas',
                menu    = 'menu_admin',
                options = {
                    {
                        title       = 'Criar / Administrar Fazendas',
                        icon        = 'screwdriver-wrench',
                        description = 'Criar, deletar e configurar fazendas',
                        onSelect    = listFarms,
                    },
                    {
                        title       = 'Gerenciar Currais e Animais',
                        icon        = 'cow',
                        description = 'Gerenciar currais, animais e estoque',
                        onSelect    = function()
                            TriggerEvent('rodz-fazenda:client:openFarmManager')
                        end,
                    },
                },
            })
            lib.showContext('rfz_fazendas_menu')
        end,
    })
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    lib.hideTextUI()
    if activePreview.cursor and DoesEntityExist(activePreview.cursor) then
        DeleteEntity(activePreview.cursor)
    end
    if activePreview.list then
        for _, pv in ipairs(activePreview.list) do
            if DoesEntityExist(pv) then DeleteEntity(pv) end
        end
    end
    activePreview.cursor = nil
    activePreview.list = nil
end)
