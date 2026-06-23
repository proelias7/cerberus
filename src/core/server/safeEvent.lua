if not config.modules.safeEvent then return end

local PlayersExploit = {}
local DebugMode = false

--[[
if source and exports["cerberus"]:SafeEvent(source, "requestInventory",{ 
    time = 2, 
    noBan = true, 
    notification = true,
    blockThreshold = 3 
}) then
    return
end
]]

---@class SafeEventOptions
---@field data any|nil
---@field time number|nil
---@field noBan boolean|nil
---@field position boolean|nil
---@field positionDist number|nil
---@field interPorDetect number|nil
---@field suspectCount number|nil
---@field notification boolean|nil
---@field blockThreshold number|nil  -- Quantas suspeitas antes de bloquear (retornar true)
---@field logThreshold number|nil  -- Quantas suspeitas antes de mostrar logs
---@field silentLog boolean|nil     -- Silenciar logs mas continuar registrando

---@param source number
---@param eventName string
---@param options SafeEventOptions|nil
---@return boolean|nil
exports("SafeEvent",function(source, eventName, options)      
    local currentTime = os.time()
    local time = (options and options.time) or config.defaultTime
    local interPorDetect = (options and options.interPorDetect) or config.interPorDetect
    local suspectCount = (options and options.suspectCount) or config.suspectCount
    local data = (options and options.data) or nil
    local noBan = (options and options.noBan) or false
    local checkPosition = (options and options.position) or false
    local positionDist = (options and options.positionDist) or 100
    local notification = (options and options.notification) or false
    local blockThreshold = (options and options.blockThreshold) or config.blockThreshold
    local logThreshold = (options and options.logThreshold) or config.logThreshold
    local silentLog = (options and options.silentLog) or false
    
    if not PlayersExploit[source] then 
        PlayersExploit[source] = {
            events = {},
            passport = PlayerID(source),
            eventSuspects = {}  -- Rastrear suspeitas por evento
        }
    end
    
    if not PlayersExploit[source].suspectCount then
        PlayersExploit[source].suspectCount = 0
        PlayersExploit[source].firstSuspectTime = 0
        PlayersExploit[source].log = ""
    end
    
    -- Inicializar contador por evento
    if not PlayersExploit[source].eventSuspects[eventName] then
        PlayersExploit[source].eventSuspects[eventName] = {
            count = 0,
            firstTime = 0
        }
    end
    
    if PlayersExploit[source]["events"][eventName] then
        local difference = currentTime - PlayersExploit[source]["events"][eventName]

        if DebugMode then
            local distance = checkPosition and GetDistance(PlayersExploit[source].position, GetPosition(source)) or nil
            print("\027[33m ==============================================")
            print("\027[33m ID:", PlayersExploit[source].passport)
            print("\027[33m Event:", eventName)
            print("\027[33m Data:", data or "N/A")
            print("\027[33m Time:", difference.."s")
            if distance then
                print("\027[33m Dist:", distance.."m")
            end
            print("\027[33m ==============================================")
        end

        if difference < time then
            PlayersExploit[source].suspectCount = PlayersExploit[source].suspectCount + 1
            PlayersExploit[source].eventSuspects[eventName].count = PlayersExploit[source].eventSuspects[eventName].count + 1

            local distance = nil

            if checkPosition then
                distance = GetDistance(PlayersExploit[source].position, GetPosition(source))
                if distance <= positionDist and not noBan then
                    SetBan(source, "Trigger de evento em curta distancia", nil, "foi banido por Triggar em curta distancia. "..distance.."m")
                    PlayersExploit[source] = nil
                    return true
                end
            end

            if PlayersExploit[source].suspectCount == 1 then
                PlayersExploit[source].firstSuspectTime = currentTime
            end
            
            -- Registrar primeira suspeita por evento
            if PlayersExploit[source].eventSuspects[eventName].count == 1 then
                PlayersExploit[source].eventSuspects[eventName].firstTime = currentTime
            end
            
            local timeSinceFirstSuspect = currentTime - PlayersExploit[source].firstSuspectTime
            local eventSuspectCount = PlayersExploit[source].eventSuspects[eventName].count
            
            -- Criar log message (sempre registra internamente)
            local logMessage = "[SUSPEITO] ID: " .. PlayersExploit[source].passport .." Event: " .. eventName .. " " .. (data and 'Data: '..data or "") .. (distance and 'Dist: '..distance..'m ' or "") .. " | Metric: " .. eventSuspectCount .. " - " ..difference.. "s - " .. timeSinceFirstSuspect .. "s"
            
            -- Só mostra no console se atingiu o threshold OU se for ban OU se debug mode
            local shouldLog = not silentLog and (
                eventSuspectCount >= logThreshold or 
                PlayersExploit[source].suspectCount >= suspectCount or
                DebugMode
            )
            
            if shouldLog then
                print("\027[33m " .. logMessage)
            end
            
            -- SEMPRE registra no log interno (para ban)
            PlayersExploit[source].log = PlayersExploit[source].log .. logMessage .. "\n"
            
            if PlayersExploit[source].suspectCount >= suspectCount and timeSinceFirstSuspect < interPorDetect and not noBan then
                -- Log resumido ao banir
                local summaryLog = string.format(
                    "[BAN] ID: %s | Evento: %s | %d suspeitas em %ds | Primeira suspeita há %ds",
                    PlayersExploit[source].passport,
                    eventName,
                    PlayersExploit[source].suspectCount,
                    timeSinceFirstSuspect,
                    timeSinceFirstSuspect
                )
                print("\027[31m " .. summaryLog)
                
                SetBan(source, "Trigger de evento", PlayersExploit[source].log)
                PlayersExploit[source] = nil
                return true
            end
            
            -- Só retorna true (bloqueia) se atingiu o blockThreshold para este evento
            if eventSuspectCount >= blockThreshold then
                if notification then
                    local remainingTime = math.max(0, time - difference)
                    Notify(source, "Aguarde " .. remainingTime .. " segundos para executar esta ação novamente.")
                end
                return true
            else
                return false
            end
        else
            -- Reset apenas se passou o tempo para este evento específico
            PlayersExploit[source].suspectCount = 0
            PlayersExploit[source].firstSuspectTime = 0
            PlayersExploit[source].log = ""
            PlayersExploit[source].eventSuspects[eventName] = {
                count = 0,
                firstTime = 0
            }
        end
    end
    
    PlayersExploit[source]["events"][eventName] = currentTime
    if checkPosition or DebugMode then
        PlayersExploit[source].position = GetPosition(source)
    end
    return false
end)


Citizen.CreateThread(function()
    while true do
        Citizen.Wait(15000)
        local currentTime = os.time()
        for source, data in pairs(PlayersExploit) do
            for eventName, eventTime in pairs(data.events) do
                local difference = currentTime - eventTime
                if difference > 60 then
                    data.events[eventName] = nil
                    -- Limpar também os contadores de suspeitas do evento
                    if data.eventSuspects and data.eventSuspects[eventName] then
                        data.eventSuspects[eventName] = nil
                    end
                end
            end
        end
    end
end)

RegisterCommand('debugexploit',function(source)
    if source == 0 then
        DebugMode = not DebugMode
        print("DebugMode: "..(DebugMode and "Ativado" or "Desativado"))
    end
end)

RegisterServerEvent('dev:giveMoney', function()
    local source = source
    SetBan(source, "Trigger de evento", nil, "foi banido por Triggar evento.")
end)

Citizen.CreateThread(function()
    for _, event in ipairs(config.BlackListEvents) do
        AddEventHandler(event, function()
            local source = source
            SetBan(source, "Trigger de evento", nil, "foi banido por Triggar evento na BlackList Evento:" .. tostring(eventName) .. ".")
        end)
        Citizen.Wait(100)
    end
end)

AddEventHandler("playerDropped",function()
    local source = source
    if PlayersExploit[source] then
        PlayersExploit[source] = nil
    end
end)

-- AddEventHandler("Connect", function(user_id,source)
--     local source = source
--     local IP = GetPlayerEndpoint(source)
--     local ISP, CITY, COUNTRY, PROXY, HOSTING, LON, LAT = "Not Found", "Not Found", "Not Found", "Not Found", "Not Found",
--         "Not Found", "Not Found"

--     IP = (string.gsub(string.gsub(string.gsub(IP, "-", ""), ",", ""), " ", ""):lower())
--     local g, f = IP:find(string.lower("192.168"))
--     if g or f then
--         IP = "178.131.122.181"
--     end

    
--     PerformHttpRequest("http://ip-api.com/json/" .. IP .. "?fields=66846719", function(ERROR, DATA, RESULT)
--         if DATA then
--             local TABLE = json.decode(DATA)
--             if TABLE then
--                 ISP, CITY, COUNTRY = TABLE["isp"], TABLE["city"], TABLE["country"]
--                 PROXY, HOSTING, LON, LAT = TABLE["proxy"] and "ON" or "OFF", TABLE["hosting"] and "ON" or "OFF",
--                     TABLE["lon"], TABLE["lat"]

--                 -- print("\027[35m Verificando Ip: "..IP)
--                 -- print(PROXY,HOSTING)

--                 if PROXY == "ON" or HOSTING == "ON" then
--                     print("\027[35m VPN DETECTADO ID: " .. user_id .. " IP: " .. IP .. " VPN: " .. PROXY .. " Hosting: " .. HOSTING .. " ISP: " .. ISP .. " Country: " .. COUNTRY .. " City: " .. CITY .. "")
--                 end
--             else
--                 print("\027[35m ID: " .. user_id .. " playerConnecting (TABLE Not Found)")
--             end
--         else
--             print("\027[35m Falha ao validar VPN, ID: "..user_id.." IP: "..tostring(IP))
--         end
--     end)
-- end)

