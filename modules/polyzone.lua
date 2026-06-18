local PolyZone = {}

-- ─── Raycast ──────────────────────────────────────────────────────────────────

local function rotationToDirection(rot)
    local rx = math.rad(rot.x)
    local rz = math.rad(rot.z)
    return vec3(-math.sin(rz) * math.cos(rx), math.cos(rz) * math.cos(rx), math.sin(rx))
end

local function getGroundHit(dist)
    local camPos = GetGameplayCamCoords()
    local dir    = rotationToDirection(GetGameplayCamRot(2))
    local dest   = camPos + dir * (dist or 100.0)
    local ray    = StartShapeTestRay(
        camPos.x, camPos.y, camPos.z,
        dest.x,   dest.y,   dest.z,
        1, cache.ped, 0
    )
    local _, hit, coords = GetShapeTestResult(ray)
    return hit and coords or nil
end

-- ─── UI helpers ───────────────────────────────────────────────────────────────

local UI_STYLE = {
    borderRadius = 5,
    padding      = '10px 14px',
    width        = '290px',
    maxWidth     = '290px',
    lineHeight   = 1.4,
    textAlign    = 'left',
    fontSize     = '13px',
}

local function showPolyUI(ptCount, thickness)
    lib.showTextUI(table.concat({
        'Definir Área',
        '',
        '[Clique Esq]   adicionar ponto',
        '[Clique Dir]   remover último',
        '[Scroll]       altura: ' .. ('%.1fm'):format(thickness),
        '[Enter]        confirmar (' .. ptCount .. ' pts)',
        '[X]            cancelar',
    }, '\n'), { position = 'right-center', icon = '', style = UI_STYLE })
end

local function showPointUI(title, heading)
    lib.showTextUI(table.concat({
        title or 'Definir Ponto',
        '',
        '[Clique Esq / Enter]  confirmar',
        '[Seta Esq / Dir]      girar',
        '[X]                   cancelar',
        '',
        ('Rotação: %.0f°'):format(heading),
    }, '\n'), { position = 'right-center', icon = '', style = UI_STYLE })
end

-- ─── Draw helpers ─────────────────────────────────────────────────────────────

local function drawSphere(x, y, z, size, r, g, b, a)
    DrawMarker(28, x, y, z + size, 0,0,0, 0,0,0, size, size, size,
        r, g, b, a, false, false, 2, false, nil, nil, false)
end

local function drawWall(ax, ay, az, bx, by, bz, wallH, r, g, b, a)
    local atz, btz = az + wallH, bz + wallH
    -- front face (2 triangles)
    DrawPoly(ax, ay, az,  ax, ay, atz, bx, by, btz, r, g, b, a)
    DrawPoly(ax, ay, az,  bx, by, btz, bx, by, bz,  r, g, b, a)
    -- back face
    DrawPoly(ax, ay, atz, ax, ay, az,  bx, by, btz, r, g, b, a)
    DrawPoly(bx, by, btz, ax, ay, az,  bx, by, bz,  r, g, b, a)
end

local function drawPolyPreview(pts, cursor, wallH)
    -- cursor: small red sphere
    if cursor then
        drawSphere(cursor.x, cursor.y, cursor.z, 0.22, 220, 20, 20, 255)
    end

    for i, pt in ipairs(pts) do
        -- confirmed point sphere
        drawSphere(pt.x, pt.y, pt.z, 0.22, 220, 20, 20, 255)

        -- wall to next confirmed point
        local nxt = pts[i + 1] or (cursor and pt == pts[#pts] and cursor or nil)
        if nxt then
            drawWall(pt.x, pt.y, pt.z, nxt.x, nxt.y, nxt.z, wallH, 200, 20, 20, 130)
        end
    end

    -- closing wall: cursor → first point (preview)
    if cursor and #pts >= 3 then
        local f = pts[1]
        drawWall(cursor.x, cursor.y, cursor.z, f.x, f.y, f.z, wallH, 220, 80, 20, 80)
    end
end

local function drawPointPreview(pos, heading)
    if not pos then return end
    drawSphere(pos.x, pos.y, pos.z, 0.25, 220, 20, 20, 255)
    -- direction arrow
    local rad = math.rad(heading)
    local ax  = pos.x - math.sin(rad) * 1.2
    local ay  = pos.y + math.cos(rad) * 1.2
    DrawLine(pos.x, pos.y, pos.z + 0.3, ax, ay, pos.z + 0.3, 255, 255, 255, 200)
end

-- ─── PolyZone.create (raycast) ────────────────────────────────────────────────

local zoneActive = false

function PolyZone.create()
    if zoneActive then return nil end
    zoneActive = true

    local pts       = {}
    local thickness = 6.0
    local cursor    = nil
    local result    = nil

    showPolyUI(#pts, thickness)

    local p = promise.new()

    CreateThread(function()
        while zoneActive do
            Wait(0)

            cursor = getGroundHit(100.0)
            drawPolyPreview(pts, cursor, thickness)

            -- Disable attack / aim to free left/right click for our use
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 16, true)
            DisableControlAction(0, 17, true)
            DisableControlAction(0, 73, true)

            if IsDisabledControlJustPressed(0, 24) and cursor then
                -- Left click → add point
                pts[#pts + 1] = cursor
                showPolyUI(#pts, thickness)

            elseif IsDisabledControlJustPressed(0, 25) and #pts > 0 then
                -- Right click → remove last
                pts[#pts] = nil
                showPolyUI(#pts, thickness)

            elseif IsDisabledControlJustReleased(0, 17) then
                -- Scroll up → more height
                thickness = math.min(thickness + 0.5, 30.0)
                showPolyUI(#pts, thickness)

            elseif IsDisabledControlJustReleased(0, 16) then
                -- Scroll down → less height
                thickness = math.max(thickness - 0.5, 1.0)
                showPolyUI(#pts, thickness)

            elseif IsControlJustReleased(0, 201) then
                -- Enter → confirm
                if #pts >= 3 then
                    result = { points = pts, thickness = thickness }
                    zoneActive = false
                else
                    lib.notify({ title = 'Fazenda', description = 'Mínimo de 3 pontos para confirmar.', type = 'error' })
                end

            elseif IsDisabledControlJustPressed(0, 73) then
                -- X → cancel
                zoneActive = false
            end
        end

        lib.hideTextUI()
        p:resolve(result)
    end)

    return Citizen.Await(p)
end

-- ─── PolyZone.createPoint (raycast) ───────────────────────────────────────────

function PolyZone.createPoint(title)
    if zoneActive then return nil end
    zoneActive = true

    local cursor  = nil
    local lastPos = GetEntityCoords(cache.ped)
    local heading = GetEntityHeading(cache.ped)
    local result  = nil

    showPointUI(title, heading)

    local p = promise.new()

    CreateThread(function()
        while zoneActive do
            Wait(0)

            local hit = getGroundHit(50.0)
            if hit then
                cursor  = hit
                lastPos = hit
            end

            drawPointPreview(cursor or lastPos, heading)

            DisableControlAction(0, 24,  true)  -- left click
            DisableControlAction(0, 174, true)  -- arrow left
            DisableControlAction(0, 175, true)  -- arrow right
            DisableControlAction(0, 73,  true)  -- X

            if IsDisabledControlPressed(0, 174) then
                heading = (heading + 1.5) % 360
                showPointUI(title, heading)
            elseif IsDisabledControlPressed(0, 175) then
                heading = (heading - 1.5 + 360) % 360
                showPointUI(title, heading)
            end

            local pos = cursor or lastPos
            if IsDisabledControlJustPressed(0, 24) and pos then
                -- Left click → confirm
                result = { x = pos.x, y = pos.y, z = pos.z, w = heading }
                zoneActive = false
            elseif IsControlJustReleased(0, 201) and pos then
                -- Enter → confirm
                result = { x = pos.x, y = pos.y, z = pos.z, w = heading }
                zoneActive = false
            elseif IsDisabledControlJustPressed(0, 73) then
                -- X → cancel
                zoneActive = false
            end
        end

        lib.hideTextUI()
        p:resolve(result)
    end)

    return Citizen.Await(p)
end

-- ─── PolyZone.createBox (legado — mantido para compatibilidade) ───────────────

local freecam = exports['fivem-freecam']

local xCoord, yCoord, zCoord = 0, 0, 0

local function getRelativePos(origin, point, theta)
    if theta == 0.0 then return point.x, point.y end
    local p = point - origin
    theta = math.rad(theta)
    local cosT, sinT = math.cos(theta), math.sin(theta)
    return math.floor(((p.x * cosT - p.y * sinT) + origin.x) * 100 + 0.0) / 100,
           math.floor(((p.x * sinT + p.y * cosT) + origin.y) * 100 + 0.0) / 100
end

local minCheck = 0.025

function PolyZone.createBox(title, onDone)
    if zoneActive then return nil end
    zoneActive = true

    local moveStep = 0.05
    local coords   = GetEntityCoords(cache.ped)
    local hdg      = GetEntityHeading(cache.ped)
    local width    = 1.8
    local length   = 1.8
    local boxH     = 2.0

    xCoord = math.floor(coords.x + 0.5) + 0.0
    yCoord = math.floor(coords.y + 0.5) + 0.0
    zCoord = math.floor(coords.z + 0.5) + 0.0

    local function showBoxUI()
        lib.showTextUI(table.concat({
            title or 'Zona Box',
            '[Setas] mover | [Scroll] precisão | [R/F] Z',
            '[Q/E] girar | [Shift+Setas] tamanho | [G/H] altura',
            '[Enter] confirmar | [ESC] cancelar',
            ('Pos: %.1f, %.1f, %.1f | %.0f°'):format(xCoord, yCoord, zCoord, hdg),
            ('W: %.1f  L: %.1f  H: %.1f  Step: %.2f'):format(width, length, boxH, moveStep),
        }, '\n'), { position = 'right-center', icon = '', style = UI_STYLE })
    end

    showBoxUI()

    local p = promise.new()

    CreateThread(function()
        while zoneActive do
            Wait(0)
            freecam:SetActive(true)

            DrawMarker(1, xCoord, yCoord, zCoord - (boxH / 2), 0,0,0, 0,0,hdg,
                width, length, boxH, 240, 229, 5, 95, false, false, 2, false, nil, nil, false)

            DisableAllControlActions(0)
            EnableControlAction(0, 1, true)
            EnableControlAction(0, 2, true)
            EnableControlAction(0, 245, true)

            local changed = false
            if IsDisabledControlJustReleased(0, 17) then
                moveStep = moveStep + 0.05; changed = true
            elseif IsDisabledControlJustReleased(0, 16) then
                moveStep = math.max(0.02, moveStep - 0.05); changed = true
            elseif IsDisabledControlPressed(0, 188) then
                if IsDisabledControlPressed(0, 21) then length = length + moveStep
                else local nx, ny = getRelativePos(vec2(xCoord, yCoord), vec2(xCoord, yCoord + moveStep), freecam:GetRotation(2).z)
                    xCoord = math.abs(nx) < minCheck and 0.0 or nx
                    yCoord = math.abs(ny or 0.0) < minCheck and 0.0 or ny
                end; changed = true
            elseif IsDisabledControlPressed(0, 187) then
                if IsDisabledControlPressed(0, 21) then length = math.max(0.5, length - moveStep)
                else local nx, ny = getRelativePos(vec2(xCoord, yCoord), vec2(xCoord, yCoord - moveStep), freecam:GetRotation(2).z)
                    xCoord = math.abs(nx) < minCheck and 0.0 or nx
                    yCoord = math.abs(ny or 0.0) < minCheck and 0.0 or ny
                end; changed = true
            elseif IsDisabledControlPressed(0, 190) then
                if IsDisabledControlPressed(0, 21) then width = width + moveStep
                else local nx, ny = getRelativePos(vec2(xCoord, yCoord), vec2(xCoord + moveStep, yCoord), freecam:GetRotation(2).z)
                    xCoord = math.abs(nx) < minCheck and 0.0 or nx
                    yCoord = math.abs(ny or 0.0) < minCheck and 0.0 or ny
                end; changed = true
            elseif IsDisabledControlPressed(0, 189) then
                if IsDisabledControlPressed(0, 21) then width = math.max(0.5, width - moveStep)
                else local nx, ny = getRelativePos(vec2(xCoord, yCoord), vec2(xCoord - moveStep, yCoord), freecam:GetRotation(2).z)
                    xCoord = math.abs(nx) < minCheck and 0.0 or nx
                    yCoord = math.abs(ny or 0.0) < minCheck and 0.0 or ny
                end; changed = true
            elseif IsDisabledControlJustReleased(0, 45) then zCoord = zCoord + moveStep; changed = true
            elseif IsDisabledControlJustReleased(0, 23) then zCoord = zCoord - moveStep; changed = true
            elseif IsDisabledControlJustReleased(0, 44) then hdg = (hdg + 5.0) % 360; changed = true
            elseif IsDisabledControlJustReleased(0, 38) then hdg = (hdg - 5.0 + 360) % 360; changed = true
            elseif IsDisabledControlJustReleased(0, 47) then boxH = boxH + moveStep; changed = true
            elseif IsDisabledControlJustReleased(0, 74) then boxH = math.max(0.5, boxH - moveStep); changed = true
            elseif IsDisabledControlJustReleased(0, 201) then
                freecam:SetActive(false); lib.hideTextUI(); zoneActive = false
                local res = { x = xCoord, y = yCoord, z = zCoord, w = hdg, width = width, length = length, height = boxH }
                if onDone then onDone(res) end
                p:resolve(res); return
            elseif IsDisabledControlJustReleased(0, 200) then
                SetPauseMenuActive(false); freecam:SetActive(false); lib.hideTextUI(); zoneActive = false
                if onDone then onDone(nil) end
                p:resolve(nil); return
            end

            if changed then showBoxUI() end
        end
        freecam:SetActive(false)
        lib.hideTextUI()
        if onDone then onDone(nil) end
        p:resolve(nil)
    end)

    return Citizen.Await(p)
end

return PolyZone
