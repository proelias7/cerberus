if not config.modules.analytics then return end

local This = GetCurrentResourceName()

-- ============================================================================
-- CONFIGURAÇÕES DE MONITORAMENTO
-- ============================================================================
local CONFIG = {
    -- Payload
    PAYLOAD_WARNING_SIZE = 32000,      -- 32KB - aviso de payload grande
    PAYLOAD_CRITICAL_SIZE = 64000,     -- 64KB - crítico
    PAYLOAD_MAX_SIZE = 128000,         -- 128KB - muito grande
    
    -- Anti-flood (por segundo)
    FLOOD_WINDOW_MS = 1000,            -- Janela de tempo (1 segundo)
    FLOOD_WARNING_CALLS = 50,          -- Aviso de muitas chamadas
    FLOOD_CRITICAL_CALLS = 100,        -- Crítico
    FLOOD_MAX_CALLS = 200,             -- Máximo antes de considerar flood
    
    -- StateBag específico
    STATEBAG_WARNING_SIZE = 16000,     -- 16KB para statebags
    STATEBAG_CRITICAL_SIZE = 32000,    -- 32KB crítico
    
    -- Debug verbose (mostra TODOS os eventos)
    DEBUG_STATEBAG = false,            -- Debug verbose de StateBags
    DEBUG_EVENTS = false,              -- Debug verbose de Eventos
    
    -- Alertas de WARNING (payload moderado, frequência alta)
    WARN_STATEBAG = true,              -- Warnings de StateBags
    WARN_EVENTS = true,                -- Warnings de Eventos
    
    -- ALERTAS CRÍTICOS (flood, payload grande) = SEMPRE LIGADOS
    -- Não tem toggle, sempre mostra automaticamente
    
    LOG_INTERVAL = 5000,               -- Intervalo para logs periódicos (ms)
}

-- ============================================================================
-- ESTATÍSTICAS GLOBAIS
-- ============================================================================
local stats = {
    total_events = 0,
    total_bytes = 0,
    large_payloads = 0,
    floods_detected = 0,
    statebag_changes = 0,
    start_time = GetGameTimer(),
}

-- Rate limiting por source
local rate_limits = {}

-- ============================================================================
-- FUNÇÕES AUXILIARES
-- ============================================================================
local function formatBytes(bytes)
    if bytes >= 1048576 then
        return string.format("%.2f MB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.2f KB", bytes / 1024)
    end
    return string.format("%d bytes", bytes)
end

local function getTimer()
    return GetGameTimer()
end

-- ============================================================================
-- SISTEMA DE LOGGING COM CORES
-- ============================================================================
local function logDebug(msg, ...)
    -- Sempre imprime quando chamado (usado apenas quando DEBUG_STATEBAG ou DEBUG_EVENTS estão ativos)
    print(string.format("^5[DEBUG]^0 " .. msg, ...))
end

local function logInfo(msg, ...)
    print(string.format("^4[INFO]^0 " .. msg, ...))
end

local function logWarning(msg, ...)
    print(string.format("^3[AVISO]^0 " .. msg, ...))
end

local function logCritical(msg, ...)
    print(string.format("^1[CRITICO]^0 " .. msg, ...))
end

local function logFlood(msg, ...)
    print(string.format("^1[FLOOD]^0 " .. msg, ...))
end

-- ============================================================================
-- SISTEMA DE RATE LIMITING
-- ============================================================================
local function checkRateLimit(identifier, eventName)
    local now = getTimer()
    local key = tostring(identifier) .. ":" .. eventName
    local limit = rate_limits[key]
    
    if not limit then
        rate_limits[key] = {
            calls = 1,
            window_start = now,
            total_bytes = 0,
        }
        return "ok", 1
    end
    
    -- Nova janela
    if now - limit.window_start > CONFIG.FLOOD_WINDOW_MS then
        local old_calls = limit.calls
        limit.calls = 1
        limit.window_start = now
        limit.total_bytes = 0
        return "ok", 1
    end
    
    limit.calls = limit.calls + 1
    
    -- Verifica níveis
    if limit.calls >= CONFIG.FLOOD_MAX_CALLS then
        stats.floods_detected = stats.floods_detected + 1
        return "flood", limit.calls
    elseif limit.calls >= CONFIG.FLOOD_CRITICAL_CALLS then
        return "critical", limit.calls
    elseif limit.calls >= CONFIG.FLOOD_WARNING_CALLS then
        return "warning", limit.calls
    end
    
    return "ok", limit.calls
end

local function addBytesToLimit(identifier, eventName, bytes)
    local key = tostring(identifier) .. ":" .. eventName
    local limit = rate_limits[key]
    if limit then
        limit.total_bytes = (limit.total_bytes or 0) + bytes
    end
end

-- ============================================================================
-- API E ESTADO
-- ============================================================================
local API = {}
local Online = true

function get_scripts()
    local scripts = {}
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name ~= This then
            table.insert(scripts, name)
        end
    end
    return scripts
end

function API.install()
    ExecuteCommand('cerberus_install')
end

function API.uninstall()
    ExecuteCommand('cerberus_uninstall')
end

-- ============================================================================
-- DELEGATE PARA RECURSOS
-- ============================================================================
local function delegate(fn)
    return setmetatable({}, {
        __index = function(self, key)
            local v = fn(key)
            self[key] = v
            return v
        end
    })
end

local resources = delegate(function(key)
    return {
        name = key,
        bytes = 0,
        count = 0,
        actual_count = 0,
        global_count = 0,
        direct_count = 0,
        events = delegate(function() return { 0, 0 } end),
    }
end)

local function PlayerInfo(source)
    if not source then return "" end

    local Playerid = PlayerID(source)
    local PlayerName = GetPlayerName(source)
    return " | Player: "..PlayerName.." (ID: "..Playerid..")"
end

-- ============================================================================
-- MONITORAMENTO DE STATEBAGS
-- ============================================================================
AddStateBagChangeHandler(nil, nil, function(bag, key, value, _, replicated)
    if not Online then return end
    if not replicated then return end
    
    local size = msgpack.pack(value):len()
    local originalSize = size
    local script = resources.__statebag__
    local playersAffected = 1
    local bagType = "entity"
    local source = nil
    
    -- Identifica o tipo de bag e extrai source se for player
    if bag == 'global' then
        playersAffected = GetNumPlayerIndices()
        size = size * playersAffected
        bagType = "global"
        key = "global:" .. key
    elseif bag:match("^player:") then
        bagType = "player"
        source = tonumber(bag:match("^player:(%d+)"))
    elseif bag:match("^entity:") then
        bagType = "entity"
    end
    
    script.actual_count = script.actual_count + 1
    script.bytes = script.bytes + size
    stats.statebag_changes = stats.statebag_changes + 1
    stats.total_bytes = stats.total_bytes + size
    
    if bag == 'global' then
        script.global_count = script.global_count + 1
    end
    
    local old = script.events[key]
    old[1] = old[1] + 1
    old[2] = old[2] + size
    
    -- Verifica rate limit
    local status, calls = checkRateLimit(bag, key)
    addBytesToLimit(bag, key, size)
    
    -- ═══════════════════════════════════════════════════════════════
    -- ALERTAS CRÍTICOS - SEMPRE APARECEM AUTOMATICAMENTE
    -- ═══════════════════════════════════════════════════════════════
    
    -- FLOOD - sempre mostra
    if status == "flood" then
        stats.floods_detected = stats.floods_detected + 1
        logFlood("StateBag FLOOD detectado!\n" ..
            "  Bag: %s | Key: %s%s\n" ..
            "  Chamadas: %d em %dms (max: %d)\n" ..
            "  Tamanho: %s | Players afetados: %d",
            bag, key, PlayerInfo(source), calls, CONFIG.FLOOD_WINDOW_MS, 
            CONFIG.FLOOD_MAX_CALLS, formatBytes(originalSize), playersAffected)
    elseif status == "critical" then
        logCritical("StateBag com muitas chamadas!\n" ..
            "  Bag: %s | Key: %s%s\n" ..
            "  Chamadas: %d/%d em %dms",
            bag, key, PlayerInfo(source), calls, CONFIG.FLOOD_MAX_CALLS, CONFIG.FLOOD_WINDOW_MS)
        DropPlayer(source, "Você atingiu o limite de chamadas de StateBag!")
    end
    
    -- PAYLOAD GRANDE - sempre mostra
    if originalSize >= CONFIG.STATEBAG_CRITICAL_SIZE then
        stats.large_payloads = stats.large_payloads + 1
        logCritical("StateBag muito grande!\n" ..
            "  Bag: %s | Key: %s%s\n" ..
            "  Tamanho: %s | Total enviado: %s\n" ..
            "  Players afetados: %d",
            bag, key, PlayerInfo(source), formatBytes(originalSize), 
            formatBytes(size), playersAffected)
        DropPlayer(source, "Você atingiu o limite de tamanho de StateBag!")
    end
    
    -- ═══════════════════════════════════════════════════════════════
    -- WARNINGS - Apenas se ativado
    -- ═══════════════════════════════════════════════════════════════
    if CONFIG.WARN_STATEBAG then
        if status == "warning" then
            logWarning("StateBag frequente: %s:%s (%d chamadas)%s", bag, key, calls, PlayerInfo(source))
        end
        
        if originalSize >= CONFIG.STATEBAG_WARNING_SIZE and originalSize < CONFIG.STATEBAG_CRITICAL_SIZE then
            logWarning("StateBag grande: %s:%s | Tamanho: %s%s",
                bag, key, formatBytes(originalSize), PlayerInfo(source))
        end
    end
    
    -- ═══════════════════════════════════════════════════════════════
    -- DEBUG VERBOSE - mostra TODOS os eventos
    -- ═══════════════════════════════════════════════════════════════
    if CONFIG.DEBUG_STATEBAG then
        logDebug("[STATEBAG] %s | Key: %s | Size: %s | Type: %s",
            bag, key, formatBytes(originalSize), bagType)
    end
end)

-- ============================================================================
-- EXPORT HIT - MONITORAMENTO DE EVENTOS
-- ============================================================================
exports('hit', function(name, event, is_global, size)
    if not Online then return end
    
    local script = resources[name]
    local players = is_global and GetNumPlayerIndices() or 1
    local originalSize = size
    
    size = size * players
    
    if is_global then
        script.global_count = script.global_count + 1
    else
        script.direct_count = script.direct_count + 1
    end
    
    script.bytes = script.bytes + size
    script.count = script.count + players
    script.actual_count = script.actual_count + 1
    
    stats.total_events = stats.total_events + 1
    stats.total_bytes = stats.total_bytes + size
    
    local old = script.events[event]
    old[1] = old[1] + 1
    old[2] = old[2] + size
    
    -- Verifica rate limit
    local status, calls = checkRateLimit(name, event)
    addBytesToLimit(name, event, size)
    
    local globalInfo = is_global and " (GLOBAL)" or ""
    
    -- ═══════════════════════════════════════════════════════════════
    -- ALERTAS CRÍTICOS - SEMPRE APARECEM AUTOMATICAMENTE
    -- ═══════════════════════════════════════════════════════════════
    
    -- FLOOD - sempre mostra
    if status == "flood" then
        stats.floods_detected = stats.floods_detected + 1
        logFlood("Evento FLOOD detectado!\n" ..
            "  Script: %s | Evento: %s%s\n" ..
            "  Chamadas: %d em %dms (max: %d)\n" ..
            "  Tamanho: %s | Players: %d",
            name, event, globalInfo, calls, CONFIG.FLOOD_WINDOW_MS,
            CONFIG.FLOOD_MAX_CALLS, formatBytes(originalSize), players)
    elseif status == "critical" then
        logCritical("Evento com muitas chamadas!\n" ..
            "  Script: %s | Evento: %s%s\n" ..
            "  Chamadas: %d/%d em %dms",
            name, event, globalInfo, calls, CONFIG.FLOOD_MAX_CALLS, CONFIG.FLOOD_WINDOW_MS)
    end
    
    -- PAYLOAD GRANDE - sempre mostra
    if originalSize >= CONFIG.PAYLOAD_CRITICAL_SIZE then
        stats.large_payloads = stats.large_payloads + 1
        logCritical("Payload GRANDE detectado!\n" ..
            "  Script: %s | Evento: %s%s\n" ..
            "  Tamanho: %s | Total enviado: %s",
            name, event, globalInfo, formatBytes(originalSize), formatBytes(size))
    end
    
    -- ═══════════════════════════════════════════════════════════════
    -- WARNINGS - Apenas se ativado
    -- ═══════════════════════════════════════════════════════════════
    if CONFIG.WARN_EVENTS then
        if status == "warning" then
            logWarning("Evento frequente: %s:%s (%d chamadas)%s", name, event, calls, globalInfo)
        end
        
        if originalSize >= CONFIG.PAYLOAD_WARNING_SIZE and originalSize < CONFIG.PAYLOAD_CRITICAL_SIZE then
            logWarning("Payload moderado: %s:%s | Tamanho: %s%s",
                name, event, formatBytes(originalSize), globalInfo)
        end
    end
    
    -- ═══════════════════════════════════════════════════════════════
    -- DEBUG VERBOSE - mostra TODOS os eventos
    -- ═══════════════════════════════════════════════════════════════
    if CONFIG.DEBUG_EVENTS then
        logDebug("[EVENT] %s:%s | Size: %s | Global: %s | Players: %d",
            name, event, formatBytes(originalSize), tostring(is_global), players)
    end
end)

function API.dump()
    local scripts = {}

    for _, data in pairs(resources) do
        table.insert(scripts, data)
    end

    table.sort(scripts, function(a, b)
        return a.name < b.name
    end)

    SaveResourceFile(This, 'dumps/dump.json', json.encode(scripts, { pretty = true }), -1)
    logInfo("Dump salvo em dumps/dump.json")
end

function API.start()
    if not Online then
        Online = true
        logInfo('Sistema de monitoramento ^2ATIVADO^0')
    else
        logWarning('O sistema já está ligado')
    end
end

function API.stop()
    if Online then
        Online = false
        logInfo('Sistema de monitoramento ^1DESATIVADO^0')
    else
        logWarning('O sistema já está desligado')
    end
end

function API.clear()
    for k in pairs(resources) do
        resources[k] = nil
    end
    rate_limits = {}
    stats.total_events = 0
    stats.total_bytes = 0
    stats.large_payloads = 0
    stats.floods_detected = 0
    stats.statebag_changes = 0
    stats.start_time = getTimer()
    logInfo('Dados limpos com sucesso')
end

-- ============================================================================
-- COMANDOS DE DEBUG SEPARADOS
-- ============================================================================
function API.debug()
    -- Toggle ambos
    local newState = not (CONFIG.DEBUG_STATEBAG or CONFIG.DEBUG_EVENTS)
    CONFIG.DEBUG_STATEBAG = newState
    CONFIG.DEBUG_EVENTS = newState
    if newState then
        logInfo('Debug COMPLETO ^2ATIVADO^0 (StateBags + Eventos)')
    else
        logInfo('Debug COMPLETO ^1DESATIVADO^0')
    end
end

function API.statebag()
    CONFIG.DEBUG_STATEBAG = not CONFIG.DEBUG_STATEBAG
    if CONFIG.DEBUG_STATEBAG then
        logInfo('Debug de StateBags ^2ATIVADO^0')
    else
        logInfo('Debug de StateBags ^1DESATIVADO^0')
    end
end

function API.events()
    CONFIG.DEBUG_EVENTS = not CONFIG.DEBUG_EVENTS
    if CONFIG.DEBUG_EVENTS then
        logInfo('Debug de Eventos ^2ATIVADO^0')
    else
        logInfo('Debug de Eventos ^1DESATIVADO^0')
    end
end

function API.warn()
    -- Toggle ambos warnings
    local newState = not (CONFIG.WARN_STATEBAG or CONFIG.WARN_EVENTS)
    CONFIG.WARN_STATEBAG = newState
    CONFIG.WARN_EVENTS = newState
    if newState then
        logInfo('Warnings ^2ATIVADOS^0 (StateBags + Eventos)')
    else
        logInfo('Warnings ^1DESATIVADOS^0')
    end
end

function API.warnstatebag()
    CONFIG.WARN_STATEBAG = not CONFIG.WARN_STATEBAG
    if CONFIG.WARN_STATEBAG then
        logInfo('Warnings de StateBags ^2ATIVADOS^0')
    else
        logInfo('Warnings de StateBags ^1DESATIVADOS^0')
    end
end

function API.warnevents()
    CONFIG.WARN_EVENTS = not CONFIG.WARN_EVENTS
    if CONFIG.WARN_EVENTS then
        logInfo('Warnings de Eventos ^2ATIVADOS^0')
    else
        logInfo('Warnings de Eventos ^1DESATIVADOS^0')
    end
end

function API.stats()
    local uptime = (getTimer() - stats.start_time) / 1000
    local minutes = math.floor(uptime / 60)
    local seconds = math.floor(uptime % 60)
    
    print("^4═══════════════════════════════════════════════════════════════^0")
    print("^4                    CERBERUS - ESTATÍSTICAS                    ^0")
    print("^4═══════════════════════════════════════════════════════════════^0")
    print(string.format("^3  Tempo online:^0 %dm %ds", minutes, seconds))
    print(string.format("^3  Status:^0 %s", Online and "^2ATIVO^0" or "^1INATIVO^0"))
    print("^4───────────────────────────────────────────────────────────────^0")
    print("^1  Alertas CRÍTICOS:^0 ^2SEMPRE ATIVOS^0 (flood + payload grande)")
    print("^3  Debug verbose:^0")
    print(string.format("    StateBags: %s | Eventos: %s",
        CONFIG.DEBUG_STATEBAG and "^2ATIVO^0" or "^1INATIVO^0",
        CONFIG.DEBUG_EVENTS and "^2ATIVO^0" or "^1INATIVO^0"))
    print("^3  Warnings:^0")
    print(string.format("    StateBags: %s | Eventos: %s",
        CONFIG.WARN_STATEBAG and "^2ATIVO^0" or "^1INATIVO^0",
        CONFIG.WARN_EVENTS and "^2ATIVO^0" or "^1INATIVO^0"))
    print("^4───────────────────────────────────────────────────────────────^0")
    print(string.format("^3  Total de eventos:^0 %d", stats.total_events))
    print(string.format("^3  StateBag changes:^0 %d", stats.statebag_changes))
    print(string.format("^3  Total de bytes:^0 %s", formatBytes(stats.total_bytes)))
    print(string.format("^3  Payloads grandes:^0 %d", stats.large_payloads))
    print(string.format("^1  Floods detectados:^0 %d", stats.floods_detected))
    print("^4═══════════════════════════════════════════════════════════════^0")
end

function API.top()
    local sorted = {}
    
    for _, data in pairs(resources) do
        if data.bytes > 0 then
            table.insert(sorted, data)
        end
    end
    
    table.sort(sorted, function(a, b)
        return a.bytes > b.bytes
    end)
    
    print("^4═══════════════════════════════════════════════════════════════^0")
    print("^4                 TOP 10 SCRIPTS POR BANDWIDTH                  ^0")
    print("^4═══════════════════════════════════════════════════════════════^0")
    
    for i = 1, math.min(10, #sorted) do
        local data = sorted[i]
        local color = i <= 3 and "^1" or (i <= 6 and "^3" or "^0")
        print(string.format("%s  %d. %-30s %s (%d eventos)^0",
            color, i, data.name, formatBytes(data.bytes), data.actual_count))
    end
    
    if #sorted == 0 then
        print("^3  Nenhum dado coletado ainda^0")
    end
    
    print("^4═══════════════════════════════════════════════════════════════^0")
end

function API.topevents()
    local events = {}
    
    for name, data in pairs(resources) do
        for event, info in pairs(data.events) do
            if info[1] > 0 then
                table.insert(events, {
                    script = name,
                    event = event,
                    count = info[1],
                    bytes = info[2],
                })
            end
        end
    end
    
    table.sort(events, function(a, b)
        return a.count > b.count
    end)
    
    print("^4═══════════════════════════════════════════════════════════════^0")
    print("^4                 TOP 15 EVENTOS POR FREQUÊNCIA                 ^0")
    print("^4═══════════════════════════════════════════════════════════════^0")
    
    for i = 1, math.min(15, #events) do
        local e = events[i]
        local color = i <= 3 and "^1" or (i <= 7 and "^3" or "^0")
        print(string.format("%s  %d. %s^0", color, i, e.event))
        print(string.format("      Script: %s | Calls: %d | Size: %s",
            e.script, e.count, formatBytes(e.bytes)))
    end
    
    if #events == 0 then
        print("^3  Nenhum evento coletado ainda^0")
    end
    
    print("^4═══════════════════════════════════════════════════════════════^0")
end

function API.floods()
    local floods = {}
    local now = getTimer()
    
    for key, limit in pairs(rate_limits) do
        if now - limit.window_start <= CONFIG.FLOOD_WINDOW_MS then
            if limit.calls >= CONFIG.FLOOD_WARNING_CALLS then
                table.insert(floods, {
                    key = key,
                    calls = limit.calls,
                    bytes = limit.total_bytes or 0,
                })
            end
        end
    end
    
    table.sort(floods, function(a, b)
        return a.calls > b.calls
    end)
    
    print("^4═══════════════════════════════════════════════════════════════^0")
    print("^4              EVENTOS COM ALTA FREQUÊNCIA (AGORA)              ^0")
    print("^4═══════════════════════════════════════════════════════════════^0")
    
    for i, f in ipairs(floods) do
        local status = "^3AVISO^0"
        if f.calls >= CONFIG.FLOOD_MAX_CALLS then
            status = "^1FLOOD^0"
        elseif f.calls >= CONFIG.FLOOD_CRITICAL_CALLS then
            status = "^1CRÍTICO^0"
        end
        
        print(string.format("  %s %s", status, f.key))
        print(string.format("      Calls: %d/%d | Bytes: %s",
            f.calls, CONFIG.FLOOD_MAX_CALLS, formatBytes(f.bytes)))
    end
    
    if #floods == 0 then
        print("^2  Nenhum flood detectado no momento^0")
    end
    
    print("^4═══════════════════════════════════════════════════════════════^0")
end

function API.config()
    print("^4═══════════════════════════════════════════════════════════════^0")
    print("^4                   CONFIGURAÇÕES ATUAIS                        ^0")
    print("^4═══════════════════════════════════════════════════════════════^0")
    print("^3  Payload:^0")
    print(string.format("    Warning: %s | Critical: %s | Max: %s",
        formatBytes(CONFIG.PAYLOAD_WARNING_SIZE),
        formatBytes(CONFIG.PAYLOAD_CRITICAL_SIZE),
        formatBytes(CONFIG.PAYLOAD_MAX_SIZE)))
    print("^3  Flood Detection:^0")
    print(string.format("    Janela: %dms | Warning: %d | Critical: %d | Max: %d",
        CONFIG.FLOOD_WINDOW_MS, CONFIG.FLOOD_WARNING_CALLS,
        CONFIG.FLOOD_CRITICAL_CALLS, CONFIG.FLOOD_MAX_CALLS))
    print("^3  StateBag:^0")
    print(string.format("    Warning: %s | Critical: %s",
        formatBytes(CONFIG.STATEBAG_WARNING_SIZE),
        formatBytes(CONFIG.STATEBAG_CRITICAL_SIZE)))
    print("^4═══════════════════════════════════════════════════════════════^0")
end

function API.setflood()
    -- Uso: cerberus setflood <max_calls>
    print("^3Uso: cerberus set flood <max_calls>^0")
    print("^3Exemplo: cerberus set flood 100^0")
end

-- ============================================================================
-- COMANDO SET PARA CONFIGURAÇÕES
-- ============================================================================
local function handleSet(args)
    local param = args[2]
    local value = tonumber(args[3])
    
    if not param then
        print("^3Uso: cerberus set <parametro> <valor>^0")
        print("^3Parâmetros disponíveis:^0")
        print("  flood <numero>     - Max calls por segundo")
        print("  payload <bytes>    - Warning size em bytes")
        print("  statebag <bytes>   - StateBag warning size")
        return
    end
    
    if param == "flood" and value then
        CONFIG.FLOOD_MAX_CALLS = value
        CONFIG.FLOOD_CRITICAL_CALLS = math.floor(value * 0.5)
        CONFIG.FLOOD_WARNING_CALLS = math.floor(value * 0.25)
        logInfo("Flood limits atualizados: Warning=%d, Critical=%d, Max=%d",
            CONFIG.FLOOD_WARNING_CALLS, CONFIG.FLOOD_CRITICAL_CALLS, CONFIG.FLOOD_MAX_CALLS)
    elseif param == "payload" and value then
        CONFIG.PAYLOAD_WARNING_SIZE = value
        CONFIG.PAYLOAD_CRITICAL_SIZE = value * 2
        CONFIG.PAYLOAD_MAX_SIZE = value * 4
        logInfo("Payload limits atualizados: Warning=%s, Critical=%s, Max=%s",
            formatBytes(CONFIG.PAYLOAD_WARNING_SIZE),
            formatBytes(CONFIG.PAYLOAD_CRITICAL_SIZE),
            formatBytes(CONFIG.PAYLOAD_MAX_SIZE))
    elseif param == "statebag" and value then
        CONFIG.STATEBAG_WARNING_SIZE = value
        CONFIG.STATEBAG_CRITICAL_SIZE = value * 2
        logInfo("StateBag limits atualizados: Warning=%s, Critical=%s",
            formatBytes(CONFIG.STATEBAG_WARNING_SIZE),
            formatBytes(CONFIG.STATEBAG_CRITICAL_SIZE))
    else
        logWarning("Parâmetro inválido ou valor não especificado")
    end
end

-- ============================================================================
-- REGISTRO DO COMANDO
-- ============================================================================
RegisterCommand('cerberus', function(source, args)
    if source ~= 0 then return end

    local cmd = args[1]
    
    if cmd == "set" then
        return handleSet(args)
    end

    local fn = API[cmd]

    if fn then
        return fn()
    end

    print("^4═══════════════════════════════════════════════════════════════^0")
    print("^4                      CERBERUS - COMANDOS                      ^0")
    print("^4═══════════════════════════════════════════════════════════════^0")
    print("^3  Instalação:^0")
    print("    cerberus install        Injeta a lib em todos os scripts")
    print("    cerberus uninstall      Remove a lib de todos os scripts")
    print("^3  Controle:^0")
    print("    cerberus start          Ativa o monitoramento")
    print("    cerberus stop           Desativa o monitoramento")
    print("    cerberus clear          Limpa todos os dados")
    print("    cerberus dump           Salva relatório em JSON")
    print("^1  ALERTAS CRÍTICOS:^0 Flood e Payload grande = SEMPRE ATIVOS")
    print("^3  Debug (verbose - mostra tudo):^0")
    print("    cerberus debug          Toggle debug COMPLETO")
    print("    cerberus statebag       Toggle debug de StateBags")
    print("    cerberus events         Toggle debug de Eventos")
    print("^3  Warnings (avisos menores):^0")
    print("    cerberus warn           Toggle warnings COMPLETOS")
    print("    cerberus warnstatebag   Toggle warnings de StateBags")
    print("    cerberus warnevents     Toggle warnings de Eventos")
    print("^3  Relatórios:^0")
    print("    cerberus stats          Mostra estatísticas gerais")
    print("    cerberus top            Top 10 scripts por bandwidth")
    print("    cerberus topevents      Top 15 eventos por frequência")
    print("    cerberus floods         Eventos com alta frequência agora")
    print("    cerberus config         Mostra configurações atuais")
    print("^3  Configuração:^0")
    print("    cerberus set flood <n>      Define max calls/segundo")
    print("    cerberus set payload <n>    Define warning size (bytes)")
    print("    cerberus set statebag <n>   Define statebag warning (bytes)")
    print("^4═══════════════════════════════════════════════════════════════^0")
end)

-- ============================================================================
-- LIMPEZA PERIÓDICA DE RATE LIMITS ANTIGOS
-- ============================================================================
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(30000) -- A cada 30 segundos
        
        local now = getTimer()
        local threshold = now - (CONFIG.FLOOD_WINDOW_MS * 10)
        local cleaned = 0
        
        for key, limit in pairs(rate_limits) do
            if limit.window_start < threshold then
                rate_limits[key] = nil
                cleaned = cleaned + 1
            end
        end
        
        if cleaned > 0 and CONFIG.DEBUG_MODE then
            logDebug("Limpeza: %d rate limits antigos removidos", cleaned)
        end
    end
end)