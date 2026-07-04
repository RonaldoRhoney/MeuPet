# MeuPet — Setup do Supabase (hoje à noite)

## Ordem exata

1. **Criar o projeto** em supabase.com → New Project (escolha a região mais próxima, ex: São Paulo / sa-east-1).
2. **SQL Editor → New query** → cole o conteúdo de `meupet_schema.sql` inteiro → Run.
   - Se der erro de extensão (`cube`/`earthdistance`/`moddatetime` não disponível no seu plano), me avise — tem alternativa sem essas extensões.
3. **Authentication → Providers**:
   - Ative **Google** (precisa criar credenciais no Google Cloud Console — Client ID + Secret).
   - Ative **Facebook** (cobre o botão "Instagram" do app — veja a nota abaixo).
   - Em **Authentication → URL Configuration**, adicione a URL onde o `meupet.html` vai rodar (ex: `https://meupet.rhoneyinc.com` ou o domínio do Lovable) em **Site URL** e **Redirect URLs**.
4. **Storage**: o `meupet_schema.sql` já cria o bucket `pet-media` com as policies. Confirme em Storage que ele apareceu como público.
5. **Settings → API**: copie a **Project URL** e a **anon public key**.
6. No `meupet.html`, procure por:
   ```js
   const SUPABASE_URL = "";
   const SUPABASE_ANON_KEY = "";
   ```
   e cole os dois valores.
7. Vire um admin de teste: rode no SQL Editor
   ```sql
   insert into public.admins (user_id) values ('SEU_USER_ID_AQUI');
   ```
   (pegue o `user_id` em Authentication → Users depois do seu primeiro login).

## Nota sobre o botão "Instagram"

O Supabase não tem um provedor OAuth chamado "instagram". O código já está ajustado para, ao clicar em "Continuar com Instagram", autenticar via **Facebook** (mesmo ecossistema Meta) — é só ativar o provider Facebook no painel. Se mais pra frente você quiser login específico via Instagram Business API, isso exige um app aprovado no Meta for Developers — me avisa que monto esse fluxo à parte.

## Dados de demonstração

Enquanto `SUPABASE_URL`/`SUPABASE_ANON_KEY` estiverem vazios, o app inteiro funciona com dados mock (feed, ranking, adoção, vitrine, petshops) — nada quebra. Assim que você preencher as credenciais, cada seção passa a puxar do banco automaticamente, sem precisar mudar mais nada no front.

## Teste rápido depois de configurar

- Abra o `meupet.html` no navegador, clique em "Entrar" → Google → deve te trazer de volta logado.
- Dê like num pet do feed → confira na tabela `likes` se a linha foi criada e se `pets.rank_score` mudou.
- Mude a cidade no seletor de petshops → a lista deve reconsultar via `petshops_near()` (vai vir vazia até você popular a tabela `petshops` com alguns registros de teste).

## Monetização (patrocinadores e links de afiliado)

- **Banners dinâmicos**: insira uma linha na tabela `sponsors` (`slot`, `headline`, `cta_text`, `target_url`, `active`) para os slots `banner_feed` e `banner_petshops` — o app já busca e exibe automaticamente, sem precisar mexer no código. Sem nenhum patrocinador ativo, o banner mostra um CTA interno (ex: "Ver oferta" → rola até a Loja).
- **Produtos com link de afiliado**: preencha `affiliate_url` ao cadastrar em `products` — o "via [loja]" na Vitrine já vira um link real com `rel="sponsored"` (recomendado pelo Google Ads/SEO para links pagos). Marque `is_sponsored = true` pra aparecer primeiro na lista com o selo "Parceiro".
- **Petshop parceiro**: marque `is_partner = true` em `petshops` para o pin dourado 🏅 no mapa e prioridade na lista "perto de você" — é o benefício do plano "Petshop Parceiro" (R$ 49/mês) já vendido na seção Planos.
- **Telemetria real**: toda impressão de banner e clique em link de afiliado grava em `ad_impressions` (`slot` no formato `house:<slot>`, `sponsor:<id>` ou `affiliate:<product_id>`, com sufixo `:click` pros cliques). Consulte essa tabela pra medir o que está rendendo.
- **Botão "Anuncie no MeuPet"** (rodapé): defina, no `meupet.html`, o e-mail comercial:
  ```js
  const SPONSOR_CONTACT_EMAIL = "";
  ```
  Sem isso preenchido, o link avisa que ainda não foi configurado em vez de abrir um e-mail vazio.
