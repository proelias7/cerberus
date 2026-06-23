local config = {
    webhook = "",
    defaultTime = 30, -- tempo padrão por requisição
    interPorDetect = 15, -- intervalo de tempo para contar uma suspeita
    suspectCount = 4, -- quantidade de suspeitas para banir
    blockThreshold = 1, -- quantas suspeitas antes de bloquear (retornar true)
    logThreshold = 1, -- quantas suspeitas antes de mostrar logs

    BlackListEvents = {
        "robberys:part1",
        "robberys:part2",
        "robberys:part3"
    },
}

config.modules = {
    banned = false,
    safeEvent = true,
    analytics = true,
}

return config