# PgQuery

Cliente desktop simples e leve para PostgreSQL no macOS. A interface usa AppKit nativo; toda a conexão, execução de SQL e leitura de resultados fica no núcleo Rust.

## Usar

1. Abra `PgQuery.app` na Mesa.
2. Cole sua URL PostgreSQL, por exemplo: `postgresql://usuario:senha@host:5432/banco?sslmode=require`.
3. Clique em **Conectar**. Use o filtro e o seletor para abrir uma tabela.
4. Escreva SQL no editor colorido e clique em **Executar SQL**. `⌘R` também executa.
5. Copie e cole usando `⌘C` e `⌘V` ou o menu **Editar**. O botão **Copiar resultado** copia a saída inteira.

A URL de conexão fica apenas na memória. O editor destaca comandos SQL, strings, números e comentários e indenta linhas novas. A conexão trabalha numa thread própria. Resultados são consumidos em fluxo e guardados até 500 linhas ou 2 MiB por consulta. Use `LIMIT` para limitar também o trabalho no servidor. O rodapé mede a CPU e a memória física do próprio app a cada meio segundo.

O ícone vetorial original está em `macos/AppIcon.svg`; `macos/make-icon.swift` o desenha nas resoluções nativas do macOS.

## Compilar

Requer Rust, Swift e as Command Line Tools do Xcode. Rode:

```sh
./build-macos.sh
```

O bundle sai em `target/PgQuery.app`.
# PgQuery

Cliente PostgreSQL nativo para macOS.

## Compilar no macOS

Requer Xcode completo, Rust e Swift Package Manager. Execute:

```sh
./build-macos.sh
```

O app compilado fica em `target/PgQuery.app`.

## Atualizações e releases

O Sparkle verifica automaticamente o feed público e o menu **PgQuery → Verificar atualizações** inicia uma verificação manual. Um ponto azul aparece nesse item quando há uma versão nova. Pushes em `main` disparam `.github/workflows/release.yml`, que compila o app, cria `.zip` e `.dmg`, publica uma release e atualiza `appcast.xml`.

Configure estes itens em **Settings → Secrets and variables → Actions** do repositório:

- Secret `SPARKLE_PRIVATE_ED_KEY`: chave privada EdDSA exportada do Chaves do macOS com o `generate_keys` do Sparkle.
- Variable `SPARKLE_PUBLIC_ED_KEY`: chave pública correspondente, já embutida em `macos/Info.plist`.
- Secrets `MACOS_CERTIFICATE_P12` e `MACOS_CERTIFICATE_PASSWORD`: identidade de assinatura estável em PKCS#12 e a senha usada na exportação. O certificado pode ser autoassinado; isso evita exigir uma conta Apple Developer, mas o primeiro download ainda pode pedir ao usuário para autorizar a abertura no macOS.

O segredo privado Sparkle e o certificado de assinatura devem ser guardados fora do repositório. A chave pública do feed fica no app e não é secreta.
