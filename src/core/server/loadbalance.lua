local SETTINGS = {
    directPayloadBytes = 3500,
    chunkBytes = 3000,
    latentBps = 25000,
    workerCount = 3,
    nearChunkDelay = 0,
    farChunkDelay = 60,
    nearDirectDelay = 0,
    farDirectDelay = 25,
    latentDispatchDelay = 10
}

local INTERNAL_CHUNK_EVENT = "__cerberus:loadbalance:chunk"
local INTERNAL_LATENT_EVENT = "__cerberus:loadbalance:latent"
local INTERNAL_DIRECT_EVENT = "__cerberus:loadbalance:direct"

local RequestSequence = 0
local KeyVersions = {}
local WorkersStarted = false
local QueueTurn = 0
local DebugLogging = false

local Queues = {
    near = { first = 1, last = 0, items = {} },
    normal = { first = 1, last = 0, items = {} }
}

local function MergeOptions(defaults, options)
    local merged = {}

    if defaults then
        for key, value in pairs(defaults) do
            merged[key] = value
        end
    end

    if options then
        for key, value in pairs(options) do
            merged[key] = value
        end
    end

    return merged
end

local function LogJobStart(job, nearCount, normalCount)
    if not DebugLogging then return end
    print(("[cerberus][loadbalance][start] request=%s sync=%s event=%s transport=%s targets=%s near=%s far=%s payloadBytes=%s key=%s"):format(
        job.requestId,
        job.syncKind or "custom",
        job.eventName,
        job.transport,
        #job.targets,
        nearCount or 0,
        normalCount or 0,
        job.payloadSize or 0,
        job.key or "none"
    ))
end

local function LogJobFinish(job)
    if not DebugLogging then return end
    print(("[cerberus][loadbalance][finish] request=%s sync=%s event=%s transport=%s targets=%s delivered=%s payloadBytes=%s elapsedMs=%s key=%s"):format(
        job.requestId,
        job.syncKind or "custom",
        job.eventName,
        job.transport,
        #job.targets,
        job.completedTargets or 0,
        job.payloadSize or 0,
        GetGameTimer() - job.createdAt,
        job.key or "none"
    ))
end

local function MarkTargetComplete(job)
    job.completedTargets = (job.completedTargets or 0) + 1

    if job.completedTargets >= (job.totalDeliveries or 0) and not job.finishedLogged then
        job.finishedLogged = true
        LogJobFinish(job)
    end
end

local function NextRequestId()
    RequestSequence = RequestSequence + 1
    return ("%s:%s"):format(GetGameTimer(), RequestSequence)
end

local function Enqueue(queueName, item)
    local queue = Queues[queueName]
    queue.last = queue.last + 1
    queue.items[queue.last] = item
end

local function Dequeue(queueName)
    local queue = Queues[queueName]
    if queue.first > queue.last then
        return nil
    end

    local item = queue.items[queue.first]
    queue.items[queue.first] = nil
    queue.first = queue.first + 1
    return item
end

local function QueueHasItems(queueName)
    local queue = Queues[queueName]
    return queue.first <= queue.last
end

local function IsPlayerConnected(target)
    return target and target > 0 and GetPlayerName(target) ~= nil
end

local function NormalizeCoords(coords)
    if not coords then
        return nil
    end

    if coords.x and coords.y and coords.z then
        return vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)
    end

    return nil
end

local function GetTargetDistance(target, coords)
    local ped = GetPlayerPed(target)
    if not ped or ped == 0 then
        return math.huge
    end

    local targetCoords = GetEntityCoords(ped)
    return #(targetCoords - coords)
end

local function ResolveTargets(targets)
    local resolved = {}
    local seen = {}

    local function addTarget(target)
        target = tonumber(target)
        if not target or target <= 0 or seen[target] then
            return
        end

        seen[target] = true
        resolved[#resolved + 1] = target
    end

    if type(targets) == "number" then
        if targets == -1 then
            for _, playerId in ipairs(GetPlayers()) do
                addTarget(playerId)
            end
        else
            addTarget(targets)
        end
    elseif type(targets) == "table" then
        for _, target in pairs(targets) do
            addTarget(target)
        end
    end

    return resolved
end

local function EncodePayload(payload)
    local encoded = json.encode(payload)
    if not encoded then
        return nil, "Falha ao serializar payload."
    end

    return encoded, #encoded
end

local function SplitPayload(encodedPayload, chunkBytes)
    local chunks = {}

    for index = 1, #encodedPayload, chunkBytes do
        chunks[#chunks + 1] = encodedPayload:sub(index, index + chunkBytes - 1)
    end

    return chunks
end

local function ResolveJobKey(eventName, options)
    if options.key ~= nil then
        return options.key or nil
    end

    if options.replacePending == false then
        return nil
    end

    return eventName
end

local function IsCurrentJob(job)
    if not job.key then
        return true
    end

    return KeyVersions[job.key] == job.version
end

local function IsDeliveryValid(delivery)
    if not delivery or not delivery.job then
        return false
    end

    if not IsCurrentJob(delivery.job) then
        return false
    end

    if not IsPlayerConnected(delivery.target) then
        return false
    end

    if delivery.job.transport == "chunk" and delivery.nextChunk > delivery.job.totalChunks then
        return false
    end

    return true
end

local function PopNextDelivery()
    local preferNear = (QueueTurn % 4) ~= 3
    QueueTurn = QueueTurn + 1

    if preferNear and QueueHasItems("near") then
        return Dequeue("near")
    end

    if QueueHasItems("normal") then
        return Dequeue("normal")
    end

    if QueueHasItems("near") then
        return Dequeue("near")
    end

    return nil
end

local function BuildJob(eventName, payload, targets, options)
    local encodedPayload, payloadSize = EncodePayload(payload)
    if not encodedPayload then
        return nil, payloadSize
    end

    local key = ResolveJobKey(eventName, options)
    local version = nil
    if key then
        version = (KeyVersions[key] or 0) + 1
        KeyVersions[key] = version
    end

    local job = {
        key = key,
        version = version,
        requestId = NextRequestId(),
        createdAt = GetGameTimer(),
        eventName = eventName,
        syncKind = options.syncKind or "custom",
        payload = payload,
        encodedPayload = encodedPayload,
        payloadSize = payloadSize,
        targets = targets,
        totalDeliveries = #targets,
        completedTargets = 0,
        finishedLogged = false
    }

    if payloadSize <= SETTINGS.directPayloadBytes then
        job.transport = "direct"
    elseif #targets == 1 then
        job.transport = "latent"
    else
        job.transport = "chunk"
        job.chunks = SplitPayload(encodedPayload, SETTINGS.chunkBytes)
        job.totalChunks = #job.chunks
    end

    return job
end

local function BuildDeliveries(job, options)
    local coords = NormalizeCoords(options.coords)
    local range = tonumber(options.range)
    local nearDeliveries = {}
    local normalDeliveries = {}

    for _, target in ipairs(job.targets) do
        if IsPlayerConnected(target) then
            local priority = "normal"
            local distance = math.huge

            if coords then
                distance = GetTargetDistance(target, coords)
                if not range or range <= 0 or distance <= range then
                    priority = "near"
                end
            end

            local delivery = {
                target = target,
                priority = priority,
                distance = distance,
                nextChunk = 1,
                job = job
            }

            if priority == "near" then
                nearDeliveries[#nearDeliveries + 1] = delivery
            else
                normalDeliveries[#normalDeliveries + 1] = delivery
            end
        end
    end

    table.sort(nearDeliveries, function(a, b)
        return a.distance < b.distance
    end)

    if coords then
        table.sort(normalDeliveries, function(a, b)
            return a.distance < b.distance
        end)
    end

    return nearDeliveries, normalDeliveries
end

local function BuildDeliveriesFromScope(job, nearTargets, farTargets)
    local nearDeliveries = {}
    local normalDeliveries = {}

    for _, target in ipairs(nearTargets) do
        if IsPlayerConnected(target) then
            nearDeliveries[#nearDeliveries + 1] = {
                target = target,
                priority = "near",
                distance = 0,
                nextChunk = 1,
                job = job
            }
        end
    end

    for _, target in ipairs(farTargets) do
        if IsPlayerConnected(target) then
            normalDeliveries[#normalDeliveries + 1] = {
                target = target,
                priority = "normal",
                distance = math.huge,
                nextChunk = 1,
                job = job
            }
        end
    end

    return nearDeliveries, normalDeliveries
end

local function RequeueDelivery(delivery)
    if not IsDeliveryValid(delivery) then
        return
    end

    Enqueue(delivery.priority == "near" and "near" or "normal", delivery)
end

local function ProcessDelivery(delivery)
    local job = delivery.job

    if job.transport == "direct" then
        TriggerClientEvent(INTERNAL_DIRECT_EVENT, delivery.target, job.eventName, job.encodedPayload)
        MarkTargetComplete(job)
        if delivery.priority == "near" then
            return SETTINGS.nearDirectDelay
        end

        return SETTINGS.farDirectDelay
    end

    if job.transport == "latent" then
        TriggerLatentClientEvent(INTERNAL_LATENT_EVENT, delivery.target, SETTINGS.latentBps, job.requestId, job.eventName, job.encodedPayload)
        MarkTargetComplete(job)
        return SETTINGS.latentDispatchDelay
    end

    local chunkIndex = delivery.nextChunk
    local chunk = job.chunks[chunkIndex]
    if not chunk then
        return 0
    end

    TriggerClientEvent(INTERNAL_CHUNK_EVENT, delivery.target, job.requestId, job.eventName, chunkIndex, job.totalChunks, chunk)
    delivery.nextChunk = chunkIndex + 1

    if delivery.nextChunk <= job.totalChunks and IsCurrentJob(job) then
        RequeueDelivery(delivery)
    else
        MarkTargetComplete(job)
    end

    if delivery.priority == "near" then
        return SETTINGS.nearChunkDelay
    end

    return SETTINGS.farChunkDelay
end

local function StartWorkers()
    if WorkersStarted then
        return
    end

    WorkersStarted = true

    for workerId = 1, SETTINGS.workerCount do
        CreateThread(function()
            while true do
                local delivery = PopNextDelivery()
                if delivery and IsDeliveryValid(delivery) then
                    local waitTime = ProcessDelivery(delivery)
                    if waitTime > 0 then
                        Wait(waitTime)
                    else
                        Wait(0)
                    end
                else
                    Wait(1000)
                end
            end
        end)
    end
end

---@param targets number|table
---@param eventName string
---@param payload any
---@param options Options
---@return boolean,string|nil
local function SendBalancedPayload(targets, eventName, payload, options)
    options = options or {}

    if type(eventName) ~= "string" or eventName == "" then
        return false, "eventName invalido."
    end

    local coords = NormalizeCoords(options.coords)
    local range = tonumber(options.range)
    local scopeRadius = tonumber(options.scopeRadius)
    local nearTargets, farTargets

    if targets == -1 and coords and range and range > 0 then
        nearTargets, farTargets = PlayersScopeCoords(coords, range, true, scopeRadius)
        farTargets = farTargets or {}

        if (#nearTargets + #farTargets) == 0 then
            return true, nil
        end

        local allTargets = {}
        for _, t in ipairs(nearTargets) do allTargets[#allTargets + 1] = t end
        for _, t in ipairs(farTargets) do allTargets[#allTargets + 1] = t end
        targets = allTargets
    elseif targets == -1 and scopeRadius and coords then
        local scoped = PlayersScopeCoords(coords, scopeRadius)
        if not scoped or #scoped == 0 then
            return true, nil
        end
        targets = scoped
    end

    local resolvedTargets = ResolveTargets(targets)
    if #resolvedTargets == 0 then
        return false, "Nenhum target valido para envio."
    end

    StartWorkers()

    local job, errorMessage = BuildJob(eventName, payload, resolvedTargets, options)
    if not job then
        return false, type(errorMessage) == "string" and errorMessage or "Falha ao montar job de load balance."
    end

    local nearDeliveries, normalDeliveries
    if nearTargets then
        nearDeliveries, normalDeliveries = BuildDeliveriesFromScope(job, nearTargets, farTargets)
    else
        nearDeliveries, normalDeliveries = BuildDeliveries(job, options)
    end

    if (#nearDeliveries + #normalDeliveries) <= 0 then
        return false, "Nenhum target conectado para envio."
    end

    LogJobStart(job, #nearDeliveries, #normalDeliveries)

    if job.transport == "direct" and #resolvedTargets == 1 then
        TriggerClientEvent(INTERNAL_DIRECT_EVENT, resolvedTargets[1], eventName, job.encodedPayload)
        MarkTargetComplete(job)
        return true, job.requestId
    end

    for _, delivery in ipairs(nearDeliveries) do
        Enqueue("near", delivery)
    end

    for _, delivery in ipairs(normalDeliveries) do
        Enqueue("normal", delivery)
    end

    return true, job.requestId
end

---@param targets number|table
---@param eventName string
---@param payload any
---@param options Options
---@return boolean,string|nil
local function SendFullSync(targets, eventName, payload, options)
    local syncOptions = MergeOptions({
        syncKind = "full",
        replacePending = true,
        key = ("%s:full"):format(eventName)
    }, options)

    return SendBalancedPayload(targets, eventName, payload, syncOptions)
end

---@alias Options { syncKind?: string, replacePending?: boolean, key?: string, coords?: vector3, range?: number, scopeRadius?: number }

---@param targets number|table
---@param eventName string
---@param payload any
---@param options Options
---@return boolean,string|nil
local function SendDeltaSync(targets, eventName, payload, options)
    local syncOptions = MergeOptions({
        syncKind = "delta",
        replacePending = false
    }, options)

    return SendBalancedPayload(targets, eventName, payload, syncOptions)
end

---@param Event string
---@param ... any
local function SendAsyncClient(Event, ...)
    if type(Event) ~= "string" or Event == "" then
        return
    end

    local args = { ... }

    CreateThread(function()
        local CurrentTime = GetGameTimer()
        for _, Source in ipairs(GetPlayers()) do
            TriggerClientEvent(Event, Source, table.unpack(args))
            Wait(20)
        end
        print(("[cerberus][loadbalance] Evento %s enviado em %sms"):format(Event, GetGameTimer() - CurrentTime))
    end)
end

exports("SendBalancedPayload", SendBalancedPayload)
exports("SendFullSync", SendFullSync)
exports("SendDeltaSync", SendDeltaSync)
exports("SendAsyncClient", SendAsyncClient)

AddEventHandler("playerDropped", function()
    local source = source

    for _, queueName in ipairs({ "near", "normal" }) do
        local queue = Queues[queueName]
        for index = queue.first, queue.last do
            local delivery = queue.items[index]
            if delivery and delivery.target == source then
                queue.items[index] = nil
            end
        end
    end
end)

RegisterCommand("lbdebug", function(src)
    if src ~= 0 then return end
    DebugLogging = not DebugLogging
    print(("[cerberus][loadbalance] debug logs %s"):format(DebugLogging and "ativados" or "desativados"))
end, true)
