# rodz-fazenda

Sistema de fazenda para FiveM (Qbox) com currais, animais, comedouro/bebedouro e venda por caminhao.

## Dependencias

- `qbx_core`
- `ox_lib`
- `ox_target`
- `ox_inventory`
- `oxmysql`

## Instalacao

1. Coloque a pasta em `resources/[rodz]/rodz-fazenda`.
2. Execute `sql/install.sql` no banco.
3. No `server.cfg`, garanta:

```cfg
ensure rodz-fazenda
```

## Resumo de gameplay atual

- Admin cria fazendas e define area, NPC comprador e ponto do caminhao.
- Cartel cria currais de vaca/porco e vagas de spawn.
- Animais ativos spawnam no cliente e ficam dentro da area do curral.
- Vacas e porcos usam comedouro/bebedouro do curral.
- Venda de animais e feita pelo caminhao boiadeiro.

## Regras atuais de alimentacao

- A vaca **nao** e alimentada diretamente no target.
- Para vacas, coloque racao no comedouro do curral.
- Consumo da vaca ocorre por necessidade (nao por timer fixo):
  - 1 saco por consumo (`Config.CowAutoFeed.itemQtyPerCycle`)
  - +5% de fome por saco (`Config.CowAutoFeed.hungerGainPercentPerCycle`)
- Notificacao de consumo vai para o lider do cartel, incluindo:
  - fazenda/curral
  - quantidade consumida
  - racao restante no comedouro

## Capacidade de abastecimento

- Comedouro: `1000 kg`
- Bebedouro: `1000 litros`

Configuracao:

```lua
Config.CorralSupply = {
    feedCapacityKg = 1000,
    waterCapacityLiters = 1000,
}
```

## Compra de animais

- Compra de vaca e porco exige **dinheiro sujo** (`black_money` por padrao).
- Se nao tiver saldo, retorna notify de erro.

Configuracao atual:

```lua
Config.Payments = {
    cowBuy = 5000,
    pigBuy = 800,
    cowBuyDirtyItem = 'black_money',
}
```

## Preco de venda da vaca por idade

- Preco inicial: `3000`
- A cada `24h` de vida: `+1000`
- Teto: `8000`

Configuracao:

```lua
Config.Payments = {
    cowSellStart = 3000,
    cowSellMax = 8000,
    cowSellAgeStepHours = 24,
    cowSellAgeStepValue = 1000,
}
```

Formula aplicada:

```text
preco = min(cowSellMax, cowSellStart + floor(horas_de_vida / cowSellAgeStepHours) * cowSellAgeStepValue)
```

## Status dos animais

No target "Ver status", a vaca mostra:

- fome
- saude
- idade em dias

## Caminhao boiadeiro

- O motorista desce do caminhao e a interacao principal fica no NPC motorista.
- O caminhao foi ajustado para parar no ponto de entrega com mais precisao.
- A venda final e confirmada na interacao com o motorista.

## Config principal (referencia rapida)

Arquivo: `config.lua`

```lua
Config.CartelGang = 'cartel'
Config.TargetDistance = 2.5

Config.Items = {
    feed = 'racao',
    medicine = 'remedio_animal',
    milk = 'leite',
    water = 'water_bottle',
}

Config.CowAutoFeed = {
    itemQtyPerCycle = 1,
    hungerGainPercentPerCycle = 5,
    itemKgUnit = 0.5,
}
```

## Observacoes

- Warnings de `Undefined global` no VSCode (CreateThread, Wait, joaat etc.) sao esperados em script FiveM.
- O estado de animal e validacoes sensiveis ficam no servidor.

