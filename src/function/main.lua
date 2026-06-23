local Proxy = module("vrp","lib/Proxy")
local vRP = Proxy.getInterface("vRP")
CurrentResource = GetCurrentResourceName()
Players = {}
local ProcessedBans = {}

local Unpack = table.unpack
local Floor = math.floor
local Ceil = math.ceil

function LoadFile(resource, path)
    local File = LoadResourceFile(resource, path)
    if not File then return nil end

    local f, err = load(File)
    if err then return nil end

    local success, res = pcall(f)
    if not success then return nil end
    return res
end

config = LoadFile(CurrentResource,'./config/config.lua')


function GetPosition(source)
    local tD = function(n) return Ceil(n * 100) / 100 end
    local x,y,z = Unpack(GetEntityCoords(GetPlayerPed(source)))
    return vector3(tD(x),tD(y),tD(z))
end

function GetDistance(position1, position2)
    if not position1 or not position2 then
        return 0
    end
    local dist = #(position1 - position2)
    return Floor(dist * 100) / 100
end

function SendWebhook(webhook,message)
    if message then
        PerformHttpRequest(webhook, function(err, text, headers) end, 'POST', json.encode({embeds = message}), { ['Content-Type'] = 'application/json' })
    end
end

function Notify(source, message)
    TriggerClientEvent("Notify",source,"aviso",message)
end

function PlayerID(source)
    local Player = GetPlayerData(source)
    if Player then
        return Player.Passport
    end
    return "Unknown"
end

function GetPlayerName(source)
    local Player = GetPlayerData(source)
    if Player then
        return Player.Name
    end
    return "Unknown"
end

function GetPlayerLicense(source)
    local Player = GetPlayerData(source)
    if Player then
        return Player.License
    end
    return "Unknown"
end

function SetBan(source, reason, logs, printReason)
    if ProcessedBans[source] then return end
    ProcessedBans[source] = true
    local Passport = PlayerID(source)
    if Passport then
        local License = GetPlayerLicense(source)
        local isBanned, BanID, Reason, TimeRemaining = vRP.BanTokens(License, 1, reason, -1, source)
        
        SetTimeout(3000,function()
            DropPlayer(source,"Você foi banido do servidor.")
            ProcessedBans[source] = nil
        end)
        if isBanned then
            print("^3  [!]^0 ^6BAN -> Passport: " .. Passport .. " Motivo: "..(printReason or reason).." BanID: "..(BanID or "N/A") .. "^0")
            local message = {
                {
                    ["color"] = 16711680,
                    ["title"] = "**[CERBERUS] PLAYER BANIDO**",
                    ["description"] = "```"..(logs or "N/A").."```",
                    ["fields"] = {
                        {
                            ["name"] = "**ID:**",
                            ["value"] = "**"..Passport.."**",
                            ["inline"] = true
                        },
                        {
                            ["name"] = "**STEAM:**",
                            ["value"] = "**"..License.."**",
                            ["inline"] = true
                        },
                        {
                            ["name"] = "**NOME:**",
                            ["value"] = "**"..GetPlayerName(source).."**",
                            ["inline"] = true
                        },
                        {
                            ["name"] = "**MOTIVO:**",
                            ["value"] = "**"..Reason.."**",
                            ["inline"] = true
                        },
                        {
                            ["name"] = "**TEMPO:**",
                            ["value"] = "**Indefinido**",
                            ["inline"] = true
                        },
                        {
                            ["name"] = "**BAN ID:**",
                            ["value"] = "**"..(BanID and BanID or "Não encontrado").."**",
                            ["inline"] = true
                        }
                    }
                }
            }

            SendWebhook(config.webhook,message)
        end
    end
end

function GetPlayerData(Source)
    if Players[Source] then
        return Players[Source]
    end
    local Passport = vRP.Passport(Source)
    if not Passport then return nil end
    local Identity = vRP.Identity(Passport)
    if not Identity then return nil end

    Players[Source] = {
        Passport = Passport,
        Name = Identity["name"] .. " " .. Identity["name2"],
        License = Identity["license"]
    }

    return Players[Source]
end

AddEventHandler('Connect', function(user_id,Source)
    GetPlayerData(Source)
end)

AddEventHandler('playerDropped', function(reason)
    local source = source
    if Players[source] then
        print("^6Desconectado: "..Players[source].Name.." - "..Players[source].Passport.." Motivo: "..reason.."^0")
        Players[source] = nil
    end
end)


Citizen.CreateThread(function()
    local R = "^1"
    local O = "^0"
    local G = "^2"
    
    print(table.concat({
        "",
        R .. [[
     ██████╗ ███████╗██████╗ ██████╗ ███████╗██████╗ ██╗   ██╗███████╗
    ██╔════╝ ██╔════╝██╔══██╗██╔══██╗██╔════╝██╔══██╗██║   ██║██╔════╝
    ██║      █████╗  ██████╔╝██████╔╝█████╗  ██████╔╝██║   ██║███████╗
    ██║      ██╔══╝  ██╔══██╗██╔══██╗██╔══╝  ██╔══██╗██║   ██║╚════██║
    ╚██████╗ ███████╗██║  ██║██████╔╝███████╗██║  ██║╚██████╔╝███████║
     ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝
        ]] .. O,
        R .. [[
                                /\_/\____,
                      ,___/\_/\ \  ~     /
                      \     ~  \ )   XXX
                        XXX     /    /\_/\___,
                           \o-o/-o-o/   ~    /
                            ) /     \    XXX
                           _|    / \ \_/
                        ,-/   _  \_/   \
                       / (   /____,__|  )
                      (  |_ (    )  \) _|
                     _/ _)   \   \__/   (_
                    (,-(,(,(,/      \,),),)
        ]] .. O,
        G .. "  [+] Sistema Cerberus inicializado com sucesso" .. O,
        G .. "  [+] Proteções carregadas e ativas" .. O,
        "",
    }, "\n"))
end)

