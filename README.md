# Cerberus

Recurso modular para servidores FiveM (vRP). Centraliza sincronismo de payloads grandes, protecao anti-exploit em eventos server e rate-limit no client.

## Modulos

| Modulo | Ativacao | Descricao |
|--------|----------|-----------|
| **Load Balance** | sempre ativo | Envio balanceado server → client (`SendFullSync`, `SendDeltaSync`, etc.) |
| **SafeEvent** | `config.modules.safeEvent` | Anti-exploit em eventos server (cooldown, posicao, ban) |
| **SetCooldown** | sempre no client | Rate-limit local para menus, NUI e acoes repetitivas |
| **Banned** | `config.modules.banned` | Cache e API de banimentos (`cerberus_bans`) |
| **Analytics** | `config.modules.analytics` | Monitoramento de eventos, payloads e flood |
| **Scope** | interno | Filtro espacial usado pelo load balance (`scopeRadius`) |

## Instalacao

```cfg
ensure oxmysql
ensure cerberus
```

Coloque o `cerberus` **antes** dos resources que dependem dos exports.

Dependencias: `oxmysql`, `vrp` (Proxy/Tunnel para Passport, ban e notify).

## Configuracao

Arquivo: `config/config.lua`

```lua
config.modules = {
    banned = false,
    safeEvent = true,
    analytics = true,
}

config.defaultTime = 30        -- intervalo padrao do SafeEvent (segundos)
config.interPorDetect = 15     -- janela para contar suspeitas
config.suspectCount = 4        -- suspeitas totais para auto-ban
config.blockThreshold = 1      -- suspeitas por evento antes de bloquear
config.logThreshold = 1        -- suspeitas por evento antes de log no console
config.webhook = ""            -- webhook opcional
config.BlackListEvents = { }   -- eventos que banem ao serem disparados
```

---

## Load Balance

### Objetivo

O `cerberus` centraliza o envio de payloads grandes do servidor para os clients, evitando que cada resource implemente seu proprio sistema de chunk, fila, prioridade e remontagem.

Beneficios:

- reduzir duplicacao de codigo
- manter um padrao unico de sincronismo
- diminuir risco de sobrecarga de rede
- facilitar manutencao e tuning de performance

### Fluxo

1. O script server chama um export do `cerberus`
2. O `cerberus` decide como transportar o payload
3. O client do `cerberus` recebe e monta os dados quando necessario
4. O `cerberus` dispara um `TriggerEvent` local para o script consumidor

```text
server do resource -> cerberus server -> rede -> cerberus client -> TriggerEvent local -> client do resource
```

Importante:

- o trecho `cerberus client -> TriggerEvent local` nao gera trafego extra de rede
- quem controla chunking, fila, prioridade e latent event e o `cerberus`
- o script consumidor recebe apenas o evento final

### Como o transporte e escolhido

- payload pequeno: envio direto
- payload grande para um unico player: `TriggerLatentClientEvent`
- payload grande para muitos players: fila com chunking e pacing

Quando `coords` e `range` sao informados:

- players dentro do raio recebem primeiro
- players fora do raio continuam recebendo, mas com prioridade menor

### Exports

| Export | Uso |
|--------|-----|
| `SendFullSync(targets, eventName, payload, options)` | Bootstrap / cache completo |
| `SendDeltaSync(targets, eventName, payload, options)` | Update ou delete unitario |
| `SendBalancedPayload(targets, eventName, payload, options)` | Controle manual do comportamento |
| `SendAsyncClient(eventName, ...)` | Dispara `TriggerClientEvent` para todos com pacing de 20ms |

### Parametros

**`targets`:** `source`, `-1` ou tabela de sources.

**`eventName`:** evento final que o client consumidor recebe.

**`payload`:** tabela serializavel em JSON.

**`options`:**

| Campo | Descricao |
|-------|-----------|
| `key` | chave logica do job |
| `coords` | coordenada para priorizacao espacial |
| `range` | raio para separar players prioritarios |
| `scopeRadius` | com `coords` e `-1`, so players dentro do raio recebem |
| `replacePending` | substitui job pendente da mesma chave |
| `syncKind` | semantica do job (logs) |

Diferenca entre `range` e `scopeRadius`:

- `range`: prioriza players proximos, mas todos recebem
- `scopeRadius`: filtra targets; apenas players dentro do raio recebem

### Exemplo — Full Sync

```lua
exports["cerberus"]:SendFullSync(
    source,
    "chest:fullSync",
    chestCacheSanitized,
    {
        key = "inventory:chests:full",
        coords = GetEntityCoords(GetPlayerPed(source)),
        range = 150.0
    }
)
```

Client:

```lua
RegisterNetEvent("chest:fullSync")
AddEventHandler("chest:fullSync", function(payload)
    allChests = payload
    CreateTargetZones()
end)
```

### Exemplo — Delta Sync

```lua
exports["cerberus"]:SendDeltaSync(-1, "chest:updateChest", chestData)

exports["cerberus"]:SendDeltaSync(-1, "chest:deleteChest", { name = chestName })
```

### Exemplo — Scope (apenas players proximos)

```lua
exports["cerberus"]:SendDeltaSync(-1, "meuResource:meuEvento", payload, {
    coords = GetEntityCoords(vehicle),
    scopeRadius = 200.0,
    range = 100.0
})
```

### Regras recomendadas

- use `SendFullSync` para cache completo / bootstrap
- use `SendDeltaSync` para update unitario
- nao faca chunking manual nos scripts consumidores
- envie apenas dados que o client realmente precisa
- prefira delta em vez de full sync sempre que possivel

### Logs

```text
[cerberus][loadbalance][start] request=123 sync=full event=chest:fullSync transport=chunk targets=80 ...
[cerberus][loadbalance][finish] request=123 sync=full event=chest:fullSync transport=chunk targets=80 delivered=80 ...
```

O log de `finish` significa que o servidor terminou de despachar o job — nao confirma aplicacao no script consumidor.

---

## SafeEvent (server)

Requer `config.modules.safeEvent = true`.

Protege eventos que dao vantagem (dinheiro, item, XP, veiculo, bypass). Retorna `true` = **bloqueado**, `false` = permitido.

```lua
exports["cerberus"]:SafeEvent(source, eventName, options)
```

### Opcoes

| Campo | Tipo | Padrao | Descricao |
|-------|------|--------|-----------|
| `time` | number | `config.defaultTime` | Intervalo minimo entre execucoes (segundos) |
| `noBan` | boolean | `false` | Se `true`, nao aplica auto-ban |
| `position` | boolean | `false` | Verifica distancia entre acoes |
| `positionDist` | number | `100` | Distancia minima em metros quando `position=true` |
| `notification` | boolean | `false` | Notifica o player ao bloquear |
| `blockThreshold` | number | `config.blockThreshold` | Suspeitas por evento antes de bloquear |
| `logThreshold` | number | `config.logThreshold` | Suspeitas por evento antes de log no console |
| `silentLog` | boolean | `false` | Registra internamente sem print |
| `interPorDetect` | number | `config.interPorDetect` | Janela para contar suspeitas |
| `suspectCount` | number | `config.suspectCount` | Suspeitas totais para auto-ban |
| `data` | any | `nil` | Dado extra para logs |

### Exemplo — evento de vantagem

```lua
RegisterServerEvent("shop:buy")
AddEventHandler("shop:buy", function(itemId)
    local source = source
    if not source then return end

    if exports["cerberus"]:SafeEvent(source, "shop:buy", {
        time = 10,
        position = true,
        positionDist = 2
    }) then
        return
    end

    -- validacao server + conceder recompensa
end)
```

### Exemplo — flood / evento sensivel a DB

```lua
if exports["cerberus"]:SafeEvent(source, "requestInventory", {
    time = 2,
    noBan = true,
    notification = true,
    blockThreshold = 3
}) then
    return
end
```

### BlackListEvents

Eventos listados em `config.BlackListEvents` aplicam ban automatico ao serem disparados.

### Debug

Console do servidor:

```text
debugexploit
```

Alterna logs detalhados do SafeEvent.

> **Regra:** `SafeEvent` complementa — nao substitui — validacao server (permissao, distancia, item, preco).

---

## SetCooldown (client)

Rate-limit no **client**. Tempo em **milissegundos**. Retorna `true` = **bloqueado**.

```lua
exports["cerberus"]:SetCooldown(name, time, hits)
```

| Parametro | Descricao |
|-----------|-----------|
| `name` | Identificador unico da acao |
| `time` | Duracao do cooldown em ms |
| `hits` | (opcional) Numero de tentativas antes de bloquear por `time` ms |

### Exemplos

```lua
-- Por tempo
if exports["cerberus"]:SetCooldown("open:inventory", 3000) then
    return
end

-- Por tentativas: 3 hits, depois bloqueia por 5s
if exports["cerberus"]:SetCooldown("use:item", 5000, 3) then
    return
end
```

```lua
RegisterNUICallback("buy", function(data, cb)
    if exports["cerberus"]:SetCooldown("shop:buy", 2000) then
        cb("blocked")
        return
    end
    TriggerServerEvent("shop:buy", data.item)
    cb("ok")
end)
```

Ao bloquear, exibe notify automatico: `Aguarde X segundos para executar a acao novamente.`

---

## SafeEvent vs SetCooldown

| | SafeEvent | SetCooldown |
|---|-----------|-------------|
| Lado | Server | Client |
| Proposito | Anti-exploit | Rate-limit de spam |
| Ao detectar | Bloqueia e/ou bane | Bloqueia temporariamente |
| Unidade de tempo | Segundos | Milissegundos |

| Situacao | Use |
|----------|-----|
| Evento server com dinheiro/item/XP | `SafeEvent` |
| Abrir menu / NUI / spam de item | `SetCooldown` |
| Sync grande server → client | `SendFullSync` / `SendDeltaSync` |

---

## Banned (opcional)

Requer `config.modules.banned = true` e tabelas `cerberus_bans` / `cerberus_identys` (criadas automaticamente).

| Export | Descricao |
|--------|-----------|
| `Banned(license, returnID?, source?)` | Verifica se license/identificadores estao banidos |
| `BanTokens(license, banned, reason, time, source)` | Aplica ou remove ban |
| `LoadCacheBanned()` | Recarrega cache de bans |
| `SourceLicense(license)` | Source associado a license |
| `GetLicenseBanID(license)` | ID do ban |
| `GetIdentys(license, source)` / `SetIdentys(license, source)` | Identificadores do player |

O SafeEvent usa `SetBan` internamente quando `noBan = false`.

---

## Analytics (opcional)

Requer `config.modules.analytics = true`.

Monitora automaticamente:

- tamanho de payloads (warning/critical)
- flood de eventos por source
- alteracoes de StateBag

Export manual para instrumentacao:

```lua
exports["cerberus"]:hit(resourceName, eventName, isGlobal, payloadSize)
```

---

## Scope (interno)

Exports usados pelo load balance e por outros modulos:

```lua
exports["cerberus"]:PlayersScope(coords, radius)
exports["cerberus"]:PlayersScopeCoords(coords, radius)
```

Retornam lista de `source` dentro do raio.

---

## Recomendacao de arquitetura

Scripts como `inventory`, `routes`, `nation` e similares devem:

- manter apenas a logica de negocio
- preparar o payload final
- chamar o export do `cerberus`

O `cerberus` deve:

- controlar transporte, fila e prioridade (load balance)
- proteger eventos de vantagem (`SafeEvent`)
- limitar spam no client (`SetCooldown`)

### O que evitar

- chunking manual em cada script
- full sync para toda alteracao pequena
- confiar apenas no client para validacao de vantagem
- reenviar cache completo quando apenas uma entrada mudou
