-- =====================================================================
-- MEUPET — SCHEMA COMPLETO (Supabase / Postgres)
-- Rodar no SQL Editor do Supabase, na ordem em que aparece.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. EXTENSÕES
-- ---------------------------------------------------------------------
create extension if not exists "uuid-ossp";
create extension if not exists "cube";
create extension if not exists "earthdistance";
-- moddatetime NÃO está disponível no plano free do Supabase
-- usamos uma função manual equivalente:

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. FUNÇÃO is_admin() — security definer, evita recursão em RLS
--    (mesmo padrão já usado no RhoneyInc holding)
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 2. PROFILES (dono do pet)
-- ---------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  avatar_url text,
  city text,
  country text,
  lat double precision,
  lng double precision,
  plan text not null default 'free' check (plan in ('free','premium','petshop_partner')),
  is_petshop boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_profiles_updated
  before update on public.profiles
  for each row execute procedure public.set_updated_at();

-- cria profile automaticamente após signup (qualquer provedor social)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, full_name, avatar_url)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', 'Tutor'), new.raw_user_meta_data->>'avatar_url');
  return new;
end;
$$;

create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---------------------------------------------------------------------
-- 3. PETS (carteirinha digital)
-- ---------------------------------------------------------------------
create table public.pets (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  species text not null,
  breed text,
  age_years numeric check (age_years >= 0 and age_years < 100),
  weight_kg numeric check (weight_kg >= 0 and weight_kg < 200),
  sex text check (sex in ('macho','femea')),
  color text check (char_length(color) <= 40),
  bio text,
  photo_url text,
  vaccine_status jsonb default '[]'::jsonb,
  city text,
  country text,
  rank_score integer not null default 0, -- recalculado via trigger de likes
  created_at timestamptz not null default now()
);

-- lista de raças por espécie, cresce sozinha conforme os tutores cadastram
-- (sem repetir nome — dedup por espécie + nome em minúsculas)
create table public.breeds (
  id uuid primary key default uuid_generate_v4(),
  species text not null check (species in ('cao','gato','outro')),
  name text not null check (char_length(name) <= 60),
  created_at timestamptz not null default now()
);
create unique index idx_breeds_unique on public.breeds (species, lower(name));

create index idx_pets_owner on public.pets(owner_id);
create index idx_pets_city on public.pets(city, country);

-- ---------------------------------------------------------------------
-- 4. POSTS (feed)
-- ---------------------------------------------------------------------
create table public.posts (
  id uuid primary key default uuid_generate_v4(),
  pet_id uuid not null references public.pets(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  media_url text,
  media_type text not null default 'image' check (media_type in ('image','video')),
  caption text,
  created_at timestamptz not null default now()
);

create index idx_posts_pet on public.posts(pet_id);
create index idx_posts_created on public.posts(created_at desc);

-- ---------------------------------------------------------------------
-- 5. LIKES (ranqueamento)
-- ---------------------------------------------------------------------
create table public.likes (
  id uuid primary key default uuid_generate_v4(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  reaction_type text not null default 'curtir' check (reaction_type in ('curtir','amei')),
  created_at timestamptz not null default now(),
  unique (post_id, user_id) -- 1 reação por pessoa por post (troca o tipo, não duplica)
);

create index idx_likes_post on public.likes(post_id);

-- recalcula rank_score do pet sempre que um like OU comentário é criado/removido
-- (comentário também pontua no ranking — decisão de produto: interação de
-- verdade, não só curtida rápida, deve pesar no posicionamento).
-- comentário conta por (post, autor) DISTINTO, não por linha — diferente de
-- likes (que já tem "unique(post_id,user_id)"), comments não tem essa
-- constraint, e contar count(*) bruto deixava qualquer conta autenticada
-- inflar o próprio rank_score comentando em loop no próprio post. Achado da
-- auditoria meupet-security nesta mesma sessão em que o campo foi criado.
create or replace function public.recalc_pet_rank()
returns trigger language plpgsql security definer as $$
declare target_pet uuid;
begin
  select pet_id into target_pet from public.posts where id = coalesce(new.post_id, old.post_id);
  update public.pets set rank_score = (
    (select count(*) from public.likes l join public.posts p on p.id = l.post_id where p.pet_id = target_pet)
    +
    (select count(distinct (c.post_id, c.user_id)) from public.comments c join public.posts p on p.id = c.post_id where p.pet_id = target_pet)
  ) where id = target_pet;
  return null;
end;
$$;

create trigger trg_likes_recalc
  after insert or delete on public.likes
  for each row execute procedure public.recalc_pet_rank();

create trigger trg_comments_recalc
  after insert or delete on public.comments
  for each row execute procedure public.recalc_pet_rank();

-- view de ranking por escopo geográfico (bairro fica a cargo do app, aqui vai cidade/país)
-- expõe latest_post_id porque "likes" referencia posts(id), não pets(id) —
-- o app precisa desse id para saber em qual post registrar a curtida.
-- latest_post_media_url/type alimentam o card do feed (foto ou vídeo do
-- último post, em vez de só a foto de perfil do pet)
create or replace view public.pet_rankings as
  select p.id, p.name, p.photo_url, p.city, p.country, p.rank_score,
         rank() over (partition by p.city order by p.rank_score desc) as rank_city,
         rank() over (partition by p.country order by p.rank_score desc) as rank_country,
         (select po.id from public.posts po where po.pet_id = p.id order by po.created_at desc limit 1) as latest_post_id,
         p.species, p.owner_id,
         pr.full_name as owner_name,
         p.sex,
         (select po.media_url from public.posts po where po.pet_id = p.id order by po.created_at desc limit 1) as latest_post_media_url,
         (select po.media_type from public.posts po where po.pet_id = p.id order by po.created_at desc limit 1) as latest_post_media_type
  from public.pets p
  join public.profiles pr on pr.id = p.owner_id;

-- ---------------------------------------------------------------------
-- 5b. COMMENTS (aninhados — comentário e resposta a resposta, tipo Facebook)
-- ---------------------------------------------------------------------
create table public.comments (
  id uuid primary key default uuid_generate_v4(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  parent_comment_id uuid references public.comments(id) on delete cascade,
  content text not null check (char_length(content) > 0 and char_length(content) <= 2000),
  created_at timestamptz not null default now()
);
create index idx_comments_post on public.comments(post_id);
create index idx_comments_parent on public.comments(parent_comment_id);

-- trava parent_comment_id pra só apontar pra comentário do MESMO post — sem
-- isso, a policy de insert (só valida user_id) deixaria criar uma resposta
-- "filha" de um comentário de outro post, gerando uma linha órfã/inconsistente
create or replace function public.check_comment_same_post()
returns trigger language plpgsql as $$
declare parent_post uuid;
begin
  if new.parent_comment_id is not null then
    select post_id into parent_post from public.comments where id = new.parent_comment_id;
    if parent_post is null or parent_post <> new.post_id then
      raise exception 'parent_comment_id deve pertencer ao mesmo post_id';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_comments_same_post
  before insert or update on public.comments
  for each row execute procedure public.check_comment_same_post();

-- ---------------------------------------------------------------------
-- 5c. FOLLOWS (seguir pet e/ou seguir tutor — os dois, independentes)
-- ---------------------------------------------------------------------
create table public.pet_follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, pet_id)
);
create table public.profile_follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followed_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followed_id),
  check (follower_id <> followed_id)
);

-- ---------------------------------------------------------------------
-- 5d. COMPARTILHAMENTOS DE POST — antes o botão de compartilhar só abria
-- o menu (WhatsApp/Instagram/etc), sem nenhum registro no banco. Agora
-- conta pro ranqueamento de postagens, então precisa existir de verdade.
-- 1 registro por pessoa por post (primary key composta) — do contrário
-- uma única conta clicando "compartilhar" em loop infla o ranque, mesmo
-- problema que a auditoria encontrou nos comentários.
-- ---------------------------------------------------------------------
create table public.post_shares (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table public.post_shares enable row level security;
create policy "post_shares_select_public" on public.post_shares for select using (true);
create policy "post_shares_insert_own" on public.post_shares for insert with check (auth.uid() = user_id);

-- o app assina mudanças em tempo real nessas 3 tabelas (likes, pet_follows,
-- post_shares) pra atualizar Feed/Ranque sem precisar recarregar a página.
-- achado durante essa sessão: a publication supabase_realtime estava sem
-- NENHUMA tabela registrada (gap pré-existente, não só de post_shares) —
-- sem isso, o app.channel(...).on('postgres_changes', ...) nunca dispara.
alter publication supabase_realtime add table public.likes, public.pet_follows, public.post_shares;

-- ranqueamento POR POSTAGEM (Feed e Ranque deixam de ser a mesma coisa):
-- pontuação = curtidas + amei (ambos já são linhas de "likes", sem
-- distinção de peso) + compartilhamentos únicos + seguidores do pet.
-- rank_city/rank_country alimentam a seção "Ranque" (Top 5 por recorte
-- geográfico); o Feed em si passa a ser cronológico, por postagem.
create or replace view public.post_rankings as
  with scored as (
    select po.id as post_id, po.pet_id, po.media_url, po.media_type, po.caption, po.created_at,
           p.name as pet_name, p.photo_url as pet_photo_url, p.species, p.sex, p.city, p.country,
           p.owner_id, pr.full_name as owner_name,
           (select count(*) from public.likes l where l.post_id = po.id) as likes_count,
           (select count(*) from public.post_shares s where s.post_id = po.id) as shares_count,
           (select count(*) from public.pet_follows pf where pf.pet_id = po.pet_id) as followers_count
    from public.posts po
    join public.pets p on p.id = po.pet_id
    join public.profiles pr on pr.id = p.owner_id
  )
  select *,
         (likes_count + shares_count + followers_count) as post_score,
         rank() over (partition by city order by (likes_count + shares_count + followers_count) desc) as rank_city,
         rank() over (partition by country order by (likes_count + shares_count + followers_count) desc) as rank_country
  from scored;

-- ---------------------------------------------------------------------
-- 6. ADOPTION_LISTINGS
-- ---------------------------------------------------------------------
create table public.adoption_listings (
  id uuid primary key default uuid_generate_v4(),
  created_by uuid not null references public.profiles(id) on delete cascade,
  pet_name text not null,
  species text not null,
  breed text,
  description text,
  photo_url text,
  ong_name text,
  city text,
  country text,
  lat double precision,
  lng double precision,
  status text not null default 'available' check (status in ('available','pending','adopted')),
  created_at timestamptz not null default now(),
  age_years numeric,
  weight_kg numeric,
  sex text check (sex in ('macho','femea')),
  size text check (size in ('pequeno','medio','grande')),
  neutered boolean,
  vaccinated boolean
);

create index idx_adoption_city on public.adoption_listings(city, country);

-- contato do doador (telefone/whatsapp) fica numa tabela separada porque RLS
-- é por linha, não por coluna — se ficasse na própria adoption_listings
-- (pública pra qualquer visitante via adoption_select_public), o telefone
-- vazaria pra qualquer robô que lesse a API direto, mesmo escondendo na UI.
create table public.adoption_contacts (
  listing_id uuid primary key references public.adoption_listings(id) on delete cascade,
  phone text not null
);
alter table public.adoption_contacts enable row level security;
-- sem policy de SELECT aqui de propósito — ninguém lê essa tabela direto,
-- nem autenticado (RLS nega por padrão sem uma policy correspondente).
-- a auditoria meupet-security apontou que "qualquer autenticado" era
-- permissivo demais: uma única conta grátis conseguia baixar o telefone de
-- TODOS os doadores numa query só. A leitura agora só acontece via a função
-- reveal_adoption_contact() abaixo, que loga quem pediu o quê e aplica cota.
create policy "adoption_contacts_insert_own" on public.adoption_contacts
  for insert with check (
    exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
  );
create policy "adoption_contacts_update_own" on public.adoption_contacts
  for update using (
    exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
  );
create index idx_adoption_status on public.adoption_listings(status);

-- registro de quem já revelou o contato de qual anúncio — usado só pela
-- função abaixo pra aplicar a cota de 20 contatos novos por usuário a cada 24h
create table public.adoption_contact_reveals (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  listing_id uuid not null references public.adoption_listings(id) on delete cascade,
  revealed_at timestamptz not null default now(),
  unique (user_id, listing_id)
);
alter table public.adoption_contact_reveals enable row level security;

create or replace function public.reveal_adoption_contact(p_listing_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_count int;
begin
  if auth.uid() is null then
    raise exception 'Login necessário';
  end if;

  -- rever a mesma listing de novo não consome cota
  if not exists (
    select 1 from public.adoption_contact_reveals
    where user_id = auth.uid() and listing_id = p_listing_id
  ) then
    select count(*) into v_count
    from public.adoption_contact_reveals
    where user_id = auth.uid() and revealed_at > now() - interval '24 hours';

    if v_count >= 20 then
      raise exception 'Limite de contatos revelados nas últimas 24h atingido — tente novamente mais tarde.';
    end if;

    insert into public.adoption_contact_reveals (user_id, listing_id)
    values (auth.uid(), p_listing_id)
    on conflict (user_id, listing_id) do nothing;
  end if;

  select phone into v_phone from public.adoption_contacts where listing_id = p_listing_id;
  return v_phone;
end;
$$;

revoke all on function public.reveal_adoption_contact(uuid) from public;
grant execute on function public.reveal_adoption_contact(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 7. PETSHOPS (geolocalização em tempo real)
-- ---------------------------------------------------------------------
create table public.petshops (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid references public.profiles(id) on delete set null,
  name text not null,
  address text,
  city text not null,
  country text not null,
  lat double precision not null,
  lng double precision not null,
  rating numeric default 0,
  opening_hours jsonb,
  is_partner boolean not null default false,
  partner_plan text check (partner_plan in (null,'basic','featured')),
  created_at timestamptz not null default now()
);

create index idx_petshops_city on public.petshops(city, country);
create index idx_petshops_geo on public.petshops using gist (
  ll_to_earth(lat, lng)
);

-- função para buscar petshops num raio (km), usada pelo app em qualquer cidade/país
create or replace function public.petshops_near(p_lat double precision, p_lng double precision, p_radius_km integer default 10)
returns setof public.petshops
language sql stable as $$
  select * from public.petshops
  where earth_box(ll_to_earth(p_lat, p_lng), p_radius_km * 1000) @> ll_to_earth(lat, lng)
    and earth_distance(ll_to_earth(p_lat, p_lng), ll_to_earth(lat, lng)) <= p_radius_km * 1000
  order by earth_distance(ll_to_earth(p_lat, p_lng), ll_to_earth(lat, lng)) asc;
$$;

-- trava is_partner/partner_plan pra não-admin, em INSERT e UPDATE. A RLS de
-- petshops (mais abaixo) só valida "auth.uid() = owner_id", então sem essa
-- trava um dono comum conseguiria se auto-declarar "Parceiro" (is_partner=true)
-- sem pagar — o selo de patrocínio do MeuPet Business só pode vir de um admin,
-- depois do pagamento combinado no fluxo de partner_leads.
create or replace function public.protect_partner_columns()
returns trigger language plpgsql security definer as $$
begin
  if public.is_admin() then
    return new;
  end if;
  if TG_OP = 'INSERT' then
    new.is_partner := false;
    new.partner_plan := null;
  else
    new.is_partner := old.is_partner;
    new.partner_plan := old.partner_plan;
  end if;
  return new;
end;
$$;

create trigger trg_petshops_protect_partner
  before insert or update on public.petshops
  for each row execute procedure public.protect_partner_columns();

-- ---------------------------------------------------------------------
-- 8. PRODUCTS (vitrine / marketplace)
-- ---------------------------------------------------------------------
create table public.products (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  price_cents integer not null,
  image_url text,
  shop_name text not null,
  affiliate_url text not null,
  category text,
  is_sponsored boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 9. GAMES (hub)
-- ---------------------------------------------------------------------
create table public.games (
  id uuid primary key default uuid_generate_v4(),
  title text not null,
  url text not null,
  cover_url text,
  is_sponsored boolean not null default false
);

-- ---------------------------------------------------------------------
-- 10. PLANS + SUBSCRIPTIONS (monetização)
-- ---------------------------------------------------------------------
create table public.plans (
  id text primary key, -- 'free' | 'premium' | 'petshop_partner'
  name text not null,
  price_cents integer not null,
  features jsonb not null default '[]'::jsonb
);

create table public.subscriptions (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  plan_id text not null references public.plans(id),
  status text not null default 'active' check (status in ('active','canceled','past_due')),
  started_at timestamptz not null default now(),
  ends_at timestamptz
);

create index idx_subscriptions_user on public.subscriptions(user_id);

-- ---------------------------------------------------------------------
-- 10b. SPONSORS (banners de patrocínio dinâmicos — monetização)
-- ---------------------------------------------------------------------
create table public.sponsors (
  id uuid primary key default uuid_generate_v4(),
  slot text not null,              -- ex: 'banner_feed', 'banner_petshops'
  label text not null default 'Publicidade',
  headline text not null,
  cta_text text not null default 'Ver oferta',
  target_url text not null,
  active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now()
);

create index idx_sponsors_slot on public.sponsors(slot, active);

-- ---------------------------------------------------------------------
-- 11. AD_IMPRESSIONS (telemetria de monetização por anúncio)
-- ---------------------------------------------------------------------
create table public.ad_impressions (
  id uuid primary key default uuid_generate_v4(),
  slot text not null,
  user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 11b. PARTNER_LEADS (MeuPet Business — cadastro de parceiros/patrocinadores)
-- Fluxo: negócio preenche o formulário → vira lead 'novo' aqui → time comercial
-- entra em contato e cobra manualmente (Pix/boleto) → só então um admin ativa
-- de verdade petshops.is_partner ou cria a linha em public.sponsors.
-- Isso é proposital: o próprio solicitante NUNCA pode se auto-promover a
-- parceiro/patrocinador direto nas tabelas que controlam o que é exibido.
-- ---------------------------------------------------------------------
create table public.partner_leads (
  id uuid primary key default uuid_generate_v4(),
  created_by uuid references public.profiles(id) on delete set null, -- null se enviado sem login
  business_name text not null check (char_length(business_name) <= 200),
  contact_name text not null check (char_length(contact_name) <= 200),
  contact_email text not null check (char_length(contact_email) <= 200),
  contact_phone text check (char_length(contact_phone) <= 40),
  city text check (char_length(city) <= 120),
  business_type text,   -- 'petshop' | 'veterinaria' | 'produto' | 'servico' | 'outro'
  plan_interest text not null check (plan_interest in ('basico','destaque','banner')),
  message text check (char_length(message) <= 2000),
  status text not null default 'novo' check (status in ('novo','em_contato','aprovado','recusado')),
  created_at timestamptz not null default now()
);

create index idx_partner_leads_status on public.partner_leads(status);

-- ---------------------------------------------------------------------
-- 12. REPORTS (moderação / "agente de segurança")
-- ---------------------------------------------------------------------
create table public.reports (
  id uuid primary key default uuid_generate_v4(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_type text not null check (target_type in ('post','pet','adoption_listing','petshop','profile')),
  target_id uuid not null,
  reason text not null,
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
alter table public.profiles enable row level security;
alter table public.pets enable row level security;
alter table public.breeds enable row level security;
alter table public.posts enable row level security;
alter table public.likes enable row level security;
alter table public.comments enable row level security;
alter table public.pet_follows enable row level security;
alter table public.profile_follows enable row level security;
alter table public.adoption_listings enable row level security;
alter table public.petshops enable row level security;
alter table public.products enable row level security;
alter table public.games enable row level security;
alter table public.plans enable row level security;
alter table public.subscriptions enable row level security;
alter table public.sponsors enable row level security;
alter table public.ad_impressions enable row level security;
alter table public.partner_leads enable row level security;
alter table public.reports enable row level security;
alter table public.admins enable row level security;

-- PROFILES: leitura pública (nome/avatar/cidade), escrita só do dono ou admin
create policy "profiles_select_public" on public.profiles for select using (true);
create policy "profiles_update_own" on public.profiles for update using (auth.uid() = id or public.is_admin());
create policy "profiles_insert_self" on public.profiles for insert with check (auth.uid() = id);

-- PETS: leitura pública, escrita do dono
create policy "pets_select_public" on public.pets for select using (true);
create policy "pets_insert_own" on public.pets for insert with check (auth.uid() = owner_id);
create policy "pets_update_own" on public.pets for update using (auth.uid() = owner_id or public.is_admin());
create policy "pets_delete_own" on public.pets for delete using (auth.uid() = owner_id or public.is_admin());

-- BREEDS: leitura pública (autocomplete), qualquer autenticado pode acrescentar
-- uma raça nova (nunca editar/remover — é só uma lista de referência que cresce)
create policy "breeds_select_public" on public.breeds for select using (true);
create policy "breeds_insert_auth" on public.breeds for insert with check (auth.uid() is not null);

-- POSTS: leitura pública, escrita do dono do pet
create policy "posts_select_public" on public.posts for select using (true);
-- pet_id precisa mesmo pertencer a quem está postando — sem isso, qualquer
-- autenticado poderia postar em nome do pet de outra pessoa (pets é leitura
-- pública, então o id de qualquer pet é conhecível)
create policy "posts_insert_own" on public.posts for insert with check (
  auth.uid() = owner_id and exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid())
);
create policy "posts_delete_own" on public.posts for delete using (auth.uid() = owner_id or public.is_admin());
-- editar caption/mídia direto do card do feed/ranque, sem passar pelo
-- perfil — with check espelha a de insert pra impedir que o dono
-- reatribua o próprio post pra um pet que não é dele
create policy "posts_update_own" on public.posts for update
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id and exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid()));

-- LIKES: leitura pública, qualquer autenticado curte/descurte só por si.
-- update_own existe pra trocar o tipo de reação (curtir <-> amei) sem duplicar linha
create policy "likes_select_public" on public.likes for select using (true);
create policy "likes_insert_own" on public.likes for insert with check (auth.uid() = user_id);
create policy "likes_update_own" on public.likes for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "likes_delete_own" on public.likes for delete using (auth.uid() = user_id);

-- COMMENTS: leitura pública, escrita/edição/remoção só de quem comentou (ou admin)
create policy "comments_select_public" on public.comments for select using (true);
create policy "comments_insert_own" on public.comments for insert with check (auth.uid() = user_id);
create policy "comments_update_own" on public.comments for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "comments_delete_own" on public.comments for delete using (auth.uid() = user_id or public.is_admin());

-- PET_FOLLOWS / PROFILE_FOLLOWS: leitura pública (contagem de seguidores),
-- só o próprio seguidor cria/remove o próprio follow
create policy "pet_follows_select_public" on public.pet_follows for select using (true);
create policy "pet_follows_insert_own" on public.pet_follows for insert with check (auth.uid() = follower_id);
create policy "pet_follows_delete_own" on public.pet_follows for delete using (auth.uid() = follower_id);

create policy "profile_follows_select_public" on public.profile_follows for select using (true);
create policy "profile_follows_insert_own" on public.profile_follows for insert with check (auth.uid() = follower_id);
create policy "profile_follows_delete_own" on public.profile_follows for delete using (auth.uid() = follower_id);

-- ADOPTION_LISTINGS: leitura pública, escrita de quem criou
create policy "adoption_select_public" on public.adoption_listings for select using (true);
create policy "adoption_insert_auth" on public.adoption_listings for insert with check (auth.uid() = created_by);
create policy "adoption_update_own" on public.adoption_listings for update using (auth.uid() = created_by or public.is_admin());

-- PETSHOPS: leitura pública, escrita do owner do petshop ou admin
create policy "petshops_select_public" on public.petshops for select using (true);
create policy "petshops_insert_own" on public.petshops for insert with check (auth.uid() = owner_id or public.is_admin());
create policy "petshops_update_own" on public.petshops for update using (auth.uid() = owner_id or public.is_admin());

-- PRODUCTS / GAMES / PLANS: leitura pública, escrita só admin
create policy "products_select_public" on public.products for select using (true);
create policy "products_admin_write" on public.products for all using (public.is_admin()) with check (public.is_admin());

create policy "games_select_public" on public.games for select using (true);
create policy "games_admin_write" on public.games for all using (public.is_admin()) with check (public.is_admin());

create policy "plans_select_public" on public.plans for select using (true);
create policy "plans_admin_write" on public.plans for all using (public.is_admin()) with check (public.is_admin());

-- SUBSCRIPTIONS: usuário só vê a própria; escrita via service_role (webhook de pagamento) ou admin
create policy "subs_select_own" on public.subscriptions for select using (auth.uid() = user_id or public.is_admin());
create policy "subs_admin_write" on public.subscriptions for all using (public.is_admin()) with check (public.is_admin());

-- SPONSORS: leitura pública só do que está ativo e dentro da vigência, escrita só admin
create policy "sponsors_select_public" on public.sponsors for select using (
  active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at >= now())
);
create policy "sponsors_admin_write" on public.sponsors for all using (public.is_admin()) with check (public.is_admin());

-- AD_IMPRESSIONS: insert público (telemetria, inclusive anônimo), leitura só admin.
-- user_id só pode ser nulo (evento anônimo) ou o próprio usuário logado —
-- impede atribuir/poluir uma impressão/clique em nome de outro usuário real.
-- Não impede flood volumétrico com a anon key (isso exigiria rate limit fora
-- do Postgres, ex: Edge Function) — mitigação de identidade, não de volume.
create policy "ads_insert_any" on public.ad_impressions for insert with check (user_id is null or user_id = auth.uid());
create policy "ads_select_admin" on public.ad_impressions for select using (public.is_admin());

-- PARTNER_LEADS: qualquer um (mesmo sem login) envia o formulário de parceria;
-- só o próprio autor logado ou admin consegue ler; só admin atualiza o status
-- (aprovar vira ação manual do time comercial, nunca automática)
-- created_by só pode ser nulo (lead anônimo) ou o próprio usuário logado —
-- impede forjar um lead em nome do uid de outra pessoa (mesmo padrão de
-- ad_impressions)
create policy "partner_leads_insert_any" on public.partner_leads for insert with check (
  created_by is null or created_by = auth.uid()
);
create policy "partner_leads_select_own_or_admin" on public.partner_leads for select using (
  (created_by is not null and auth.uid() = created_by) or public.is_admin()
);
create policy "partner_leads_update_admin" on public.partner_leads for update using (public.is_admin());

-- REPORTS: qualquer autenticado reporta, só admin lê/atualiza ("agente de segurança/moderação")
create policy "reports_insert_auth" on public.reports for insert with check (auth.uid() = reporter_id);
create policy "reports_select_admin" on public.reports for select using (public.is_admin());
create policy "reports_update_admin" on public.reports for update using (public.is_admin());

-- ADMINS: só admin enxerga a própria tabela de admins
create policy "admins_select_admin" on public.admins for select using (public.is_admin());

-- =====================================================================
-- STORAGE (fotos de pets, avatares, posts)
-- =====================================================================
-- 1) Criar o bucket "pet-media" pelo painel Storage (público = true)
--    ou via SQL:
-- limite de 20MB e só imagem/vídeo — sem isso, avatar/post (que não passam
-- pelo recorte via canvas) podiam subir qualquer arquivo de qualquer tamanho.
-- 20MB dá pra uns 20-30s de vídeo curto no feed sem estourar o plano grátis.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pet-media', 'pet-media', true, 20971520, array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm'])
on conflict (id) do update set
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- 2) Policies do bucket: leitura pública, upload/edição só dentro da
--    própria pasta do usuário (ex: pet-media/<user_id>/foto.jpg)
create policy "pet_media_select_public" on storage.objects
  for select using (bucket_id = 'pet-media');

create policy "pet_media_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'pet-media' and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "pet_media_update_own" on storage.objects
  for update using (
    bucket_id = 'pet-media' and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "pet_media_delete_own" on storage.objects
  for delete using (
    bucket_id = 'pet-media' and auth.uid()::text = (storage.foldername(name))[1]
  );

-- =====================================================================
-- SEED inicial de planos
-- =====================================================================
insert into public.plans (id, name, price_cents, features) values
  ('free', 'Free', 0, '["Carteirinha básica","Feed e curtidas","Busca de petshops","Com anúncios"]'),
  ('premium', 'Premium', 1400, '["Sem anúncios","Boost no ranking","Carteirinha personalizada","Acesso antecipado a games"]'),
  ('petshop_partner', 'Petshop Parceiro', 4900, '["Pin destacado no mapa","Vitrine própria","Relatório de alcance","Selo de verificado"]')
on conflict (id) do nothing;
