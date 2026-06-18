local Preview = {}

local busy = false

-- ─── Raycast ──────────────────────────────────────────────────────────────────

local function rotationToDirection(rot)
    local rx = math.rad(rot.x)
    local rz = math.rad(rot.z)
    return vec3(-math.sin(rz) * math.cos(rx), math.cos(rz) * math.cos(rx), math.sin(rx))
end

local function refineGroundZ(x, y, fallbackZ)
    local ok, gz = GetGroundZFor_3dCoord(x, y, fallbackZ + 5.0, false)
    if ok then return gz end
    ok, gz = GetGroundZFor_3dCoord(x, y, fallbackZ + 50.0, false)
    if ok then return gz end
    return fallbackZ
end

local function getGroundHit(ignoreEnt)
    local camPos = GetGameplayCamCoords()
    local dir    = rotationToDirection(GetGameplayCamRot(2))
    local dest   = camPos + dir * 50.0
    local ray    = StartShapeTestRay(
        camPos.x, camPos.y, camPos.z,
        dest.x,   dest.y,   dest.z,
        1, ignoreEnt or cache.ped, 0
    )
    local _, hit, coords = GetShapeTestResult(ray)
    if not hit then return nil end
    return vec3(coords.x, coords.y, coords.z)
end

-- ─── UI ───────────────────────────────────────────────────────────────────────

local function showUI(label, heading)
    local lines = {
        label or 'Posicionamento',
        '',
        '[Clique Esq / Enter]   confirmar',
        '[Seta Esq / Dir]       girar',
        '[X]                    cancelar',
    }
    if heading then
        lines[#lines + 1] = ''
        lines[#lines + 1] = ('Rotação: %.0f°'):format(heading)
    end
    lib.showTextUI(table.concat(lines, '\n'), {
        position = 'right-center',
        icon = '',
        style = {
            borderRadius = 6,
            padding = '12px 14px',
            width = '310px',
            maxWidth = '310px',
            lineHeight = 1.4,
            textAlign = 'left',
        },
    })
end

-- ─── Model loading ────────────────────────────────────────────────────────────

local function requestModel(hash)
    if not hash or hash == 0 then return false end
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return false end
    local ok = pcall(function() lib.requestModel(hash, 10000) end)
    return ok
end

-- ─── Preview.placePed ────────────────────────────────────────────────────────

function Preview.placePed(model, label)
    if busy then return nil end
    busy = true

    local hash = type(model) == 'number' and model or joaat(model)
    if not requestModel(hash) then
        busy = false
        lib.notify({ title = 'Fazenda', description = 'Modelo de NPC inválido.', type = 'error' })
        return nil
    end

    local pc      = GetEntityCoords(cache.ped)
    local heading = GetEntityHeading(cache.ped)
    local lastPos = pc

    local ped = CreatePed(4, hash, pc.x, pc.y, pc.z, heading, false, false)
    SetEntityAlpha(ped, 180, false)
    SetEntityInvincible(ped, true)
    SetEntityCollision(ped, false, false)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)

    showUI(label or 'Posicionamento de NPC', heading)

    local p      = promise.new()
    local result = nil

    CreateThread(function()
        while busy do
            Wait(0)

            local hit = getGroundHit(cache.ped)
            if hit then lastPos = hit end

            FreezeEntityPosition(ped, false)
            SetEntityCoords(ped, lastPos.x, lastPos.y, lastPos.z, false, false, false, false)
            FreezeEntityPosition(ped, true)
            SetEntityHeading(ped, heading)

            DisableControlAction(0, 24,  true)  -- left click
            DisableControlAction(0, 174, true)  -- arrow left
            DisableControlAction(0, 175, true)  -- arrow right
            DisableControlAction(0, 73,  true)  -- X

            if IsDisabledControlPressed(0, 174) then
                heading = (heading + 1.5) % 360
                showUI(label or 'Posicionamento de NPC', heading)
            elseif IsDisabledControlPressed(0, 175) then
                heading = (heading - 1.5 + 360) % 360
                showUI(label or 'Posicionamento de NPC', heading)
            end

            if IsDisabledControlJustPressed(0, 24) then
                result = vec4(lastPos.x, lastPos.y, lastPos.z, heading)
                busy = false
            elseif IsControlJustReleased(0, 201) then
                result = vec4(lastPos.x, lastPos.y, lastPos.z, heading)
                busy = false
            elseif IsDisabledControlJustPressed(0, 73) then
                busy = false
            end
        end

        lib.hideTextUI()
        if DoesEntityExist(ped) then DeleteEntity(ped) end
        p:resolve(result)
    end)

    return Citizen.Await(p)
end

-- ─── Preview.placeVehicle ────────────────────────────────────────────────────

function Preview.placeVehicle(model, label)
    if busy then return nil end
    busy = true

    local hash = type(model) == 'number' and model or joaat(model)
    if not requestModel(hash) then
        busy = false
        lib.notify({ title = 'Fazenda', description = 'Modelo de veículo inválido.', type = 'error' })
        return nil
    end

    local pc      = GetEntityCoords(cache.ped)
    local heading = GetEntityHeading(cache.ped)
    local lastPos = pc

    local veh = CreateVehicle(hash, pc.x, pc.y, pc.z, heading, false, false)
    SetEntityAlpha(veh, 120, false)
    SetEntityInvincible(veh, true)
    SetEntityCollision(veh, false, false)
    FreezeEntityPosition(veh, true)
    SetVehicleDoorsLocked(veh, 2)

    showUI(label or 'Posicionamento de Veículo', heading)

    local p      = promise.new()
    local result = nil

    CreateThread(function()
        while busy do
            Wait(0)

            local hit = getGroundHit(cache.ped)
            if hit then lastPos = hit end

            FreezeEntityPosition(veh, false)
            SetEntityCoords(veh, lastPos.x, lastPos.y, lastPos.z, false, false, false, false)
            SetVehicleOnGroundProperly(veh)
            FreezeEntityPosition(veh, true)
            SetEntityHeading(veh, heading)

            DisableControlAction(0, 24,  true)
            DisableControlAction(0, 174, true)
            DisableControlAction(0, 175, true)
            DisableControlAction(0, 73,  true)

            if IsDisabledControlPressed(0, 174) then
                heading = (heading + 1.5) % 360
                showUI(label or 'Posicionamento de Veículo', heading)
            elseif IsDisabledControlPressed(0, 175) then
                heading = (heading - 1.5 + 360) % 360
                showUI(label or 'Posicionamento de Veículo', heading)
            end

            if IsDisabledControlJustPressed(0, 24) then
                result = vec4(lastPos.x, lastPos.y, lastPos.z, heading)
                busy = false
            elseif IsControlJustReleased(0, 201) then
                result = vec4(lastPos.x, lastPos.y, lastPos.z, heading)
                busy = false
            elseif IsDisabledControlJustPressed(0, 73) then
                busy = false
            end
        end

        lib.hideTextUI()
        if DoesEntityExist(veh) then DeleteEntity(veh) end
        p:resolve(result)
    end)

    return Citizen.Await(p)
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    busy = false
    lib.hideTextUI()
end)

return Preview
