Config = {}

-- ─── Geral ────────────────────────────────────────────────────────────────────

Config.Debug           = false
Config.CartelGang      = 'lafuente'
Config.TargetDistance  = 2.5
Config.MaxCorrals          = 4
Config.MaxAnimals          = 100
Config.MaxEmployees        = 10
Config.SalaryIntervalMinutes = 60   -- pagamento a cada 60 minutos

-- ─── Spawn fixo do caminhão ───────────────────────────────────────────────────

Config.TruckSpawn = { x = 1326.78, y = 1189.36, z = 107.76, w = 271.83 }

-- ─── Itens ────────────────────────────────────────────────────────────────────

Config.Items = {
    feed     = 'racao',
    medicine = 'remedio_animal',
    milk     = 'leite',
    water    = 'water_bucket',
}

Config.CorralSupply = {
    feedCapacityKg = 1000,
    waterCapacityLiters = 1000,
}

-- ─── Pagamentos ───────────────────────────────────────────────────────────────

Config.Payments = {
    account       = 'bank',
    cowBuy        = 5000,
    cowBuyDirtyItem = 'black_money',
    cowSellStart  = 3000,
    cowSellMax    = 8000,
    cowSellAgeStepHours = 24,
    cowSellAgeStepValue = 1000,
    cowSell       = 2200,
    pigBuy        = 800,
    pigSell       = 1200,
    milkSell      = 45,
    feedBuy       = 50,
    waterBuy      = 30,
    medicineBuy   = 150,
}

-- ─── Animais ──────────────────────────────────────────────────────────────────

Config.Animals = {
    cow = {
        model             = 'a_c_cow',
        pedType           = 28,
        hungerDecayPerHour = 8.0,
        thirstDecayPerHour = 9.0,
        healthDecayPerHour = 5.0,
        healthRegenPerHour = 1.5,
        criticalHunger    = 20,
        criticalThirst    = 20,
        milkCooldown      = 20,       -- minutos
        milkYield         = { min = 1, max = 3 },
        feedHungerGain    = 40.0,
        feedHealthGain    = 8.0,
        autoFeedHungerGain = 1.0,
        autoFeedHealthGain = 0.2,
        drinkThirstGain   = 45.0,
        drinkHealthGain   = 6.0,
        autoFeedThreshold = 99.0,
        autoDrinkThreshold = 65.0,
    },
    pig = {
        model             = 'a_c_pig',
        pedType           = 28,
        hungerDecayPerHour = 10.0,
        thirstDecayPerHour = 11.0,
        healthDecayPerHour = 4.0,
        healthRegenPerHour = 1.0,
        criticalHunger    = 18,
        criticalThirst    = 18,
        feedHungerGain    = 38.0,
        feedHealthGain    = 6.0,
        drinkThirstGain   = 42.0,
        drinkHealthGain   = 4.0,
        autoFeedThreshold = 65.0,
        autoDrinkThreshold = 65.0,
    },
}

Config.AnimalRoaming = {
    enabled = true,
    minRadius = 4.0,
    padding = 1.5,
    repathInterval = 15000,
    leashDistance = 6.0,
}

-- ─── Alimentação automática no comedouro (vacas) ─────────────────────────────
-- itemQtyPerCycle: quantidade de item consumida por ciclo
-- itemKgUnit: equivalência de peso por item (apenas informativo para facilitar ajuste)
Config.CowAutoFeed = {
    itemQtyPerCycle = 1, -- 1 saco por vaca por ciclo
    hungerGainPercentPerCycle = 5, -- +5% de fome por saco consumido
    itemKgUnit = 0.5, -- 1 item = 0.5kg
}

-- ─── Caminhão ─────────────────────────────────────────────────────────────────

Config.Truck = {
    vehicle          = 'benson',
    driver           = 's_m_m_trucker_01',
    speed            = 16.0,
    speedLeaving     = 22.0,  -- velocidade ao partir após carregamento
    -- driveStyle: StopForVehicles(1) + StopForPeds(2) + SwerveAroundAllCars(32)
    --             + SwerveAroundCarsOdd(128) + AvoidHighways(512) = 675
    -- Remove: NoPathFinding(16), GoIntoOncomingTraffic(8), IgnorePathing(256)
    driveStyle       = 675,
    maxAnimalsPerRun = 10,
    cancelFee        = 1500,
    spawnDistance    = 60.0,
    arrivalDistance  = 4.0,
    arrivalTimeout   = 120000,  -- ms
    loadDuration     = 12000,   -- ms
    cooldown         = 900,     -- segundos
    despawnDelay     = 30000,   -- ms após entrega
}

-- ─── Ações (progressbar) ──────────────────────────────────────────────────────

Config.Actions = {
    feedAnimal = {
        duration = 5000,
        label    = 'Alimentando animal...',
        anim     = { dict = 'amb@world_human_gardener_plant@male@base', clip = 'base' },
    },
    milkCow = {
        duration = 8000,
        label    = 'Ordenhando vaca...',
        anim     = { dict = 'amb@medic@standing@kneel@base', clip = 'base' },
    },
    useMedicine = {
        duration = 4000,
        label    = 'Medicando animal...',
        anim     = { dict = 'amb@world_human_gardener_plant@male@base', clip = 'base' },
    },
    loadTruck = {
        duration = 12000,
        label    = 'Carregando caminhão...',
        anim     = { dict = 'amb@world_human_clipboard@male@idle_a', clip = 'idle_c' },
    },
}

-- ─── Segurança ────────────────────────────────────────────────────────────────

Config.Security = {
    actionDistance       = 4.0,
    saleDistance         = 8.0,
    actionTimeoutSeconds = 120,
}
