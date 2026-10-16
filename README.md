# Expresso Gourmet — reconstrução mobile-first

Aplicação Next.js + React + TypeScript para o cardápio público e operação da lanchonete Expresso Gourmet, na UNINTA em Tianguá/CE. A entrega atual concentra-se no cardápio, pedidos para retirada no balcão, fila administrativa, catálogo, configurações básicas da loja e gestão de acessos.

## Atendimento definido

O único método de atendimento ativo nesta versão é **retirada no balcão**. Entrega fica desabilitada no frontend, na API e nas regras de pedido do banco.

## Funcionalidades nesta base

- Cardápio público com busca, filtros por categoria, sacola e checkout mobile.
- Checkout envia apenas produto/quantidade e dados básicos. O banco recalcula preço, disponibilidade, total e desconto validado.
- Idempotência no pedido para impedir duplicação acidental em retries de rede.
- Número e código de retirada; consulta de status exige uma chave privada que não é persistida em texto puro.
- Painel responsivo com login Supabase Auth, área de visão geral, fila de pedidos, catálogo, configurações da loja e equipe.
- Permissões distintas: proprietária pode administrar catálogo/configurações/equipe; funcionário pode conduzir a operação e alternar disponibilidade conforme autorizado.
- Eventos Supabase Realtime para pedidos, alerta visual de novo pedido e som opcional ativado pelo usuário; polling de recuperação quando Realtime não estiver disponível.
- Página de acompanhamento do pedido, com atualização periódica.
- Catálogo público com cache CDN de até 30 segundos e stale-while-revalidate; nenhum custo nem dado financeiro é retornado.
- Migração proposta para importar 63 produtos/custos e o pedido legado para tabelas relacionais, mantendo o JSONB anterior como backup de reconciliação.
- Índices de filas, contadores de painel via RPC e controle distribuído de limite de checkout via PostgreSQL, após migration 002.

## O que ainda está fora da entrega

- Upload de fotos diretamente pelo painel (os arquivos já extraídos ficam em `public/menu-images/`; por enquanto, o formulário usa caminhos locais ou URLs HTTPS).
- Gestão completa de cursos/alunos/campanhas e validação de descontos no checkout novo.
- Relatórios financeiros completos, metas e gráficos históricos.
- Integração automática WhatsApp Business/webhook (o link de WhatsApp não prova envio nem retorno automático ao banco).
- Integração com gateway de pagamento; forma escolhida no checkout é uma preferência e fica pendente até confirmação da equipe.
- Teste de carga e publicação de produção.

## Requisitos e instalação

- Node.js 20.9 ou superior; recomenda-se LTS.
- Acesso ao projeto Supabase correto e backup aprovado antes da migração.

No Windows:

1. Extraia o ZIP e abra um terminal na pasta do projeto.
2. Execute `npm install`.
3. Copie `.env.example` para `.env.local`.
4. Configure as variáveis do ambiente.
5. Execute `npm run dev` e abra `http://localhost:3000`.

### Variáveis de ambiente

- `NEXT_PUBLIC_SUPABASE_URL`: URL do projeto Supabase.
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`: chave publicável/anon do mesmo projeto; o browser usa-a apenas com RLS e para autenticação.
- `SUPABASE_SERVICE_ROLE_KEY`: segredo exclusivamente server-side. Nunca usar `NEXT_PUBLIC_`, nunca comitar e nunca expor no browser.
- `PICKUP_TOKEN_SECRET`: segredo estável aleatório, mínimo 32 caracteres, usado para derivar o token privado do pedido.
- `NEXT_PUBLIC_DEMO_MODE`: deixe `false` em produção. `true` habilita um catálogo demonstrativo e bloqueia o checkout real se a API falhar.

Não reutilize credenciais de outro ambiente. As chaves reais não estão incluídas neste pacote.

## Migrations

As migrations precisam ser revisadas, testadas em branch/ambiente isolado e aplicadas na ordem:

1. `supabase/migrations/202610160001_normalize_menu_and_pickup_orders.sql`
   - adiciona IDs legados e campos do fluxo de retirada;
   - importa os campos públicos dos produtos e custos em tabela privada;
   - reconcilia pedido(s) legado(s), mantendo pagamento pendente até confirmação;
   - cria RPCs transacionais para criar, consultar e atualizar pedidos;
   - preserva o JSONB original para rollback/reconciliação.
2. `supabase/migrations/202610160002_admin_realtime_rate_limits.sql`
   - cria índices voltados à fila e às consultas do painel;
   - adiciona a tabela `orders` à publicação Realtime quando disponível;
   - cria limitador de checkout compartilhado entre instâncias Vercel;
   - cria RPC de contadores do painel;
   - cria a RPC `admin_save_product`, que grava catálogo e custo unitário na mesma transação.

**Não aplique direto no banco de produção sem backup/revisão.** A versão HTML antiga ainda pode gravar no estado JSONB sem dual-write para tabelas relacionais. A migração de produção só deve ocorrer durante uma janela coordenada de corte para o novo site, após validar o ambiente de teste. O estado JSONB original não deve ser apagado pela migração.

Confira `docs/05-VERIFICACAO-POS-MIGRACAO.sql` para consultas de verificação pós-migração e compare quantidades, preços, custos e pedidos com o backup.

## API v1

Contrato detalhado em `docs/openapi.yaml`.

Público:

- `GET /api/v1/catalog`
- `POST /api/v1/orders`
- `GET /api/v1/orders/status?pickupCode=...` com `x-order-access-token`

Com sessão autorizada:

- `GET /api/v1/orders` — fila paginada, filtro e contadores.
- `PATCH /api/v1/orders/:id/status` — transições validadas e histórico.
- `GET /api/v1/products` — catálogo administrativo e categorias.
- `POST /api/v1/products` — criar produto (proprietária).
- `PATCH /api/v1/products/:id` — proprietária edita; funcionário só alterna disponibilidade.
- `DELETE /api/v1/products/:id` — arquivamento lógico (proprietária).
- `GET /api/v1/settings`, `PATCH /api/v1/settings` — leitura por equipe, edição pela proprietária.
- `GET /api/v1/team`, `POST /api/v1/team`, `PATCH /api/v1/team/:id` — gestão de equipe pela proprietária.

O CRUD administrativo usa servidor/API e verifica perfil ativo e função antes das operações. O checkout depende das migrations: sem conexão e funções SQL, ele deve apresentar erro e não fingir que registrou o pedido.

## Atualizações e escalabilidade

- Pedidos usam eventos Supabase Realtime para atualização rápida; polling é somente recuperação (45 s conectado, 8 s em estado degradado), além de atualização quando a aba volta ao foco.
- O painel busca lotes limitados (80 pedidos e um item sentinela para saber se há próxima página), evitando `count: exact` a cada evento.
- RPC de estatísticas agrega os quatro indicadores principais em uma chamada.
- O Realtime transmite somente eventos do cabeçalho do pedido; o painel consulta itens e dados completos pela API após o evento, reduzindo tráfego e duplicação de atualizações.
- A edição de preço e custo unitário é feita em uma função transacional para impedir que o catálogo seja atualizado sem o custo privado correspondente.
- Rate limit compartilhado no PostgreSQL limita checkout por janela entre instâncias serverless; há também um limite de melhor esforço por instância como proteção adicional.
- Catálogo usa cache CDN curto; atualizações de preço/disponibilidade podem levar até cerca de 30 s a refletir em caches públicos, enquanto a criação do pedido revalida a disponibilidade/preço diretamente no banco.
- Índices favorecem filas por status/data, itens por pedido e produtos por categoria/ordem.

Isso prepara o sistema para escala, mas **não substitui teste de carga**. A capacidade real depende do plano e configuração do Supabase/Vercel, tamanho do catálogo, conexões Realtime e padrão de uso.

## Testes e validação

Depois de instalar dependências:

```bash
npm run check:static
npm run lint
npm run build
```

A verificação estática local testa a sintaxe dos TS/TSX, JSON/YAML, arquivos referenciados e marcadores básicos de segurança/arquitetura. Ela não substitui o build, testes de integração ou teste de carga.

Teste em celulares reais: acesso público sem login, sacola, checkout, retry idempotente, preço revalidado, código de retirada, acompanhamento, login de proprietário e funcionário, permissões, Realtime, fallback de polling, disponibilidade, configurações e persistência após refresh/outro dispositivo.

## Estado desta entrega

O código foi estruturado localmente e passou por verificação de sintaxe TypeScript/TSX antes do empacotamento. **A migration não foi aplicada ao Supabase, não houve deploy e o build completo depende da instalação das dependências**, que não foi concluída neste ambiente. A conta Vercel conectada retornou erro de autorização para inspecionar logs e validar o site real; será necessário corrigir esse acesso para concluir a publicação e auditoria operacional.

## GitHub + Vercel + Supabase

Veja `docs/07-GITHUB-VERCEL-SUPABASE.md` para conectar o repositório privado ao projeto Vercel existente e cadastrar variáveis de ambiente com segurança. A CI em `.github/workflows/ci.yml` verifica estática, lint e build, mas não aplica migrations automaticamente.

**Importante:** o banco Supabase remoto contém migrations históricas cujos arquivos ainda não foram recuperados para este repositório. Reconciliar as 17 migrations históricas antes de usar a CLI para aplicar mudanças; não habilitar deploy de schema automático em produção enquanto isso não estiver resolvido.

### Publicar o primeiro commit no GitHub (Windows)

Depois de criar um repositório privado vazio no GitHub, abra PowerShell na raiz e execute:

```powershell
./scripts/publish-to-github.ps1 -RepositoryUrl "https://github.com/SEU_USUARIO/expresso-gourmet.git"
```

O script usa as credenciais do Git Credential Manager, não inclui tokens no comando e não força o push se o remoto tiver histórico diferente. Leia `docs/07-GITHUB-VERCEL-SUPABASE.md` antes de conectar o repositório à Vercel e alterar o banco.
