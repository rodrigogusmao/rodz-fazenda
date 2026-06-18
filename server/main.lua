-- ─── Main server — criação das tabelas SQL (carregado primeiro) ───────────────

local function createTables()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `rfz_farms` (
            `id`          VARCHAR(20)  NOT NULL,
            `name`        VARCHAR(100) NOT NULL,
            `area`        LONGTEXT     NOT NULL,
            `npc_coords`  LONGTEXT     NOT NULL,
            `truck_point` LONGTEXT     NOT NULL,
            `created_by`  VARCHAR(50)  NOT NULL,
            `created_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `rfz_corrals` (
            `id`           VARCHAR(30)       NOT NULL,
            `farm_id`      VARCHAR(20)       NOT NULL,
            `type`         ENUM('cow','pig') NOT NULL,
            `area`         LONGTEXT          NOT NULL,
            `spawn_points` LONGTEXT          NOT NULL,
            `feed_zone`    LONGTEXT          NULL,
            `water_zone`   LONGTEXT          NULL,
            `feed_stock`   INT               NOT NULL DEFAULT 0,
            `water_stock`  INT               NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`),
            FOREIGN KEY (`farm_id`) REFERENCES `rfz_farms`(`id`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `rfz_inventory` (
            `farm_id`  VARCHAR(20) NOT NULL,
            `cows`     INT         NOT NULL DEFAULT 0,
            `pigs`     INT         NOT NULL DEFAULT 0,
            `feed`     INT         NOT NULL DEFAULT 0,
            `medicine` INT         NOT NULL DEFAULT 0,
            `milk`     INT         NOT NULL DEFAULT 0,
            PRIMARY KEY (`farm_id`),
            FOREIGN KEY (`farm_id`) REFERENCES `rfz_farms`(`id`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `rfz_animals` (
            `id`          VARCHAR(60)       NOT NULL,
            `farm_id`     VARCHAR(20)       NOT NULL,
            `corral_id`   VARCHAR(30)       NOT NULL,
            `slot`        INT               NOT NULL DEFAULT 0,
            `type`        ENUM('cow','pig') NOT NULL,
            `hunger`      FLOAT             NOT NULL DEFAULT 100.0,
            `thirst`      FLOAT             NOT NULL DEFAULT 100.0,
            `health`      FLOAT             NOT NULL DEFAULT 100.0,
            `last_fed`    INT               NOT NULL DEFAULT 0,
            `last_drank`  INT               NOT NULL DEFAULT 0,
            `last_milked` INT               NOT NULL DEFAULT 0,
            `born_at`     INT               NOT NULL DEFAULT 0,
            `active`      TINYINT(1)        NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`),
            FOREIGN KEY (`farm_id`)   REFERENCES `rfz_farms`(`id`)   ON DELETE CASCADE,
            FOREIGN KEY (`corral_id`) REFERENCES `rfz_corrals`(`id`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    pcall(function() MySQL.query.await('ALTER TABLE `rfz_corrals` ADD COLUMN `feed_zone` LONGTEXT NULL') end)
    pcall(function() MySQL.query.await('ALTER TABLE `rfz_corrals` ADD COLUMN `water_zone` LONGTEXT NULL') end)
    pcall(function() MySQL.query.await('ALTER TABLE `rfz_corrals` ADD COLUMN `feed_stock` INT NOT NULL DEFAULT 0') end)
    pcall(function() MySQL.query.await('ALTER TABLE `rfz_corrals` ADD COLUMN `water_stock` INT NOT NULL DEFAULT 0') end)
    pcall(function() MySQL.query.await('ALTER TABLE `rfz_animals` ADD COLUMN `thirst` FLOAT NOT NULL DEFAULT 100.0') end)
    pcall(function() MySQL.query.await('ALTER TABLE `rfz_animals` ADD COLUMN `last_drank` INT NOT NULL DEFAULT 0') end)
    -- Sistema de propriedade
    pcall(function() MySQL.query.await('ALTER TABLE `rfz_farms` ADD COLUMN `price` INT NOT NULL DEFAULT 0') end)
    pcall(function() MySQL.query.await('ALTER TABLE `rfz_farms` ADD COLUMN `owner_citizenid` VARCHAR(50) NULL DEFAULT NULL') end)
    pcall(function() MySQL.query.await('ALTER TABLE `rfz_farms` ADD COLUMN `sale_price` INT NULL DEFAULT NULL') end)
    -- Funcionários
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `rfz_employees` (
            `id`          INT AUTO_INCREMENT PRIMARY KEY,
            `farm_id`     VARCHAR(20)  NOT NULL,
            `citizenid`   VARCHAR(50)  NOT NULL,
            `name`        VARCHAR(100) DEFAULT NULL,
            `role`        VARCHAR(50)  NOT NULL DEFAULT 'ajudante',
            `salary`      INT          NOT NULL DEFAULT 0,
            `hired_at`    INT          NOT NULL DEFAULT 0,
            UNIQUE KEY `uniq_farm_emp` (`farm_id`, `citizenid`),
            KEY `idx_farm_id` (`farm_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    print('^2[rodz-fazenda]^7 Tabelas rfz_* verificadas/criadas.')
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    createTables()
    TriggerEvent('rodz-fazenda:server:ready')
end)
