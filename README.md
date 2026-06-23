# Cerberus Load Balance

## Objetivo

O `cerberus` centraliza o envio de payloads grandes do servidor para os clients, evitando que cada resource implemente seu proprio sistema de chunk, fila, prioridade e remontagem.

O objetivo e:

- reduzir duplicacao de codigo
- manter um padrao unico de sincronismo
- diminuir risco de sobrecarga de rede
- facilitar manutencao e tuning de performance

## Fluxo

O fluxo de sincronismo funciona assim:

1. O script server chama um export do `cerberus`
2. O `cerberus` decide como transportar o payload
3. O client do `cerberus` recebe e monta os dados quando necessario
4. O `cerberus` dispara um `TriggerEvent` local para o script consumidor

Resumo:

```text
server do resource -> cerberus server -> rede -> cerberus client -> TriggerEvent local -> client do resource
```

Importante:

- o trecho `cerberus client -> TriggerEvent local` nao gera trafego extra de rede
- quem controla chunking, fila, prioridade e latent event e o `cerberus`
- o script consumidor recebe apenas o evento final

## Como o transporte e escolhido

O `cerberus` escolhe automaticamente a estrategia:

- payload pequeno: envio direto
- payload grande para um unico player: `TriggerLatentClientEvent`
- payload grande para muitos players: fila com chunking e pacing

Quando `coords` e `range` sao informados:

- players dentro do raio recebem primeiro
- players fora do raio continuam recebendo, mas com prioridade menor

## Tipos de sincronismo

### Full Sync

Use para bootstrap ou cache completo.

Exemplos:

- player entrou no servidor e precisa receber todos os baus
- resource recarregou um cache inteiro
- houve rebuild completo de um estado compartilhado

Comportamento:

- pensado para payload grande
- substitui envio pendente anterior da mesma chave
- preserva o estado mais novo

Export:

```lua
exports["cerberus"]:SendFullSync(targets, eventName, payload, options)
```

Alias:

```lua
exports["cerberus"]:SyncFull(targets, eventName, payload, options)
```

### Delta Sync

Use para atualizar apenas uma parte do estado.

Exemplos:

- editou um bau
- deletou um bau
- atualizou uma unica rota
- alterou uma unica entrada do cache

Comportamento:

- pensado para payload pequeno ou unitario
- nao substitui pendencias por padrao
- evita perder atualizacoes intermediarias

Export:

```lua
exports["cerberus"]:SendDeltaSync(targets, eventName, payload, options)
```

Alias:

```lua
exports["cerberus"]:SyncDelta(targets, eventName, payload, options)
```

## Export generico

Tambem existe o export generico:

```lua
exports["cerberus"]:SendBalancedPayload(targets, eventName, payload, options)
```

Alias:

```lua
exports["cerberus"]:QueueBalancedPayload(targets, eventName, payload, options)
```

Use esse formato quando quiser controle manual do comportamento.

## Parametros

### `targets`

Pode ser:

- `source`
- `-1` para todos os players conectados
- tabela com varios `source`

### `eventName`

Evento final que o script client consumidor vai receber.

### `payload`

Tabela ou estrutura serializavel em JSON.

### `options`

Campos suportados:

- `key`: chave logica do job
- `coords`: coordenada para priorizacao espacial
- `range`: raio para separar players prioritarios
- `scopeRadius`: quando usado com `coords` e targets `-1`, filtra targets para apenas players dentro do raio usando o sistema de scope espacial. Players fora do raio nao recebem o evento. Util para eventos que so fazem sentido para players proximos (ex: modificacoes visuais de veiculos)
- `replacePending`: define se deve substituir pendencia anterior
- `syncKind`: usado para logs e semantica do job

## Regras recomendadas

- use `SendFullSync` para cache completo
- use `SendDeltaSync` para update unitario
- nao faca chunking manual dentro dos scripts consumidores
- envie apenas dados que o client realmente precisa
- prefira delta em vez de full sync sempre que possivel
- use `coords` e `range` quando o dado for relevante por proximidade
- use `scopeRadius` quando o evento so e relevante para players proximos

## Exemplo de Full Sync

```lua
local ok, requestId = exports["cerberus"]:SendFullSync(
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

No client:

```lua
RegisterNetEvent("chest:fullSync")
AddEventHandler("chest:fullSync", function(payload)
    allChests = payload
    CreateTargetZones()
end)
```

## Exemplo de Delta Sync

```lua
exports["cerberus"]:SendDeltaSync(
    -1,
    "chest:updateChest",
    chestData
)
```

No client:

```lua
RegisterNetEvent("chest:updateChest")
AddEventHandler("chest:updateChest", function(chestData)
    allChests[chestData.name] = chestData
    UpdateTargetZones(chestData.name)
end)
```

## Caso de delete

Para delecao, o padrao recomendado e enviar um delta pequeno:

```lua
exports["cerberus"]:SendDeltaSync(
    -1,
    "chest:deleteChest",
    { name = chestName }
)
```

No client:

```lua
RegisterNetEvent("chest:deleteChest")
AddEventHandler("chest:deleteChest", function(data)
    allChests[data.name] = nil
    CreateTargetZones()
end)
```

## Logs

O `cerberus` escreve logs no console quando um job:

- inicia
- termina

Os logs mostram:

- `request`
- `sync`
- `event`
- `transport`
- `targets`
- `near`
- `far`
- `payloadBytes`
- `elapsedMs`
- `key`

Exemplo:

```text
[cerberus][loadbalance][start] request=123 sync=full event=chest:fullSync transport=chunk targets=80 near=12 far=68 payloadBytes=48120 key=inventory:chests:full
[cerberus][loadbalance][finish] request=123 sync=full event=chest:fullSync transport=chunk targets=80 delivered=80 payloadBytes=48120 elapsedMs=1732 key=inventory:chests:full
```

Observacao:

- o log de `finish` significa que o servidor terminou de despachar o job
- ele nao confirma aplicacao final no script consumidor

## Cenarios comuns

### Player entrou depois do servidor iniciado

Use `SendFullSync(source, ...)`.

Esse e o caso de bootstrap de estado para um unico player.

### Editou apenas um item do cache

Use `SendDeltaSync(-1, ...)`.

Esse e o caso ideal para evitar reenviar o cache inteiro.

### Atualizacao relevante por proximidade

Use `coords` e `range`.

Players proximos recebem primeiro. Os demais recebem depois.

### Evento exclusivo para players proximos (scope)

Use `coords`, `scopeRadius` e targets `-1`.

Players fora do raio nao recebem o evento. Exemplo:

```lua
local coords = GetEntityCoords(vehicle)
exports["cerberus"]:SendDeltaSync(
    -1,
    "meuResource:meuEvento",
    payload,
    {
        coords = coords,
        scopeRadius = 200.0,
        range = 100.0
    }
)
```

Diferenca entre `range` e `scopeRadius`:

- `range`: prioriza players proximos, mas todos recebem
- `scopeRadius`: filtra targets, apenas players dentro do raio recebem

Podem ser usados juntos: `scopeRadius` filtra quem recebe, `range` prioriza a ordem de entrega entre os que recebem.

## O que evitar

- criar chunking manual em cada script
- usar full sync para toda alteracao pequena
- reenviar cache completo quando apenas uma entrada mudou
- tratar o client consumidor como responsavel por logica de balanceamento

## Recomendacao de arquitetura

Scripts como `inventory`, `routes`, `nation` e similares devem:

- manter apenas a logica de negocio
- preparar o payload final
- chamar o export do `cerberus`

O `cerberus` deve:

- controlar transporte
- controlar fila
- controlar prioridade
- montar payload fragmentado no client
- disparar o evento local final

