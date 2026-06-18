# rodz-fazenda

Sistema completo de fazendas para FiveM com framework **QBX (Qbox)** + **ox_lib** + **ox_target** + **ox_inventory**.

---

## Funcionalidades

### Propriedade
- Fazendas criadas pelo admin/cartel e compradas por jogadores
- Dono define o preço de venda para outros jogadores
- Transferência de propriedade entre players
- Cancelamento de listagem de venda

### Currais
- Criação e edição de currais por fazenda (tipo: vaca ou porco)
- Definição de área, pontos de spawn de animais, comedouros e bebedouros
- Estoque de ração e água por curral em tempo real

### Animais
- Compra de vacas e porcos via loja (dinheiro sujo)
- Sistema de saúde, fome e sede com degradação ao longo do tempo
- Alimentação e hidratação via estoque do curral
- Ordenha de vacas (apenas quando fome/sede em níveis adequados)
- Remédio para animais doentes

### Vendas
- Venda de leite exclusiva para o dono da fazenda
- Venda de vacas e porcos via caminhão boiadeiro
- Preço da vaca escalonado com a idade do animal

### Equipe
- Dono contrata players por ID de servidor ou citizenid
- Cargos: **Ajudante**, **Vaqueiro**, **Capataz**, **Supervisor**, **Gerente**
- Salário individual por funcionário
- Salários debitados automaticamente da conta do dono a cada ciclo configurável
- Demissão e edição de cargo/salário a qualquer momento

### NUI (Tablet)
- Interface tablet com 5 abas: **Geral**, **Animais**, **Loja**, **Vendas**, **Equipe**
- Design responsivo com suporte a cor de acento via convar `mri:color`
- Notificações integradas via `ox_lib`

---

## Dependências

| Resource | Link |
|---|---|
| ox_lib | https://github.com/overextended/ox_lib |
| ox_target | https://github.com/overextended/ox_target |
| ox_inventory | https://github.com/overextended/ox_inventory |
| oxmysql | https://github.com/overextended/oxmysql |
| qbx_core | https://github.com/Qbox-project/qbx_core |
| fivem-freecam | https://github.com/Deltanic/fivem-freecam |

---

## Instalação

### 1. Banco de dados

Execute `sql/install.sql` no seu banco MySQL/MariaDB.  
As tabelas também são criadas automaticamente na inicialização do resource caso não existam.

Tabelas criadas:

| Tabela | Descrição |
|---|---|
| `rfz_farms` | Fazendas |
| `rfz_corrals` | Currais |
| `rfz_inventory` | Inventário da fazenda |
| `rfz_animals` | Animais individuais |
| `rfz_employees` | Funcionários |

### 2. Itens (ox_inventory)

Adicione os itens ao seu `ox_inventory/data/items.lua`:

```lua
['leite']           = { label = 'Leite',         weight = 500,  stack = true },
['racao_animal']    = { label = 'Ração Animal',   weight = 1000, stack = true },
['agua_animal']     = { label = 'Água Animal',    weight = 500,  stack = true },
['remedio_animal']  = { label = 'Remédio Animal', weight = 200,  stack = true },
```

> Os nomes dos itens são configuráveis em `config.lua` → `Config.Items`.

### 3. server.cfg

```
ensure rodz-fazenda
```

---

## Configuração

```lua
Config.CartelGang          = 'cartel'       -- grupo com acesso ao modo criador
Config.MaxEmployees        = 10             -- limite de funcionários por fazenda
Config.SalaryIntervalMinutes = 60           -- intervalo de pagamento de salário (minutos)
Config.TargetDistance      = 2.5            -- distância de interação ox_target

Config.Items = {
    milk     = 'leite',
    feed     = 'racao_animal',
    water    = 'agua_animal',
    medicine = 'remedio_animal',
}

Config.Payments = {
    account              = 'bank',    -- conta do dono usada para salários
    cowBuy               = 5000,      -- preço de compra de vaca (dinheiro sujo)
    pigBuy               = 3000,      -- preço de compra de porco
    feedBuy              = 200,       -- preço do saco de ração
    waterBuy             = 100,       -- preço do balde de água
    medicineBuy          = 500,       -- preço do remédio
    milkSell             = 150,       -- preço por unidade de leite
    cowSellStart         = 8000,      -- preço inicial de venda de vaca
    cowSellMax           = 25000,     -- teto de preço por idade
    cowSellAgeStepHours  = 24,        -- horas por escalão de preço
    cowSellAgeStepValue  = 1000,      -- valor adicionado por escalão
    pigSell              = 4500,      -- preço de venda de porco
}

Config.CorralSupply = {
    feedCapacityKg      = 1000,
    waterCapacityLiters = 1000,
}
```

### Fórmula de preço da vaca por idade

```
preço = min(cowSellMax, cowSellStart + floor(horas_de_vida / cowSellAgeStepHours) * cowSellAgeStepValue)
```

---

## Estrutura de Arquivos

```
rodz-fazenda/
├── client/
│   ├── main.lua        # lógica principal (NUI, targets, spawns)
│   ├── creator.lua     # menus admin para criar/editar fazendas
│   ├── manager.lua     # edição de currais e zonas
│   └── truck.lua       # caminhão boiadeiro (client)
├── server/
│   ├── main.lua        # criação das tabelas SQL e evento de startup
│   ├── farms.lua       # CRUD de fazendas, currais, funcionários, callbacks
│   ├── animals.lua     # lógica de animais, timer de saúde, venda de leite
│   ├── utils.lua       # helpers (GetCitizenId, GetSourceByCitizenId)
│   └── truck.lua       # callbacks de venda por caminhão
├── modules/
│   ├── preview.lua     # sistema de posicionamento com ghost entity
│   └── polyzone.lua    # zonas poligonais
├── html/
│   ├── index.html      # estrutura da NUI tablet
│   ├── app.js          # lógica da NUI
│   └── style.css       # estilos
├── sql/
│   └── install.sql     # script de criação manual das tabelas
├── config.lua
└── fxmanifest.lua
```

---

## Permissões

A criação e gerenciamento de fazendas requer pertencer ao grupo definido em `Config.CartelGang`. Edite a função `isCartel()` em `client/main.lua` conforme sua configuração de grupos.

---

## Observações

- Avisos de `Undefined global` no VSCode (`CreateThread`, `Wait`, `joaat`, etc.) são esperados em scripts FiveM — não afetam o funcionamento.
- Toda validação sensível (venda, contratação, salário) ocorre exclusivamente no servidor.
- O resource detecta automaticamente colunas faltando e as adiciona via `ALTER TABLE` com `pcall` seguro.

---

## Licença

Uso livre para servidores FiveM. Redistribuição e revenda proibidas.
