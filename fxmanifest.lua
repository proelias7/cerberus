fx_version 'adamant'
game "gta5"
lua54 'yes'

dependencies {
    "oxmysql"
}

author 'proelias7 by QUANTIC STORE'
description 'Sistema de detecção de exploits'
version '2.1'

client_scripts {
    "src/core/client/main.lua",
}

server_scripts {
    "@vrp/lib/utils.lua",
    "src/function/main.lua",
    "src/core/server/*",
}