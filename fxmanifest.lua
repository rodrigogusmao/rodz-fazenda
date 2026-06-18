fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

description 'Sistema de Fazendas - rodz-fazenda'
author 'rodz'
version '1.0.0'

ui_page 'html/index.html'

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
    'config.lua',
}

client_scripts {
    'client/main.lua',
    'client/creator.lua',
    'client/manager.lua',
    'client/truck.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/utils.lua',
    'server/farms.lua',
    'server/animals.lua',
    'server/truck.lua',
}

files {
    'modules/polyzone.lua',
    'modules/preview.lua',
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

dependencies {
    'ox_lib',
    'ox_target',
    'oxmysql',
    'qbx_core',
    'fivem-freecam',
    'mri_Qbox',
}
