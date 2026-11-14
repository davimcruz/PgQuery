# PgQuery

Cliente desktop leve para PostgreSQL no macOS. A interface usa AppKit nativo; conexão, execução de SQL e leitura de resultados ficam no núcleo Rust.

[Baixar PgQuery para macOS (.dmg)](https://github.com/davimcruz/PgQuery/releases/latest/download/PgQuery.dmg)

## Usar

1. Abra `PgQuery.app`.
2. Cole uma URL PostgreSQL, por exemplo `postgresql://usuario:senha@host:5432/banco?sslmode=require`.
3. Clique em **Conectar** e use o filtro e o seletor para abrir uma tabela.
4. Escreva SQL e clique em **Executar SQL**. `⌘R` também executa.
5. **Copiar resultado** e **Limpar** aparecem após uma consulta bem-sucedida.

## Editor SQL

- **Autocomplete por contexto**: tabelas depois de `FROM`/`JOIN`/`UPDATE`/`INTO`, colunas de `alias.`/`tabela.`, tabelas de `schema.`, e identificadores ao abrir aspas duplas (`"`). Não abre sozinho enquanto você digita palavras-chave.
- `⎋` ou `⌃Espaço` abre as sugestões manualmente; `↑ ↓` navegam, `↩`/`⇥` inserem, `⎋` fecha. Em **SQL → Sugerir colunas enquanto digita** dá para ligar sugestões automáticas de colunas.
- Entende aliases, CTEs (`WITH`) e subconsultas; colunas ambíguas entre tabelas são inseridas qualificadas (`u.id`). Identificadores só ganham aspas quando o PostgreSQL exige.
- `⌘↩` executa a instrução sob o cursor (ou a seleção); `⌘R` executa a seleção ou tudo. A posição de erros do PostgreSQL é sublinhada no editor.
- Fecha parênteses e aspas automaticamente, indenta ao pular linha, `⇥`/`⇧⇥` indentam blocos, `⌘/` comenta linhas, `⌘D` duplica, `⌘F` busca, `⌘+`/`⌘-` mudam a fonte.

Testes do editor (sem banco): `scripts/test-editor.sh`.

O ícone vetorial original está em `macos/AppIcon.svg`; `macos/make-icon.swift` gera os tamanhos nativos do macOS.

## Compilar

Requer Rust e Swift Package Manager. Execute:

```sh
./build-macos.sh
```

O app compilado fica em `target/PgQuery.app`.

## Atualizações e releases

O Sparkle verifica automaticamente o feed público. **PgQuery → Verificar atualizações** inicia uma verificação manual; o menu mostra um ponto azul quando uma versão nova está disponível. Pushes em `main` disparam `.github/workflows/release.yml`, que compila o app, publica `.zip` e `.dmg` em uma GitHub Release e atualiza `appcast.xml`.

Depois de criar o repositório público e autenticar o GitHub CLI (`gh auth login -h github.com`), execute:

```sh
scripts/configure-release-secrets.sh
```

O script prepara os secrets de Actions para a chave privada EdDSA do Sparkle e para uma identidade de assinatura autoassinada estável. As chaves privadas ficam no Chaves do macOS e nos secrets do GitHub Actions; não são gravadas no repositório. A chave pública Sparkle já está embutida no app. Sem uma conta Apple Developer, o primeiro download pode exigir que cada pessoa autorize a abertura do app nas configurações do macOS.

## Armazenamento local da conexão

A URL de conexão fica em `~/Library/Application Support/PgQuery/connection.txt`, com permissões restritas à conta do usuário. O arquivo não é criptografado e pode conter a senha do banco; proteja sua conta do macOS e apague esse arquivo para remover a conexão salva.

## Licença

[MIT](LICENSE)
