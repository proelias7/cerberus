local this = GetCurrentResourceName()
local cerberus = exports.cerberus

-- ═══════════════════════════════════════════════════════════════
-- INTERCEPTA EVENTOS DE SAÍDA (Server -> Client)
-- ═══════════════════════════════════════════════════════════════
local _TriggerClientEventInternal = TriggerClientEventInternal

function TriggerClientEventInternal(name, target, payload, len)
    cerberus:hit(this, "OUT:" .. name, target == -1, len)
    _TriggerClientEventInternal(name, target, payload, len)
end

-- ═══════════════════════════════════════════════════════════════
-- INTERCEPTA EVENTOS DE ENTRADA (Client -> Server)
-- ═══════════════════════════════════════════════════════════════
local _RegisterNetEvent = RegisterNetEvent
local _AddEventHandler = AddEventHandler
local registeredEvents = {}

function RegisterNetEvent(eventName, ...)
    registeredEvents[eventName] = true
    return _RegisterNetEvent(eventName, ...)
end

function AddEventHandler(eventName, handler)
    -- Só intercepta eventos de rede (registrados com RegisterNetEvent)
    if registeredEvents[eventName] then
        local wrappedHandler = function(...)
            local args = msgpack.pack({...})
            local len = args and #args or 0
            cerberus:hit(this, "IN:" .. eventName, false, len)
            return handler(...)
        end
        return _AddEventHandler(eventName, wrappedHandler)
    end
    
    return _AddEventHandler(eventName, handler)
end