# WorbyRepRest

API REST em Horse para expor, em JSON, as tabelas envolvidas no projeto `C:\Tomasi Sistemas\Exportorbi\trunk`.

## Tabelas mapeadas

- representante
- cliente
- cidades
- vendas1
- vendas2
- cr1
- produto
- grupo
- produto_representante
- grupo_representante
- produto_representante_inativos
- grade_comissao
- fop
- prazo
- prazo_representante
- processo_pedido
- hist_processo_pedido
- v_comissao_nova

## Contrato JSON

O request e o response da API sao em JSON.
Nao existe fluxo TXT nesta API.

## Rotas

- `GET /health`
- `GET /tables`
- `POST /tables`
- `POST /login`
- `POST /api/list`
- `POST /api/item`
- `POST /api/pedido`
- `POST /api/pedidos_digitados`

### `POST /login`

```json
{
  "login": "admin",
  "senha": "123"
}
```

## Exemplos de request

### `POST /api/list`

```json
{
  "table": "cliente",
  "limit": 100,
  "codRepresentante": "1"
}
```

### `POST /api/item`

```json
{
  "table": "produto",
  "id": "123"
}
```

### `POST /api/pedido`

```json
{
  "vendas1": {
    "cod_cliente": 1,
    "cod_representante": 2,
    "tot_liquido": 100.5
  },
  "vendas2": [
    {
      "cod_produto": 10,
      "qtd": 2,
      "preco": 50.25
    }
  ]
}
```

### `POST /api/pedidos_digitados`

```json
{
  "pedidos": [
    {
      "pedido_id": 123,
      "vendas1": {
        "cod_cliente": 1,
        "cod_representante": 2,
        "tot_liquido": 100.5
      },
      "vendas2": [
        {
          "cod_produto": 10,
          "qtd": 2,
          "preco": 50.25
        }
      ]
    }
  ]
}
```

## Configuracao

A conexao e a porta HTTP sao lidas do arquivo `servidor.ini` na pasta do executavel.

## Observacoes

- O projeto usa whitelist das tabelas mapeadas do `Exportorbi`.
- `POST /api/list` aceita `codRepresentante` e aplica o filtro apenas nas tabelas que possuem campo de representante mapeado.
- `POST /login` autentica na tabela `tbusu` usando os campos `login` e `senha`.
- `POST /api/pedido` insere o cabecalho em `vendas1` e os itens em `vendas2` na mesma transacao.
- Em `POST /api/pedido`, o `numdoc` de `vendas1` e gerado pelo banco e replicado automaticamente nos registros de `vendas2`.
- `POST /api/item` usa a chave primaria configurada em `src\WorbyRepRest.Metadata.pas`.
- Para algumas estruturas sem PK simples, a chave configurada hoje e uma aproximacao inicial e pode ser refinada depois.
