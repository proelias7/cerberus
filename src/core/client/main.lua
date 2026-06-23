
local Cooldowns = {}
local loadBalanceSessions = {}
local loadBalanceSessionTtl = 120000

exports("SetCooldown", function(name, time, hits)
    local currentTime = GetGameTimer()
    if Cooldowns[name] then
        if Cooldowns[name].blocked then
            if Cooldowns[name].time > currentTime then
                return true
            else
                Cooldowns[name] = nil
            end
            return false
        end
        if hits then
            Cooldowns[name].hit += 1
            if Cooldowns[name].hit >= hits then
                if Cooldowns[name].time > currentTime then
                    local remainingTime = math.ceil((Cooldowns[name].time - currentTime) / 1000)
                    TriggerEvent("Notify", "amarelo", "Aguarde " .. remainingTime .. " segundos para executar a ação novamente.", 2000)
                    Cooldowns[name].blocked = true
                    return true
                else
                    Cooldowns[name] = nil
                end
            end
        else
            if Cooldowns[name].time > currentTime then
                local remainingTime = math.ceil((Cooldowns[name].time - currentTime) / 1000)
                TriggerEvent("Notify", "amarelo", "Aguarde " .. remainingTime .. " segundos para executar a ação novamente.", 2000)
                Cooldowns[name].blocked = true
                return true
            else
                Cooldowns[name] = nil
            end
        end
    else
        Cooldowns[name] = { time = currentTime + time, hit = 0, blocked = false }
    end

    return false
end)

local function TriggerEventUnpacked(eventName, payload)
    if type(payload) == "table" and #payload > 0 then
        TriggerEvent(eventName, table.unpack(payload, 1, #payload))
    else
        TriggerEvent(eventName, payload)
    end
end

local function getOrCreateLoadBalanceSession(requestId, eventName, totalChunks)
    local now = GetGameTimer()
    local session = loadBalanceSessions[requestId]

    if session and (session.expiresAt <= now or session.totalChunks ~= totalChunks or session.eventName ~= eventName) then
        loadBalanceSessions[requestId] = nil
        session = nil
    end

    if not session then
        session = {
            eventName = eventName,
            totalChunks = totalChunks,
            chunks = {},
            received = 0,
            expiresAt = now + loadBalanceSessionTtl
        }

        loadBalanceSessions[requestId] = session
    else
        session.expiresAt = now + loadBalanceSessionTtl
    end

    return session
end

RegisterNetEvent("__cerberus:loadbalance:chunk")
AddEventHandler("__cerberus:loadbalance:chunk", function(requestId, eventName, chunkIndex, totalChunks, chunk)
    if type(requestId) ~= "string" or type(eventName) ~= "string" then
        return
    end

    local session = getOrCreateLoadBalanceSession(requestId, eventName, totalChunks)
    if not session.chunks[chunkIndex] then
        session.received = session.received + 1
    end

    session.chunks[chunkIndex] = chunk

    if session.received < session.totalChunks then
        return
    end

    local encodedPayload = table.concat(session.chunks)
    loadBalanceSessions[requestId] = nil

    local payload = json.decode(encodedPayload)
    if payload == nil and encodedPayload ~= "null" then
        print(("[cerberus] Falha ao decodificar payload fragmentado: %s"):format(eventName))
        return
    end

    TriggerEventUnpacked(eventName, payload)
end)

RegisterNetEvent("__cerberus:loadbalance:direct")
AddEventHandler("__cerberus:loadbalance:direct", function(eventName, encodedPayload)
    if type(eventName) ~= "string" or type(encodedPayload) ~= "string" then
        return
    end

    local payload = json.decode(encodedPayload)
    if payload == nil and encodedPayload ~= "null" then
        print(("[cerberus] Falha ao decodificar payload direct: %s"):format(eventName))
        return
    end

    TriggerEventUnpacked(eventName, payload)
end)

RegisterNetEvent("__cerberus:loadbalance:latent")
AddEventHandler("__cerberus:loadbalance:latent", function(requestId, eventName, encodedPayload)
    if type(requestId) ~= "string" or type(eventName) ~= "string" or type(encodedPayload) ~= "string" then
        return
    end

    loadBalanceSessions[requestId] = nil

    local payload = json.decode(encodedPayload)
    if payload == nil and encodedPayload ~= "null" then
        print(("[cerberus] Falha ao decodificar payload latent: %s"):format(eventName))
        return
    end

    TriggerEventUnpacked(eventName, payload)
end)

CreateThread(function()
    while true do
        Wait(30000)

        local now = GetGameTimer()
        for requestId, session in pairs(loadBalanceSessions) do
            if session.expiresAt <= now then
                loadBalanceSessions[requestId] = nil
            end
        end
    end
end)