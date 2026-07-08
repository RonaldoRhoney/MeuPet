# MeuPet — Automações via n8n + Telegram

Guia passo a passo pra ativar as 7 automações. As mudanças de banco (coluna
`badge` em `pets` e a função `daily_report_stats()`) já foram aplicadas em
produção — o que falta é 100% configuração em serviços externos (Telegram,
Railway, n8n, Supabase Dashboard), feita por você.

## 1. Criar o bot no Telegram

1. Abra o Telegram, busque **@BotFather**.
2. Envie `/newbot`, escolha nome "MeuPet Admin" e um username terminado em `bot`
   (ex: `meupet_admin_bot`).
3. Copie o **token** que ele devolve (formato `123456789:ABC-...`).
4. Busque o bot pelo username, envie `/start` pra ele.
5. Acesse no navegador: `https://api.telegram.org/bot<TOKEN>/getUpdates`
   (troque `<TOKEN>` pelo token real) e copie o `"id"` dentro de `"chat"` — esse
   é o seu `CHAT_ID`.

Guarde os dois em algum lugar seguro (gerenciador de senhas) — vamos colar em
vários lugares no n8n.

## 2. Subir o n8n no Railway

1. Crie conta em [railway.app](https://railway.app) (free tier).
2. Use o template oficial de n8n do Railway (busque "n8n" no marketplace de
   templates) — ele já vem com Postgres próprio pro n8n guardar os workflows.
3. Depois de implantado, o Railway te dá uma URL pública tipo
   `https://seu-projeto.up.railway.app` — é nela que o n8n vai rodar 24h.
4. Acesse essa URL, crie sua conta de admin do n8n (e-mail/senha, só sua).

## 3. Importar os 7 workflows

Os arquivos prontos estão em `automations/n8n/*.json`. Para cada um:

1. No n8n, clique em **"+"** → **"Import from File"** e selecione o JSON.
2. Ele vai pedir pra você **associar as credenciais** (Telegram, HTTP Headers)
   — isso é normal, workflows exportados nunca trazem segredos junto.

### Credencial do Telegram (uma vez só, reaproveitada nos 7)

No primeiro workflow, clique no node **"Telegram - avisa admin"** → no campo
de credencial, "Create New" → cole o **token do bot** (passo 1) → salve como
"Telegram MeuPet Bot". Nos outros 6 workflows, quando pedir credencial de
Telegram, selecione essa mesma já criada (não precisa recriar).

### Chat ID, chave da service_role e segredo do webhook (find & replace manual)

Cada workflow tem campos com texto literal `SEU_TELEGRAM_CHAT_ID_AQUI`,
`SUA_SERVICE_ROLE_KEY_AQUI` e `SEU_WEBHOOK_SECRET_AQUI` que você precisa
substituir dentro do n8n (clique no node, edite o campo, cole o valor real).
São textos de propósito — não coloque os valores reais de volta no arquivo
`.json` do repositório, o real só deve existir dentro do banco de dados do
seu n8n.

**O que é o `SEU_WEBHOOK_SECRET_AQUI`?** Os Database Webhooks do Supabase não
assinam a requisição — se alguém descobrir a URL do seu webhook n8n, pode
forjar um POST e disparar a automação sem ter feito nada de verdade no app
(ex: forjar um "marco de curtidas" pra se auto-promover a "lenda"). Todo
workflow (exceto o 6, que é por horário) tem um node **"Confirma secret"**
logo depois do Webhook, que só deixa passar se o header `x-meupet-secret`
bater com um valor que só você define. Gere uma string aleatória longa (ex:
`openssl rand -hex 24` no terminal), cole ela no node "Confirma secret" de
cada um dos 6 workflows, e configure o **mesmo valor** como header customizado
em cada Database Webhook do Supabase (passo 5 abaixo).

A `service_role key` fica em: Supabase → Settings → API → "Secret keys"
(mesma chave já usada em outras partes do projeto, formato `sb_secret_...`).

**Atenção:** essa chave dá acesso total ao banco, sem as regras de segurança
(RLS). Trate como senha de administrador — nunca a cole em nenhum arquivo
versionado no Git.

## 4. Ativar cada workflow e pegar a URL do webhook

1. Em cada um dos workflows 1, 2, 3, 4, 5 e 7 (todos exceto o 6, que é agendado
   por horário), clique no node **Webhook** e copie a **URL de produção**
   (só aparece depois que o workflow está **ativo** — o toggle "Active" no
   canto superior direito).
2. Anote essas 6 URLs no arquivo `automations/n8n_webhooks.md` (template já
   criado, só preencher).
3. O workflow 6 (relatório diário) não precisa de URL — só precisa estar
   **ativo** pra disparar sozinho todo dia às 8h.

## 5. Configurar os Database Webhooks no Supabase

Pra cada automação 1, 2, 3, 4, 5 e 7 (usando a URL copiada no passo anterior):

1. Supabase Dashboard → **Database → Webhooks → Create a new hook**.
2. Preencha:
   - **Nome**: nome da automação (ex: "bug-report-telegram")
   - **Tabela**: conforme a tabela abaixo
   - **Eventos**: conforme a tabela abaixo
   - **Tipo**: "HTTP Request"
   - **URL**: a URL do webhook do n8n correspondente
   - **HTTP Method**: POST
   - **HTTP Headers**: `Content-Type: application/json` **e** `x-meupet-secret: <o mesmo valor que você colocou no node "Confirma secret">`

| # | Automação              | Tabela              | Evento(s)     |
|---|-------------------------|---------------------|---------------|
| 1 | Bug report → Telegram   | `reports`           | INSERT        |
| 2 | Novo usuário            | `profiles`          | INSERT        |
| 3 | Marco de curtidas       | `likes`             | INSERT        |
| 4 | Nova adoção             | `adoption_listings` | INSERT        |
| 5 | Assinatura Premium      | `subscriptions`     | INSERT        |
| 7 | Petshop parceiro        | `petshops`          | UPDATE        |

## 6. Testar cada fluxo com dados reais ANTES de ativar de verdade

Recomendo, pra cada automação, nessa ordem:

1. Ative o workflow no n8n.
2. Configure o webhook no Supabase apontando pra ele.
3. Gere o evento real no app (ex: mande um feedback de bug pelo app de verdade,
   ou insira uma linha de teste via SQL) e confirme que a mensagem chega no
   Telegram formatada corretamente.
4. Se algo vier errado (campo em branco, erro 401 do Supabase, etc), veja o
   histórico de execuções no n8n ("Executions") — ele mostra o payload exato
   recebido e onde falhou.

## Segurança — considerações que ficaram de fora por enquanto

A auditoria de segurança do projeto (rodada antes de eu liberar essas
mudanças) confirmou que dar a `service_role key` completa pro n8n é uma
expansão real de risco: se o Railway/n8n for comprometido, o atacante tem
acesso total ao banco (bypass de RLS em tudo), não só ao que as automações
precisam. A mitigação mais forte seria criar uma role Postgres dedicada
(ex: `n8n_bot`) com grants mínimos (só o necessário pra essas 7 automações) e
gerar um JWT próprio pra ela, em vez de usar a service_role. Isso reduz o
"raio de explosão" caso o n8n seja comprometido, mas é um trabalho de
configuração adicional (role + policies + geração de JWT) que optamos por não
fazer agora — usamos o header secreto (`x-meupet-secret`, acima) como
mitigação mais simples pro risco mais imediato (webhook forjável). Se quiser
reforçar mais tarde, é só pedir.

## Notas importantes

- **Automação 5 (assinatura Premium) fica dormente até existir um gateway de
  pagamento real** (Stripe/Mercado Pago/PagSeguro) integrado ao MeuPet — hoje
  não existe, então nada vai disparar essa automação por enquanto. Isso é
  esperado, não é erro.
- **Automação 2**: o e-mail de boas-vindas ao usuário não foi implementado —
  o MeuPet ainda não tem serviço de e-mail (SMTP) configurado. O aviso pro
  admin via Telegram já funciona; o e-mail fica pra depois (nota dentro do
  próprio workflow no n8n).
- Todos os nodes HTTP/Telegram já têm "retry em caso de falha" configurado
  (tenta de novo depois de 5 minutos), conforme pedido.
