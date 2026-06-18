-- ─── Utilitários globais — carregados antes de todos os outros server scripts ──

function RandId(len)
    local chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    local id    = ''
    for _ = 1, (len or 6) do
        local i = math.random(1, #chars)
        id      = id .. chars:sub(i, i)
    end
    return id
end

function Dbg(module, ...)
    if Config and Config.Debug then
        print(('[rodz-fazenda][%s]'):format(module), ...)
    end
end

function Now()
    return os.time()
end

function Clamp(val, minVal, maxVal)
    if val < minVal then return minVal end
    if val > maxVal then return maxVal end
    return val
end

function RoundN(n, decimals)
    local mult = 10 ^ (decimals or 0)
    return math.floor(n * mult + 0.5) / mult
end

function IsAdmin(src)
    return IsPlayerAceAllowed(src, 'command') or IsPlayerAceAllowed(src, 'admin')
end

function IsFarmOwner(src, farmId)
    local cid  = GetCitizenId(src)
    local farm = Farms and Farms[farmId]
    return cid ~= nil and farm ~= nil and farm.owner_citizenid == cid
end

function IsCartel(src)
    local player = exports.qbx_core:GetPlayer(src)
    if not player then return false end
    local gang = player.PlayerData.gang
    return gang and gang.name == Config.CartelGang
end

function IsCartelBoss(src)
    local player = exports.qbx_core:GetPlayer(src)
    if not player then return false end

    local gang = player.PlayerData.gang
    if not gang or gang.name ~= Config.CartelGang then
        return false
    end

    return gang.isboss == true or gang.isBoss == true or gang.grade and gang.grade.level == 4
end

function IsLafuente(src)
    local player = exports.qbx_core:GetPlayer(src)
    if not player then return false end
    local gang = player.PlayerData.gang
    if not gang or gang.name ~= Config.CartelGang then return false end
    return gang.grade and gang.grade.level >= 0
end

function GetQPlayer(src)
    return exports.qbx_core:GetPlayer(src)
end

function GetCitizenId(src)
    local player = GetQPlayer(src)
    return player and player.PlayerData.citizenid or nil
end

function AddMoney(src, amount, reason)
    local player = GetQPlayer(src)
    if not player or amount <= 0 then return false end
    player.Functions.AddMoney(Config.Payments.account, amount, reason or 'rodz-fazenda')
    return true
end

function RemoveMoney(src, amount, reason)
    local player = GetQPlayer(src)
    if not player then return false end
    return player.Functions.RemoveMoney(Config.Payments.account, amount, reason or 'rodz-fazenda')
end

function HasItem(src, itemName, qty)
    if GetResourceState('ox_inventory') == 'started' then
        local ok, count = pcall(function()
            return exports.ox_inventory:Search(src, 'count', itemName)
        end)
        if ok then
            return (tonumber(count) or 0) >= (qty or 1)
        end
    end

    local player = GetQPlayer(src)
    if not player then return false end
    local count = 0
    for _, item in pairs(player.PlayerData.items or {}) do
        if item and item.name == itemName then
            count = count + (item.amount or 0)
        end
    end
    return count >= (qty or 1)
end

function GiveItem(src, itemName, qty)
    if (qty or 0) <= 0 then return true end
    if GetResourceState('ox_inventory') == 'started' then
        local ok, res = pcall(function()
            return exports.ox_inventory:AddItem(src, itemName, qty)
        end)
        if ok and res ~= false then return true end
    end
    if GetResourceState('qb-inventory') == 'started' then
        local ok, res = pcall(function()
            return exports['qb-inventory']:AddItem(src, itemName, qty, false, nil, 'rodz-fazenda')
        end)
        if ok and res ~= false then return true end
    end
    local player = GetQPlayer(src)
    return player and player.Functions.AddItem(itemName, qty) ~= false
end

function TakeItem(src, itemName, qty)
    if (qty or 0) <= 0 then return true end
    if GetResourceState('ox_inventory') == 'started' then
        local ok, res = pcall(function()
            return exports.ox_inventory:RemoveItem(src, itemName, qty)
        end)
        if ok and res ~= false then return true end
    end
    if GetResourceState('qb-inventory') == 'started' then
        local ok, res = pcall(function()
            return exports['qb-inventory']:RemoveItem(src, itemName, qty, false, nil, 'rodz-fazenda')
        end)
        if ok and res ~= false then return true end
    end
    local player = GetQPlayer(src)
    return player and player.Functions.RemoveItem(itemName, qty) ~= false
end

function Notify(src, description, notifyType, title)
    if not src or src <= 0 then return end

    TriggerClientEvent('ox_lib:notify', src, {
        title = title or 'Fazenda',
        description = description,
        type = notifyType or 'inform',
    })
end

function GetPlayerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

function WithinDistance(src, coords, dist)
    local pc = GetPlayerCoords(src)
    if not pc then return false end
    return #(pc - vec3(coords.x, coords.y, coords.z)) <= dist
end

function GetSourceByCitizenId(citizenid)
    if not citizenid then return nil end
    for _, src in ipairs(GetPlayers()) do
        local s = tonumber(src)
        if s and GetCitizenId(s) == citizenid then return s end
    end
    return nil
end

function GetAnimalAgeDays(bornAt)
    local ageSeconds = math.max(0, Now() - (tonumber(bornAt) or 0))
    return math.floor(ageSeconds / 86400)
end

function GetAnimalSalePrice(animalType, bornAt)
    if animalType == 'cow' then
        local startPrice = tonumber(Config.Payments.cowSellStart) or 3000
        local maxPrice   = tonumber(Config.Payments.cowSellMax)   or 8000
        local stepHours  = math.max(1, math.floor(tonumber(Config.Payments.cowSellAgeStepHours) or 24))
        local stepValue  = math.max(1, math.floor(tonumber(Config.Payments.cowSellAgeStepValue) or 1000))
        local ageSeconds = math.max(0, Now() - (tonumber(bornAt) or 0))
        local steps      = math.floor(ageSeconds / (stepHours * 3600))
        local price      = math.min(maxPrice, startPrice + (steps * stepValue))
        return math.floor(price), math.floor(ageSeconds / 86400)
    end

    local basePrice   = Config.Payments.pigSell or 0
    local ageDays     = GetAnimalAgeDays(bornAt)
    local bonusSteps  = math.min(ageDays, 10)
    local multiplier  = 1.0 + (bonusSteps * 0.05)
    return math.floor(basePrice * multiplier + 0.5), ageDays
end
