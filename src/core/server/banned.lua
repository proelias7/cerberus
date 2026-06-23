if not config.modules.banned then return end

local CacheBanned = {}
local IndexToken = {}
local IndexIdent = {}
local SourcesLicense = {}

Citizen.CreateThread(function()
    exports.oxmysql:execute([[
        CREATE TABLE IF NOT EXISTS `cerberus_bans` (
            `id` INT(10) NOT NULL AUTO_INCREMENT,
            `license` VARCHAR(50) NULL DEFAULT NULL COLLATE 'latin1_swedish_ci',
            `reason` VARCHAR(255) NULL DEFAULT 'Não informado' COLLATE 'latin1_swedish_ci',
            `time` INT(10) NULL DEFAULT '-1',
            `identys` LONGTEXT NULL DEFAULT NULL COLLATE 'utf8mb4_bin',
            PRIMARY KEY (`id`) USING BTREE,
            INDEX `id` (`id`) USING BTREE,
            INDEX `license` (`license`) USING BTREE,
            CONSTRAINT `cerberus_bans_chk_2` CHECK (json_valid(`identys`))
        )
        COLLATE='latin1_swedish_ci'
        ENGINE=InnoDB
        ROW_FORMAT=DYNAMIC
        AUTO_INCREMENT=881
        ;
    ]])
    exports.oxmysql:execute([[
        CREATE TABLE IF NOT EXISTS `cerberus_identys` (
            `id` INT(10) NOT NULL AUTO_INCREMENT,
            `license` TEXT NOT NULL COLLATE 'utf8mb4_general_ci',
            `identys` LONGTEXT NOT NULL COLLATE 'utf8mb4_general_ci',
            PRIMARY KEY (`id`) USING BTREE,
            INDEX `license` (`license`(768)) USING BTREE,
            INDEX `id` (`id`) USING BTREE
        )
        COLLATE='utf8mb4_general_ci'
        ENGINE=InnoDB
        AUTO_INCREMENT=3876
        ;
    ]])
    Wait(3000)
    LoadCacheBanned()
end)

function SourceLicense(license)
    if SourcesLicense[license] then
        return SourcesLicense[license]
    end
    return false
end

function LoadCacheBanned()
    local tempCache = {}
    local tempIndexToken = {}
    local tempIndexIdent = {}

    local data = exports["oxmysql"]:query_async("SELECT * FROM cerberus_bans")
    Wait(2000)
    for _, v in pairs(data) do
        local decoded = json.decode(v.identys or "{}")
        tempCache[v.license] = {
            id = v.id,
            time = v.time,
            reason = v.reason,
            identys = decoded
        }

        for _, token in pairs(decoded.tokens or {}) do
            tempIndexToken[token] = v.license
        end

        for _, ident in pairs(decoded.identis or {}) do
            if not string.find(ident, "ip") then
                tempIndexIdent[ident] = v.license
            end
        end
    end
    
    CacheBanned = tempCache
    IndexToken = tempIndexToken
    IndexIdent = tempIndexIdent

    tempCache = nil
    tempIndexToken = nil
    tempIndexIdent = nil
    print("^2  [+]^0 ^6Cache de bans carregada (cerberus)^0")
end

function DeleteCacheBanned(license)
    local ban = CacheBanned[license]
    if not ban then return end

    exports.oxmysql:executeSync("DELETE FROM cerberus_bans WHERE license = ?", { license })

    for _, token in pairs(ban.identys.tokens or {}) do
        IndexToken[token] = nil
    end
    for _, ident in pairs(ban.identys.identis or {}) do
        IndexIdent[ident] = nil
    end

    CacheBanned[license] = nil
end

function UpdateCacheBanned(license)
    Wait(2000)
    local data = exports["oxmysql"]:query_async("SELECT * FROM cerberus_bans WHERE license = ?", { license })
    if data[1] then
        print("^2  [+]^0 ^6Cache sincronizada (cerberus)^0")
        local decoded = json.decode(data[1].identys or "{}")

        CacheBanned[license] = { id = data[1].id, time = data[1].time, reason = data[1].reason, identys = decoded }

        for _,token in pairs(decoded.tokens or {}) do
            IndexToken[token] = license
        end
        for _,ident in pairs(decoded.identis or {}) do
            if not string.find(ident,"ip") then
                IndexIdent[ident] = license
            end
        end
    end
end

function InsertCacheBanned(license,time,reason,identys)
    local ban = CacheBanned[license]
    if ban then
        print("^3  [!]^0 ^6Licença já constava banida — atualizando^0")
        CacheBanned[license] = { id = ban.id, time = time, reason = reason, identys = identys }
        exports["oxmysql"]:executeSync("UPDATE cerberus_bans SET reason = ?, time = ?, identys = ? WHERE license = ?", { reason, time, json.encode(identys), license })
        
        for _,token in pairs(identys.tokens or {}) do
            IndexToken[token] = license
        end
        for _,ident in pairs(identys.identis or {}) do
            if not string.find(ident,"ip") then
                IndexIdent[ident] = license
            end
        end
        print("^2  [+]^0 ^6Cache em memória — índices atualizados^0")
    else
        print("^2  [+]^0 ^6Banco de dados — " .. tostring(license) .. " · " .. tostring(reason) .. "^0")
        exports["oxmysql"]:executeSync("INSERT INTO cerberus_bans(license,reason,time,identys) VALUES(?,?,?,?)", { license, reason, time, json.encode(identys) })
        UpdateCacheBanned(license)
    end
end

function Banned(license, returnID, source)
    local now = os.time()
    local ban = CacheBanned[license] or nil
    if ban then
        if ban.time ~= -1 and ban.time <= now then
            DeleteCacheBanned(license)
            local fields = {
                {
                    name = "**IDENTIFICAÇÃO DO ADMIN:**",
                    value = "**ID:** [**"..license.."**]"
                },
                {
                    name = "**IDENTIFICAÇÃO DO PLAYER:**",
                    value = "**ID:** [**"..source.."**]"
                },
                {
                    name = "**MOTIVO:**",
                    value = "**"..ban.reason.."**"
                }
            }
            exports["webhook"]:Send("unban","BANIMENTO REMOVIDO:",fields)
            return false, false, ban.reason
        end
        return true, (returnID and ban.id or false), ban.reason
    end

    local identys = GetIdentys(license, source)
    if not identys then return false, false end

    -- verifica tokens
    for _, token in pairs(identys.tokens or {}) do
        local lic = IndexToken[token]
        if lic and CacheBanned[lic] then
            return true, (returnID and CacheBanned[lic].id or false), CacheBanned[lic].reason
        end
    end

    -- verifica identidades (exceto IP)
    for _, ident in pairs(identys.identis or {}) do
        if not string.find(ident, "ip") then
            local lic = IndexIdent[ident]
            if lic and CacheBanned[lic] then
                return true, (returnID and CacheBanned[lic].id or false), CacheBanned[lic].reason
            end
        end
    end

    return false, false
end

local BL = "^6"
local BR = "^6══════════════════════════════════════════════════════════^0"

function BanTokens(license, banned, reason, time, source)
    if banned == 1 or banned == true then
        local buf = { "", BR, BL .. "  Banimento^0", BR }

        local identys = GetIdentys(license,source)
        if identys then
            table.insert(buf, "  " .. BL .. tostring(license) .. " · " .. tostring(reason) .. " · tempo " .. tostring(time) .. "^0")
            table.insert(buf, "^2  [+]^0 ^41.^0 " .. BL .. "Identidades coletadas^0")
            local tempo = -1
            if time ~= nil and time > 0 then 
                tempo = tonumber(os.time()) + 86400 * tonumber(time)
                table.insert(buf, "^2  [+]^0 ^42.^0 " .. BL .. "Prazo do ban — " .. os.date("%d/%m/%Y %H:%M", tempo) .. " (unix " .. tostring(tempo) .. ")^0")
            else
                table.insert(buf, "^2  [+]^0 ^42.^0 " .. BL .. "Prazo do ban — permanente^0")
            end

            if not reason then 
                reason = 'Não informado'
                table.insert(buf, "^3  [!]^0 ^43.^0 " .. BL .. "Motivo — padrão (não informado)^0")
            else
                table.insert(buf, "^2  [+]^0 ^43.^0 " .. BL .. "Motivo — " .. reason .. "^0")
            end

            print(table.concat(buf, "\n"))

            InsertCacheBanned(license,tempo,reason,identys)

            local Player = source or SourceLicense(license)
            if Player then
                print("  " .. BL .. "Kick -> source " .. tostring(Player) .. "^0")
                DropPlayer(Player,'Você foi banido da cidade! MOTIVO: '..reason..' TEMPO: '..(tempo == -1 and "Indefinido" or time..' Dias'))
                print("^2  [+]^0 " .. BL .. "Sessão encerrada (kick)^0")
            else
                print("  " .. BL .. "Nenhuma sessão ativa (kick ignorado)^0")
            end
            
            print(BR)
            return Banned(license,true,source)
        else
            table.insert(buf, "^1  [-]  Falha ao obter identidades do jogador^0")
            table.insert(buf, BR)
            print(table.concat(buf, "\n"))
            return false
        end
    elseif banned == 0 or not banned then
        local buf = { "", BR, BL .. "  Desbanimento^0", BR }
        table.insert(buf, "  " .. BL .. tostring(license) .. "^0")
        
        if Banned(license) then
            table.insert(buf, "^2  [+]^0 ^41.^0 " .. BL .. "Removendo registro^0")
            DeleteCacheBanned(license)
            table.insert(buf, "^2  [+]^0 ^42.^0 " .. BL .. "Desbanido — cache e banco limpos^0")
            table.insert(buf, BR)
            print(table.concat(buf, "\n"))
            return true
        else
            table.insert(buf, "  " .. BL .. "Nada a remover (não estava banido)^0")
            table.insert(buf, BR)
            print(table.concat(buf, "\n"))
        end
    end
    
    print("^3  [!]  Nenhuma ação · " .. tostring(license) .. "^0")
    return false
end

function GetLicenseBanID(id)
    local CowBanned = exports["oxmysql"]:query_async("SELECT license FROM cerberus_bans WHERE id = ?", { id })
    if CowBanned[1] then
        return CowBanned[1].license or nil
    end
    return nil
end

function GetIdentys(license, source)
    local identys = { ['tokens'] = {}, ['identis'] = {} }
    local Player = source or SourceLicense(license)
	if Player then
        for i = 0, GetNumPlayerTokens(Player) - 1 do
            identys['tokens'][i] = GetPlayerToken(Player, i)
        end

        for i = 0, GetNumPlayerIdentifiers(Player) - 1 do
            identys['identis'][i] = GetPlayerIdentifier(Player, i)
        end

        if identys['tokens'] or identys['identis'] then
            if type(identys) == "table" then
                if next(identys['tokens']) or next(identys['identis']) then
                    return identys
                else
                    local data = exports["oxmysql"]:query_async("SELECT identys FROM cerberus_identys WHERE license = ?", { license })
                    if data[1] and data[1].identys then
                        identys = json.decode(data[1].identys)
                        return identys
                    end 
                end
            end
        else
            local data = exports["oxmysql"]:query_async("SELECT identys FROM cerberus_identys WHERE license = ?", { license })
            if data[1] and data[1].identys then
                identys = json.decode(data[1].identys)
                return identys
            end
        end
    else
        local data = exports["oxmysql"]:query_async("SELECT identys FROM cerberus_identys WHERE license = ?", { license })
	    if data[1] and data[1].identys then
            identys = json.decode(data[1].identys)
			return identys
		end
	end
	return false
end

function SetIdentys(license, source)
    local Player = source or SourceLicense(license)
    if Player then
        local identys = { ['tokens'] = {}, ['identis'] = {} }

        local data = exports["oxmysql"]:query_async("SELECT license FROM cerberus_identys WHERE license = ?", { license })
        if data[1] == nil then
            for i = 0, GetNumPlayerTokens(Player) - 1 do
                identys['tokens'][i] = GetPlayerToken(Player, i)
            end

            for i = 0, GetNumPlayerIdentifiers(Player) - 1 do
                identys['identis'][i] = GetPlayerIdentifier(Player, i)
            end

            exports["oxmysql"]:execute("INSERT INTO cerberus_identys(license,identys) VALUES(?,?)", { license, json.encode(identys) })
            return true
        end
    end
    return false
end


exports("SourceLicense", SourceLicense)
exports("LoadCacheBanned", LoadCacheBanned)
exports("Banned", Banned)
exports("BanTokens", BanTokens)
exports("GetLicenseBanID", GetLicenseBanID)
exports("GetIdentys", GetIdentys)
exports("SetIdentys", SetIdentys)