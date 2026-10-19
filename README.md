# Expresso Gourmet — sistema operacional

Cardápio digital mobile-first e painel de operação da lanchonete Expresso Gourmet, na UNINTA em Tianguá/CE. O atendimento online ativo é **somente retirada no balcão**.

## Aplicação

- `index.html`: entrada principal do site estático servido pela Vercel.
- `presentation/index.html`: mesmo arquivo de aplicação, mantido para preservar o endereço anterior de apresentação.
- `supabase/functions/pickup-order/index.ts`: endpoint de checkout real, com validação do servidor, idempotência, limite de requisições e confirmação de preços/disponibilidade no banco.
- `supabase/functions/staff-admin/index.ts`: convite de funcionários, permitido apenas para a proprietária autenticada.
- A fila da equipe recebe eventos PostgreSQL Realtime apenas após o login; a consulta periódica funciona como recuperação se o socket ou o CDN falhar.
- `supabase/migrations/`: alterações aditivas e controles de segurança registrados no repositório.

Não existe mais um caminho de checkout que crie vendas fictícias. A aplicação não inclui produtos de amostra nem gráficos preenchidos com números inventados. Se o banco não responder, o cardápio mostra o erro e não simula um pedido.

## Fluxo do cliente

1. O navegador carrega os produtos e configurações publicadas em `expresso_public_catalog`.
2. A sacola mantém somente a seleção local até o cliente enviar o formulário.
3. O navegador envia produtos/quantidades para a Edge Function `pickup-order`; não envia preços confiáveis.
4. A função valida campos, origem, limite de requisições, disponibilidade e configurações da loja. O banco calcula o preço final a partir de `products`.
5. Quando o banco registra o pedido, o cliente recebe o número e o código de retirada. A consulta de acompanhamento retorna somente estado do pedido, sem expor dados pessoais.
6. A equipe confirma a retirada e o pagamento no painel. Escolher “Pix” ou “dinheiro” não marca automaticamente a venda como paga.

## Login e permissões

Há uma única tela de login por e-mail e senha via Supabase Auth. O papel vem de `profiles.role` e o acesso exige `profiles.active = true`; o navegador não pode escolher a própria função.

- **Proprietária:** análise de vendas, catálogo, preço, custos, parâmetros da loja, pagamentos e equipe.
- **Funcionários:** fila de pedidos, atualizações de preparo/retirada e disponibilidade dos produtos. O dashboard financeiro e a edição de custos ficam restritos à proprietária.
- **Equipe:** convites por e-mail usam a Edge Function `staff-admin`; cada pessoa deve usar sua conta individual.

## Dashboard de vendas

O painel usa `get_sales_dashboard(p_from, p_to)`, com períodos de 7, 30, 90 e 180 dias e fuso horário `America/Fortaleza`. A função agora recusa chamadas de funcionários e exige papel de proprietária ativa.

- Dia da semana, data e horário são agrupados a partir de pedidos finalizados.
- Ranking de produtos usa quantidade e valores que foram gravados nos itens do pedido.
- O faturamento recebido só soma pedidos finalizados com `payment_status = 'paid'`.
- A comparação com o período anterior usa o mesmo intervalo de dias.
- Sem histórico suficiente, o painel mostra falta de dados em vez de inventar vencedores.

## Banco de dados e migrações

As migrações novas preservam o estado JSONB legado como arquivo de recuperação, importam os registros para tabelas relacionais e evitam sobrescrever dados normalizados em reexecuções:

1. `20261016141000_normalize_live_catalog_and_checkout.sql` — produtos, custos, pedido legado, limite compartilhado do checkout e catálogo derivado dos produtos relacionais.
2. `20261016142000_backfill_legacy_cost_snapshots.sql` — completa o custo histórico do item legado sem alterar seu preço registrado.
3. `20261016143000_owner_product_admin_functions.sql` — operações transacionais de produto/custo, configurações e acessos.
4. `20261016144000_transactional_payment_confirmation.sql` — atualização transacional do pagamento.
5. `20261016145000_sales_dashboard_owner_only.sql` — restringe o dashboard financeiro à proprietária.
6. `20261016150000_restrict_direct_order_mutations.sql` — restringe inserções/alterações diretas de itens e pagamentos; a aplicação usa as funções transacionais aprovadas.
7. `20261016152000_enable_order_realtime.sql` — inclui `orders` na publicação Realtime para acelerar a fila da equipe.
8. `20261018170000_harden_order_transitions_and_admin_reads.sql` — centraliza o avanço/cancelamento de pedidos em uma RPC, restringe mutações diretas e libera as leituras administrativas com RLS.
9. `20261018171000_fix_authenticated_category_reads.sql` — corrige a leitura de categorias usada pelo formulário de produtos.
10. `20261018172000_explicit_rate_limit_denial_and_legacy_indexes.sql` — explicita a negação de acesso de navegador ao limitador de pedidos e adiciona índices para duas chaves estrangeiras legadas.

### Estado conferido após a migração

- 63 produtos na tabela relacional e no catálogo público.
- 63 custos de produto.
- 1 pedido histórico importado e 1 item.
- 1 registro de pagamento legado, ainda **pendente** porque não havia confirmação explícita de recebimento.
- O histórico JSONB continua preservado.

O pedido legado de R$ 27,00 não conta como faturamento pago até a equipe confirmar o pagamento. Os dados atuais ainda são insuficientes para concluir quais dias ou produtos realmente vendem mais; os rankings tornam-se confiáveis conforme pedidos reais forem finalizados e os pagamentos confirmados.

## Verificação

O workflow `.github/workflows/verify-live-app.yml` valida a sintaxe JavaScript, a igualdade entre as três entradas HTML, as integrações reais de checkout/equipe/dashboard, o uso de RPC para transições de pedido, a renovação das sessões autenticadas, as políticas do limitador e a ausência dos antigos geradores de demonstração.

Antes de anunciar a operação em produção, ainda é necessário fazer uma compra controlada autorizada pelo estabelecimento, com pagamento e retirada reais. Não crie pedidos fictícios no banco de produção só para verificar a interface.

## Segurança e publicação

- A chave publicável do Supabase pode aparecer no frontend; a proteção depende das políticas RLS e das funções validadas.
- A auditoria do Supabase sinalizou a proteção contra senhas vazadas desabilitada. Ative-a em Auth → Password Security para rejeitar senhas conhecidas em vazamentos: https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection.
- Nunca coloque `service_role` nem chaves secretas em `index.html`, `.env.example` ou GitHub. As Edge Functions usam o segredo de servidor no ambiente do Supabase.
- O código está na branch `main` de [Wolf9729/expresso-gourmet](https://github.com/Wolf9729/expresso-gourmet).
- O projeto Vercel existente foi usado para previews por upload direto; o vínculo de deploy automático via GitHub ainda precisa ser concluído sem trocar o domínio atual inadvertidamente.
- O plano atual do Supabase não permite criar branch de banco, então não foi possível executar um clone isolado antes da migração. As migrações aplicadas foram aditivas e verificadas com consultas de contagem e integridade.
