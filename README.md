# Vinheria Agnello

Base da atividade da Fase 7 da FIAP. `Orders` registra pedidos em `orders.db` após consultar `Inventory` por REST. `Inventory` mantém o saldo por SKU em `inventory.db`. O SKU `WINE-001` começa com 10 unidades e o registro de um pedido preserva esse saldo.

## Subir os serviços

Com o Docker Desktop em modo de containers Linux e PowerShell 7.4 ou posterior, execute na raiz do projeto:

```powershell
.\scripts\Initialize-DemoSecurity.ps1
docker compose up --build -d
docker compose ps
```

O build usa o SDK do .NET 10 dentro do Docker. Os dois protocolos ficam ativos ao mesmo tempo. As portas são publicadas apenas no loopback da máquina.

| Serviço | HTTP | HTTPS |
|---|---|---|
| `Orders` | `http://localhost:8080` | `https://localhost:8443` |
| `Inventory` | `http://localhost:8081` | `https://localhost:8444` |

## Autenticação e certificados

O inicializador gera uma CA local, um certificado HTTPS por serviço e dois JWTs RS256 de demonstração. O cliente usa o token com audiência `orders` e escopo `orders:access`. O `Orders` usa a identidade `orders-service`, com audiência `inventory` e escopo `inventory:read`, para consultar o `Inventory`. Em ambos os protocolos, os endpoints recebem `Authorization: Bearer <token>`, retornam `401` para credencial ausente ou inválida e retornam `403` quando o token válido tem escopo insuficiente.

A pasta `.demo-security` é ignorada pelo Git e pelo Docker no build. O Compose monta os arquivos necessários em cada container durante a execução. O roteiro e o cliente HTTP do `Orders` confiam na CA local e validam o nome do servidor. A geração e os testes usam a CA sem alterar o repositório de certificados do sistema. [Segredos no Docker Compose](https://docs.docker.com/compose/how-tos/use-secrets/)

Os tokens expiram após uma hora. Para renovar, pare os serviços, gere um novo conjunto de credenciais e recrie os containers com os mesmos volumes SQLite.

```powershell
docker compose stop
.\scripts\Initialize-DemoSecurity.ps1
docker compose up --force-recreate -d
```

## Endpoints

| Serviço | Método e caminho | Resultado |
|---|---|---|
| `Inventory` | `GET /stock/{sku}` | `200` com `sku` e `availableQuantity`, ou `404` para SKU desconhecido |
| `Orders` | `POST /orders` | Recebe `sku` e `quantity`. Retorna `201` com o pedido e o cabeçalho `Location` |
| `Orders` | `GET /orders/{id}` | `200` com `id`, `sku` e `quantity`, ou `404` para pedido inexistente |

## Demonstrar rede e DNS

O Docker atribui IPs dinamicamente na rede `bridge` `vinheria-agnello_demo` para simular a atribuição de endereços do DHCP. O DNS embutido registra os serviços pelo nome. Quando recebe um pedido por HTTP, o `Orders` consulta `http://inventory:8080`. Quando recebe por HTTPS, consulta `https://inventory:8443` e valida o certificado do `Inventory`. [Rede e DNS no Docker Compose](https://docs.docker.com/compose/how-tos/networking/)

```powershell
docker network inspect vinheria-agnello_demo
docker compose exec -T orders getent hosts inventory
docker compose exec -T inventory getent hosts orders
```

Compare os IPs retornados pelo DNS com `IPv4Address` na inspeção. Capture essas saídas e as do fluxo a seguir como evidências para o relatório.

## Demonstrar o fluxo REST

```powershell
.\scripts\Test-Demo.ps1
```

O roteiro verifica a rejeição de certificados com CA desconhecida ou nome incompatível e os casos de `401` e `403`. Para cada protocolo, cria um pedido de duas unidades, segue o link retornado e confirma que o saldo continua em 10. Também verifica `400` para dados inválidos, `404` para SKU ou pedido desconhecido e `409` para saldo insuficiente.

Nos logs, a mesma consulta interna aparece em `http://inventory:8080/stock/WINE-001` e `https://inventory:8443/stock/WINE-001`. Em uma captura HTTP, o corpo e o token de teste ficam legíveis. Em HTTPS, o TLS cifra esses dados. Use apenas os dados e os tokens do laboratório na comparação. Se a conexão falhar ou o `Inventory` rejeitar a credencial, o `Orders` responde com `503` antes de gravar o pedido.

```powershell
docker compose logs orders --tail 80
```

Para comprovar a persistência, recrie os containers e informe o ID exibido como `Created order` na execução anterior. O roteiro consulta esse pedido e cria um novo.

```powershell
docker compose up --force-recreate -d
.\scripts\Test-Demo.ps1 -ExistingOrderId (Read-Host 'ID do pedido anterior')
```

Os volumes `orders-data` e `inventory-data` guardam os dois arquivos SQLite e sobrevivem ao comando `docker compose down`. O EF Core cria o esquema e os dados iniciais quando o banco é novo.
