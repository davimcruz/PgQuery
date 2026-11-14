<div align="center">

# PgQuery

**Cliente PostgreSQL leve e nativo para macOS, com um editor SQL de verdade.**

[![Última versão](https://img.shields.io/github/v/release/davimcruz/PgQuery?label=vers%C3%A3o&color=2f6fed)](https://github.com/davimcruz/PgQuery/releases/latest)
[![Licença MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-green)](LICENSE)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-lightgrey)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-lightgrey)

[**⬇️ Baixar PgQuery.dmg**](https://github.com/davimcruz/PgQuery/releases/latest/download/PgQuery.dmg)

<img src="docs/editor.png" alt="Editor SQL do PgQuery com realce de sintaxe" width="760">

</div>

PgQuery é um cliente desktop para PostgreSQL feito para abrir rápido, ficar leve e não atrapalhar. A interface é **AppKit nativo** (nada de Electron ou webview) e a conexão, a execução de SQL e a leitura dos resultados ficam num **núcleo em Rust**. Em repouso ele usa algumas dezenas de MiB de memória e praticamente nenhuma CPU.

## Destaques

- **Autocomplete que entende o contexto.** Não abre enquanto você digita `SELECT`; aparece quando faz sentido: depois de `.`, ao abrir aspas duplas ou ao escolher a tabela depois de `FROM`/`JOIN`.
- **Executa a instrução sob o cursor** (`⌘↩`), sem precisar selecionar nem apagar o resto do script.
- **Resultados legíveis:** datas no formato do seu sistema, `true`/`false` em vez de `t`/`f`, filtros combinados e ordenação por coluna.
- **Navegação por chave estrangeira:** um clique na seta ao lado de uma FK abre a linha referenciada na outra tabela, com botão de voltar.
- **Estimativa de linhas** de cada tabela na barra lateral, instantânea mesmo em tabelas enormes.
- **Atualizações automáticas** com [Sparkle](https://sparkle-project.org).
- **Código aberto** sob licença MIT.

## Instalação

1. [Baixe o `PgQuery.dmg`](https://github.com/davimcruz/PgQuery/releases/latest/download/PgQuery.dmg) (ou escolha uma versão em [Releases](https://github.com/davimcruz/PgQuery/releases)).
2. Abra o disco e arraste **PgQuery** para **Aplicativos**.
3. No primeiro uso, clique com o botão direito (ou `Control`+clique) no app e escolha **Abrir**.

> O app é assinado com um certificado próprio, sem Apple Developer ID, e **não é notarizado**. Por isso o macOS pede essa confirmação na primeira abertura. As atualizações seguintes pelo Sparkle não repetem o aviso.

**Requisitos:** macOS 12 ou mais novo, em Macs com Apple Silicon (M1 ou posterior).

## Primeiros passos

1. Abra o PgQuery e cole a URL de conexão, por exemplo
   `postgresql://usuario:senha@host:5432/banco?sslmode=require`.
   Se preferir, use **Por parâmetros…** e preencha host, porta, banco, usuário, senha e SSL.
2. Clique em **Conectar**. A lista de tabelas aparece na barra lateral, cada uma com a estimativa de linhas.
3. Clique numa tabela para ver as primeiras linhas, ou escreva SQL no editor e pressione `⌘↩`.
4. Clique numa linha do resultado para abrir o painel de detalhes.

A conexão fica salva e o app reconecta sozinho na próxima abertura (veja [Segurança](#segurança-e-privacidade)). Para trocar de banco, use **Configurações** (`⌘,`).

## Editor SQL

<table>
<tr>
<td width="50%"><img src="docs/autocomplete-tables.png" alt="Sugestão de tabelas depois do FROM"></td>
<td width="50%"><img src="docs/autocomplete-columns.png" alt="Sugestão de colunas com o tipo e a tabela de origem"></td>
</tr>
</table>

### Quando as sugestões aparecem

| Situação | Comportamento |
|---|---|
| Digitando palavras-chave (`SELECT`, `WHERE`…) | **Não abre.** |
| Depois de `.` (`u.`, `schema.`) | Abre com as colunas do alias/tabela, ou as tabelas do schema. |
| Ao abrir aspas duplas `"` | Abre com tabelas e colunas, inserindo o nome sem duplicar a aspa de fechamento. |
| Escolhendo tabela depois de `FROM`, `JOIN`, `UPDATE`, `INTO` | Abre com as tabelas, views e schemas. |
| Em qualquer outro lugar | Só manualmente, com `⎋` ou `⌃Espaço`. |
| Dentro de strings e comentários | Nunca. |

Dá para ligar sugestões de colunas enquanto digita em **SQL → Sugerir colunas enquanto digita**. Se você fecha a lista com `⎋`, ela fica quieta naquela palavra.

### O que ele sabe

- **Aliases, CTEs (`WITH`) e subconsultas:** `SELECT x.| FROM (SELECT email, count(*) AS n FROM users GROUP BY 1) x` sugere `email` e `n`.
- **Colunas ambíguas** entre tabelas da consulta são inseridas qualificadas (`u.id`).
- **Aspas só quando necessário:** `users` vira `users`, mas `Clientes` vira `"Clientes"`; palavras reservadas também ganham aspas.
- **Busca flexível:** `ci` encontra `customer_id` (iniciais) e `at` encontra `created_at` (parte do nome).
- Mostra o **tipo** e a **tabela de origem** de cada coluna, e funções com a assinatura.
- Tabelas fora de `public` são inseridas com o schema (`billing.invoices`).
- O catálogo é recarregado depois de `CREATE`, `ALTER` e `DROP`.

### Edição

- Fecha parênteses, colchetes e aspas automaticamente, e `⌫` apaga o par vazio.
- Indentação automática ao pular linha; dentro de `()` o corpo é indentado.
- Números de linha, destaque da linha atual e do parêntese correspondente.
- Realce de sintaxe (palavras-chave, funções, tipos, strings, números, parâmetros e comentários), inclusive para `E'…'`, `$$…$$` e comentários aninhados.
- Busca e substituição (`⌘F`), desfazer/refazer, tamanho da fonte ajustável.
- Em caso de erro, o PostgreSQL aponta a posição e o trecho é **sublinhado em vermelho** no editor.

### Executar

| Ação | Atalho | O que roda |
|---|---|---|
| **Executar instrução** | `⌘↩` | A instrução sob o cursor (separadas por `;`), ou só a seleção. |
| **Executar SQL** | `⌘R` | Todo o editor, ou só a seleção. |

Um `;` dentro de string ou comentário não separa instruções.

## Resultados

- **Valores formatados:** datas e timestamps no formato do sistema (`timestamptz` no seu fuso), booleanos como `true`/`false` e `NULL` em cinza. O valor original continua disponível no painel de detalhes, nos filtros e ao copiar.
- **Filtros combinados:** o botão **Filtro** adiciona condições (`contém`, `é igual a`, `começa com`, `maior que`, `é NULL`…). Todas precisam bater, cada uma tem seu `×`, e os filtros permanecem ao reexecutar a consulta.
- **Ordenação:** clique no cabeçalho da coluna.
- **Detalhes da linha:** clique numa linha para abrir o painel lateral com cada coluna, seu tipo e o valor completo.
- **Foreign keys:** colunas com chave estrangeira mostram uma seta; ela abre a linha referenciada e o botão **Voltar** retorna ao resultado anterior.
- **Copiar:** **Copiar resultado** (`⇧⌘C`) copia como TSV; o menu de contexto copia as linhas selecionadas como **JSON**.
- O resultado mostra até **500 linhas** (e 2 MiB); o rodapé avisa quando há mais.

## Atalhos

| Atalho | Ação |
|---|---|
| `⌘↩` | Executar instrução sob o cursor |
| `⌘R` | Executar tudo (ou a seleção) |
| `⎋` / `⌃Espaço` | Mostrar sugestões (`⎋` fecha se já estiverem abertas) |
| `↑` `↓` `⇞` `⇟` | Navegar nas sugestões |
| `↩` / `⇥` | Inserir a sugestão |
| `⌘/` | Comentar/descomentar linhas |
| `⌘D` | Duplicar linha (ou seleção) |
| `⇥` / `⇧⇥` | Indentar / desindentar linhas selecionadas |
| `⌘]` / `⌘[` | Indentar / desindentar |
| `⌘F` | Buscar · `⌘G` próxima · `⇧⌘G` anterior · `⌥⌘F` substituir |
| `⌘+` `⌘-` `⌘0` | Aumentar, diminuir e restaurar a fonte |
| `⇧⌘C` | Copiar resultado |
| `⌘K` | Limpar resultado e filtros |
| `⌘,` | Configurações de conexão |

Os botões mostram o atalho ao lado do nome.

## Segurança e privacidade

- **Nada sai da sua máquina:** o app só conversa com o banco que você configurar e com o feed público de atualizações no GitHub. Não há telemetria.
- **A conexão fica salva em um arquivo local:** `~/Library/Application Support/PgQuery/connection.txt`, com permissão restrita ao seu usuário. O arquivo **não é criptografado** e pode conter a senha do banco; proteja sua conta do macOS e apague o arquivo para esquecer a conexão.
- **TLS:** `sslmode=require` criptografa a conexão **sem validar o certificado** do servidor, como o `psql` (o rodapé avisa). `verify-ca` e `verify-full` validam o certificado e o nome do servidor; `prefer` tenta usar TLS quando o servidor oferece; `disable` desliga o TLS.
- **Supabase:** se a sua rede não tem IPv6, use a URL do *Session Pooler* (porta 5432) em vez do endereço direto `db.<ref>.supabase.co`; o app sugere isso quando a conexão falha por rede.
- A URL é ocultada por padrão nas configurações; use **Mostrar URL** para ver.

## Limitações conhecidas

- Somente PostgreSQL, com **uma conexão** e **um editor** por vez.
- Não edita dados nas tabelas, não tem túnel SSH nem exportação para CSV (por enquanto só copiar como TSV/JSON).
- Scripts com várias instruções mostram as linhas de todas juntas, sob as colunas da primeira; use `⌘↩` para rodar uma por vez.
- A interface está apenas em **português**.
- Apenas **Apple Silicon**.

## Compilar a partir do código

Precisa de macOS, [Rust](https://rustup.rs) e as ferramentas de linha de comando do Xcode (Swift).

```sh
git clone https://github.com/davimcruz/PgQuery.git
cd PgQuery
./build-macos.sh
open target/PgQuery.app
```

Testes do editor (lexer, autocomplete, filtros e formatação), sem precisar de banco:

```sh
scripts/test-editor.sh
```

### Como é organizado

```
src/lib.rs               núcleo em Rust: conexão, consultas, catálogo (API C + eventos JSON)
macos/PgQuery.swift      janela principal, barra lateral, resultados, detalhes, menus
macos/SQLLexer.swift     tokenizador PostgreSQL (strings, $$, comentários, parâmetros)
macos/SQLCompletion.swift  motor de autocomplete (contexto, aliases, CTEs, ranking)
macos/SQLTextView.swift  editor: pares, indentação, comentários, execução, erros
macos/SQLHighlighter.swift · LineNumberRuler.swift · CompletionPopup.swift
macos/ResultFilter*.swift · ValueFormatter.swift · KeyCap.swift · HoverScrollView.swift
macos/Tests/main.swift   testes (executados por scripts/test-editor.sh)
```

O Swift chama o Rust por uma API C pequena (`pg_connect`, `pg_query`, `pg_select_table`, `pg_poll`, `pg_set_notify`); o Rust roda num thread próprio e avisa a interface quando há resultado, então a UI nunca trava esperando o banco.

O ícone vetorial está em `macos/AppIcon.svg`; `macos/make-icon.swift` gera os tamanhos nativos.

## Atualizações e releases

O Sparkle verifica o feed público automaticamente. **PgQuery → Verificar atualizações** faz uma verificação manual, e o menu mostra um ponto azul quando há versão nova.

Cada push em `main` dispara `.github/workflows/release.yml`, que roda os testes, compila o app, publica `.zip` e `.dmg` numa GitHub Release e atualiza o `appcast.xml`. A versão é `1.0.N`, com `N` aumentando a cada release.

Para configurar os *secrets* de assinatura num fork (chave EdDSA do Sparkle e certificado de assinatura), autentique o GitHub CLI (`gh auth login -h github.com`) e execute:

```sh
scripts/configure-release-secrets.sh
```

As chaves privadas ficam no Chaves do macOS e nos *secrets* do GitHub Actions; nunca são gravadas no repositório. Somente a chave **pública** do Sparkle está embutida no app.

## Contribuindo

Issues e pull requests são bem-vindos. Antes de abrir um PR, rode `scripts/test-editor.sh` e `./build-macos.sh`. Mudanças no autocomplete ou nos filtros devem vir com testes em `macos/Tests/main.swift`.

## Licença

[MIT](LICENSE) © 2026 Davi Machado
