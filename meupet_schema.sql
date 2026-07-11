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
-- NUNCA guarde lat/lng exatos aqui: profiles é select-público
-- ("profiles_select_public ... using (true)"), então qualquer coisa
-- nessa tabela é lida por qualquer um com a anon key (embutida no HTML).
-- Já existiu uma coluna lat/lng aqui, sem uso real (0 linhas populadas) e
-- publicamente exposta — achado de auditoria de segurança. Coordenada
-- precisa de localização só entra em tabela owner-only, tipo
-- profile_private_info ou push_subscriptions.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  avatar_url text,
  city text,
  country text,
  plan text not null default 'free' check (plan in ('free','premium','petshop_partner')),
  is_petshop boolean not null default false,
  is_banned boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_profiles_updated
  before update on public.profiles
  for each row execute procedure public.set_updated_at();

-- plan/is_petshop só podem ser escritos pela automação de pagamento (webhook
-- via service_role) — a policy profiles_update_own deixa o dono editar o
-- próprio perfil livremente (sem restrição de coluna), então sem isso ele
-- poderia se auto-promover a 'premium' direto pelo devtools, de graça
create or replace function public.protect_profile_plan()
returns trigger language plpgsql as $$
begin
  if current_user <> 'service_role' then
    if new.plan is distinct from old.plan then new.plan := old.plan; end if;
    if new.is_petshop is distinct from old.is_petshop then new.is_petshop := old.is_petshop; end if;
  end if;
  return new;
end;
$$;

create trigger trg_protect_profile_plan before update on public.profiles
  for each row execute procedure public.protect_profile_plan();

-- is_banned só pode ser alterado por quem passa is_admin() — diferente de
-- plan (só service_role/webhook), banir precisa poder ser feito por uma
-- sessão admin comum a partir do painel; sem essa trava, o próprio usuário
-- banido poderia se desbanir com um update direto via devtools (a policy
-- profiles_update_own permite auth.uid() = id sem checar essa coluna)
create or replace function public.protect_profile_ban()
returns trigger language plpgsql as $$
begin
  if not public.is_admin() and new.is_banned is distinct from old.is_banned then
    new.is_banned := old.is_banned;
  end if;
  return new;
end;
$$;

create trigger trg_protect_profile_ban before update on public.profiles
  for each row execute procedure public.protect_profile_ban();

-- checa se QUEM ESTÁ CHAMANDO (auth.uid()) está banido — usada nas policies
-- de insert/update de conteúdo abaixo, pra banir de verdade bloquear no
-- servidor, não só esconder o botão no front-end
create or replace function public.is_banned()
returns boolean
language sql
security definer
set search_path = public
as $$
  select coalesce((select is_banned from public.profiles where id = auth.uid()), false);
$$;

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
  city text,
  country text,
  rank_score integer not null default 0, -- recalculado via trigger de likes
  -- "badge in (null,...)" NÃO valida nada: x = null é NULL (não FALSE), e
  -- CHECK só rejeita quando a expressão é FALSE — todo valor passaria.
  -- Precisa ser "is null or badge in (...)" pra rejeitar valor de verdade.
  badge text check (badge is null or badge in ('estrela_nascente','popular','viral','lenda')),
  created_at timestamptz not null default now()
);

-- badge só pode ser escrito pela automação (n8n via service_role) — a
-- policy pets_update_own deixa o dono editar o próprio pet livremente,
-- então sem isso ele poderia se auto-promover a 'lenda' direto pelo app
create or replace function public.protect_pet_badge()
returns trigger language plpgsql as $$
begin
  if new.badge is distinct from old.badge and current_user <> 'service_role' then
    new.badge := old.badge;
  end if;
  return new;
end;
$$;

create trigger trg_protect_pet_badge before update on public.pets
  for each row execute procedure public.protect_pet_badge();

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
-- 3b. VACINAÇÃO (alerta na carteirinha + seção "Cuidados")
-- registro de saúde é dado sensível: diferente do resto do app (que é
-- majoritariamente público), aqui SÓ o próprio tutor lê/escreve —
-- substituiu a coluna pets.vaccine_status (jsonb, nunca chegou a ser
-- usada) por uma tabela relacional de verdade, mais fácil de consultar
-- pra "quais pets têm vacina vencendo" sem precisar parsear jsonb
-- ---------------------------------------------------------------------
create table public.pet_vaccinations (
  id uuid primary key default uuid_generate_v4(),
  pet_id uuid not null references public.pets(id) on delete cascade,
  vaccine_name text not null,
  date_given date,
  next_due_date date,
  notes text,
  created_at timestamptz not null default now()
);
create index idx_pet_vaccinations_pet on public.pet_vaccinations(pet_id);
create index idx_pet_vaccinations_due on public.pet_vaccinations(next_due_date);

alter table public.pet_vaccinations enable row level security;
create policy "pet_vaccinations_select_own" on public.pet_vaccinations for select using (
  exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid())
);
create policy "pet_vaccinations_insert_own" on public.pet_vaccinations for insert with check (
  exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid())
);
create policy "pet_vaccinations_update_own" on public.pet_vaccinations for update using (
  exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid())
) with check (
  exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid())
);
create policy "pet_vaccinations_delete_own" on public.pet_vaccinations for delete using (
  exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid())
);

-- ---------------------------------------------------------------------
-- 3c. INFORMAÇÕES PRIVADAS DO TUTOR (gênero, nascimento, bairro, dispositivo)
--     separado de profiles (que é select-public) porque é dado sensível
--     usado só para estatísticas agregadas no painel ADM
-- ---------------------------------------------------------------------
create table public.profile_private_info (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  gender text check (gender in ('masculino','feminino','outro','prefere_nao_informar')),
  birth_date date,
  neighborhood text,
  last_device text check (last_device in ('mobile_ios','mobile_android','tablet_android','mobile_outro','desktop')),
  updated_at timestamptz not null default now()
);

create trigger trg_ppi_updated
  before update on public.profile_private_info
  for each row execute procedure public.set_updated_at();

alter table public.profile_private_info enable row level security;
create policy "ppi_select_own" on public.profile_private_info for select using (auth.uid() = profile_id or public.is_admin());
create policy "ppi_insert_own" on public.profile_private_info for insert with check (auth.uid() = profile_id);
create policy "ppi_update_own" on public.profile_private_info for update using (auth.uid() = profile_id) with check (auth.uid() = profile_id);
create policy "ppi_delete_own" on public.profile_private_info for delete using (auth.uid() = profile_id);

-- só toca a coluna last_device (nunca mexe em gênero/nascimento/bairro já
-- salvos) — evita que o registro automático de dispositivo a cada login
-- sobrescreva dados que o tutor preencheu manualmente no perfil
create or replace function public.set_my_device(p_device text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.profile_private_info (profile_id, last_device)
  values (auth.uid(), p_device)
  on conflict (profile_id) do update set last_device = excluded.last_device, updated_at = now();
end;
$$;
revoke all on function public.set_my_device(text) from public;
grant execute on function public.set_my_device(text) to authenticated;

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
create policy "post_shares_insert_own" on public.post_shares for insert with check (auth.uid() = user_id and not public.is_banned());

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
           (select count(*) from public.pet_follows pf where pf.pet_id = po.pet_id) as followers_count,
           (select count(*) from public.comments c where c.post_id = po.id) as comments_count
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
-- select restrito ao próprio dono (pra ele ver/editar o telefone que ele
-- mesmo cadastrou) — continua sem policy pra qualquer OUTRO autenticado,
-- então não reabre o vazamento em massa que a auditoria corrigiu
create policy "adoption_contacts_select_own" on public.adoption_contacts
  for select using (
    exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
  );
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
  -- nullable: feedback/bug report enviado deslogado não tem reporter
  reporter_id uuid references public.profiles(id) on delete cascade,
  -- 'app' cobre feedback/bug geral do app (não é sobre um post/pet específico)
  target_type text not null check (target_type in ('post','pet','adoption_listing','petshop','profile','app')),
  target_id uuid not null,
  -- cap de tamanho: reports aceita insert anônimo (sem login), então precisa
  -- de um limite pra não virar vetor de flood/storage abuse (mesmo padrão
  -- de feedback_posts.content)
  reason text not null check (char_length(reason) <= 3000),
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 10. FEEDBACK (mural público de opiniões/sugestões — qualquer um responde e curte)
-- ---------------------------------------------------------------------
create table public.feedback_posts (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  content text not null check (char_length(content) > 0 and char_length(content) <= 2000),
  created_at timestamptz not null default now()
);
create index idx_feedback_posts_created on public.feedback_posts(created_at desc);

alter table public.feedback_posts enable row level security;
create policy "feedback_posts_select_public" on public.feedback_posts for select using (true);
create policy "feedback_posts_insert_own" on public.feedback_posts for insert with check (auth.uid() = owner_id and not public.is_banned());
create policy "feedback_posts_update_own" on public.feedback_posts for update using (auth.uid() = owner_id or public.is_admin()) with check (auth.uid() = owner_id or public.is_admin());
create policy "feedback_posts_delete_own" on public.feedback_posts for delete using (auth.uid() = owner_id or public.is_admin());

create table public.feedback_comments (
  id uuid primary key default uuid_generate_v4(),
  feedback_id uuid not null references public.feedback_posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  content text not null check (char_length(content) > 0 and char_length(content) <= 2000),
  created_at timestamptz not null default now()
);
create index idx_feedback_comments_feedback on public.feedback_comments(feedback_id);

alter table public.feedback_comments enable row level security;
create policy "feedback_comments_select_public" on public.feedback_comments for select using (true);
create policy "feedback_comments_insert_own" on public.feedback_comments for insert with check (auth.uid() = user_id and not public.is_banned());
create policy "feedback_comments_update_own" on public.feedback_comments for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "feedback_comments_delete_own" on public.feedback_comments for delete using (auth.uid() = user_id or public.is_admin());

create table public.feedback_likes (
  feedback_id uuid not null references public.feedback_posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (feedback_id, user_id)
);
create index idx_feedback_likes_feedback on public.feedback_likes(feedback_id);

alter table public.feedback_likes enable row level security;
create policy "feedback_likes_select_public" on public.feedback_likes for select using (true);
create policy "feedback_likes_insert_own" on public.feedback_likes for insert with check (auth.uid() = user_id and not public.is_banned());
create policy "feedback_likes_delete_own" on public.feedback_likes for delete using (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- 11. PAINEL ADM — funções agregadas (nunca expõem linha individual,
--     só contagens/buckets; bloqueadas por is_admin() dentro da função)
-- ---------------------------------------------------------------------
create or replace function public.am_i_admin()
returns boolean language sql security definer set search_path = public as $$
  select public.is_admin();
$$;
revoke all on function public.am_i_admin() from public;
grant execute on function public.am_i_admin() to authenticated;

create or replace function public.admin_dashboard_stats()
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  select jsonb_build_object(
    'total_users', (select count(*) from public.profiles),
    'total_pets', (select count(*) from public.pets),
    'total_posts', (select count(*) from public.posts),
    'total_feedbacks', (select count(*) from public.feedback_posts),
    'by_pet_sex', (
      select coalesce(jsonb_object_agg(s.label, s.cnt), '{}'::jsonb) from (
        select coalesce(pt.sex, 'nao_informado') as label, count(*) as cnt
        from public.pets pt
        group by 1
      ) s
    ),
    'by_device', (
      select coalesce(jsonb_object_agg(d.label, d.cnt), '{}'::jsonb) from (
        select coalesce(ppi.last_device, 'desconhecido') as label, count(*) as cnt
        from public.profiles p left join public.profile_private_info ppi on ppi.profile_id = p.id
        group by 1
      ) d
    ),
    'by_country', (
      select coalesce(jsonb_object_agg(c.label, c.cnt), '{}'::jsonb) from (
        select coalesce(p.country, 'nao_informado') as label, count(*) as cnt
        from public.profiles p group by 1 order by count(*) desc limit 15
      ) c
    ),
    'by_city', (
      select coalesce(jsonb_object_agg(c.label, c.cnt), '{}'::jsonb) from (
        select coalesce(p.city, 'nao_informado') as label, count(*) as cnt
        from public.profiles p group by 1 order by count(*) desc limit 15
      ) c
    ),
    'by_neighborhood', (
      select coalesce(jsonb_object_agg(n.label, n.cnt), '{}'::jsonb) from (
        select coalesce(ppi.neighborhood, 'nao_informado') as label, count(*) as cnt
        from public.profiles p left join public.profile_private_info ppi on ppi.profile_id = p.id
        group by 1 order by count(*) desc limit 15
      ) n
    ),
    'by_age_bucket', (
      select coalesce(jsonb_object_agg(a.label, a.cnt), '{}'::jsonb) from (
        select
          case
            when ppi.birth_date is null then 'nao_informado'
            when age(ppi.birth_date) < interval '18 years' then '<18'
            when age(ppi.birth_date) < interval '25 years' then '18-24'
            when age(ppi.birth_date) < interval '35 years' then '25-34'
            when age(ppi.birth_date) < interval '45 years' then '35-44'
            when age(ppi.birth_date) < interval '55 years' then '45-54'
            else '55+'
          end as label,
          count(*) as cnt
        from public.profiles p left join public.profile_private_info ppi on ppi.profile_id = p.id
        group by 1
      ) a
    )
  ) into result;

  return result;
end;
$$;
revoke all on function public.admin_dashboard_stats() from public;
grant execute on function public.admin_dashboard_stats() to authenticated;

-- ---------------------------------------------------------------------
-- 12. PUSH SUBSCRIPTIONS (alertas de petshops perto de você, mesmo com
--     o app fechado — enviados por um job agendado fora do banco, via
--     service_role, que ignora RLS; o cliente só gerencia a própria linha)
-- ---------------------------------------------------------------------
create table public.push_subscriptions (
  id uuid primary key default uuid_generate_v4(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  -- localização capturada no momento em que o tutor ativa o alerta (o
  -- currentGeo já detectado na sessão) — fica aqui, tabela owner-only,
  -- em vez de profiles (select-público) ou de exigir profiles.lat/lng
  lat double precision,
  lng double precision,
  city text,
  last_notified_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_push_subscriptions_profile on public.push_subscriptions(profile_id);

alter table public.push_subscriptions enable row level security;
create policy "push_subs_select_own" on public.push_subscriptions for select using (auth.uid() = profile_id);
create policy "push_subs_insert_own" on public.push_subscriptions for insert with check (auth.uid() = profile_id);
create policy "push_subs_update_own" on public.push_subscriptions for update using (auth.uid() = profile_id) with check (auth.uid() = profile_id);
create policy "push_subs_delete_own" on public.push_subscriptions for delete using (auth.uid() = profile_id);
-- last_notified_at também é gravado pelo job agendado (service_role,
-- ignora RLS) depois de enviar o alerta

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
create policy "pets_insert_own" on public.pets for insert with check (auth.uid() = owner_id and not public.is_banned());
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
  auth.uid() = owner_id and not public.is_banned()
  and exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid())
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
create policy "likes_insert_own" on public.likes for insert with check (auth.uid() = user_id and not public.is_banned());
create policy "likes_update_own" on public.likes for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "likes_delete_own" on public.likes for delete using (auth.uid() = user_id);

-- COMMENTS: leitura pública, escrita/edição/remoção só de quem comentou (ou admin)
create policy "comments_select_public" on public.comments for select using (true);
create policy "comments_insert_own" on public.comments for insert with check (auth.uid() = user_id and not public.is_banned());
create policy "comments_update_own" on public.comments for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "comments_delete_own" on public.comments for delete using (auth.uid() = user_id or public.is_admin());

-- PET_FOLLOWS / PROFILE_FOLLOWS: leitura pública (contagem de seguidores),
-- só o próprio seguidor cria/remove o próprio follow
create policy "pet_follows_select_public" on public.pet_follows for select using (true);
create policy "pet_follows_insert_own" on public.pet_follows for insert with check (auth.uid() = follower_id and not public.is_banned());
create policy "pet_follows_delete_own" on public.pet_follows for delete using (auth.uid() = follower_id);

create policy "profile_follows_select_public" on public.profile_follows for select using (true);
create policy "profile_follows_insert_own" on public.profile_follows for insert with check (auth.uid() = follower_id and not public.is_banned());
create policy "profile_follows_delete_own" on public.profile_follows for delete using (auth.uid() = follower_id);

-- ADOPTION_LISTINGS: leitura pública, escrita de quem criou
create policy "adoption_select_public" on public.adoption_listings for select using (true);
create policy "adoption_insert_auth" on public.adoption_listings for insert with check (auth.uid() = created_by and not public.is_banned());
create policy "adoption_update_own" on public.adoption_listings for update using (auth.uid() = created_by or public.is_admin());
create policy "adoption_delete_own" on public.adoption_listings for delete using (auth.uid() = created_by or public.is_admin());

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
create policy "reports_insert_auth" on public.reports for insert with check ((auth.uid() = reporter_id or reporter_id is null) and not public.is_banned());
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

-- ---------------------------------------------------------------------
-- ADMIN — lista nominal de usuários (quem está usando o app)
--   security definer roda como o dono da função (postgres), que enxerga
--   auth.users mesmo com RLS ativo nela — só entra e-mail/último acesso
--   aqui dentro, nunca numa tabela/view pública. Bloqueado por is_admin().
-- ---------------------------------------------------------------------
create or replace function public.admin_user_list()
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  select coalesce(jsonb_agg(s.u order by s.last_sign_in_at desc nulls last), '[]'::jsonb) into result
  from (
    select jsonb_build_object(
      'id', p.id,
      'full_name', p.full_name,
      'email', au.email,
      'city', p.city,
      'country', p.country,
      'plan', p.plan,
      'is_banned', p.is_banned,
      'is_admin', exists(select 1 from public.admins a where a.user_id = p.id),
      'created_at', p.created_at,
      'last_sign_in_at', au.last_sign_in_at
    ) as u,
    au.last_sign_in_at
    from public.profiles p
    join auth.users au on au.id = p.id
  ) s;

  return result;
end;
$$;
revoke all on function public.admin_user_list() from public;
grant execute on function public.admin_user_list() to authenticated;

-- ---------------------------------------------------------------------
-- ADMIN — banir/desbanir, promover/rebaixar, aprovar parceria
-- ---------------------------------------------------------------------
create or replace function public.admin_set_user_banned(p_user_id uuid, p_banned boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  update public.profiles set is_banned = p_banned where id = p_user_id;
end;
$$;
revoke all on function public.admin_set_user_banned(uuid, boolean) from public;
grant execute on function public.admin_set_user_banned(uuid, boolean) to authenticated;

-- admins não tem policy de insert/delete (só select) — promoção/rebaixamento
-- só acontece por aqui dentro, nunca direto do client
create or replace function public.admin_promote_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  insert into public.admins (user_id) values (p_user_id) on conflict do nothing;
end;
$$;
revoke all on function public.admin_promote_user(uuid) from public;
grant execute on function public.admin_promote_user(uuid) to authenticated;

create or replace function public.admin_demote_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  if (select count(*) from public.admins) <= 1 then
    raise exception 'não é possível remover o último admin do app';
  end if;
  delete from public.admins where user_id = p_user_id;
end;
$$;
revoke all on function public.admin_demote_user(uuid) from public;
grant execute on function public.admin_demote_user(uuid) to authenticated;

create or replace function public.admin_approve_partner_lead(p_lead_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  update public.partner_leads set status = 'aprovado' where id = p_lead_id;
end;
$$;
revoke all on function public.admin_approve_partner_lead(uuid) from public;
grant execute on function public.admin_approve_partner_lead(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- ADMIN — relatório diário agregado, uso exclusivo de automação server-side
--   (n8n, chamado com a service_role key). Sem gate de is_admin() porque
--   quem chama é sempre service_role — não passa por sessão de usuário,
--   então auth.uid() seria sempre nulo aqui. A proteção é o grant: só
--   service_role pode executar, anon/authenticated são bloqueados.
-- ---------------------------------------------------------------------
create or replace function public.daily_report_stats()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'novos_usuarios', (select count(*) from public.profiles where created_at >= now() - interval '24 hours'),
    'curtidas', (select count(*) from public.likes where created_at >= now() - interval '24 hours'),
    'adocoes', (select count(*) from public.adoption_listings where status = 'available'),
    'reports', (select count(*) from public.reports where status = 'open'),
    'assinaturas', (select count(*) from public.subscriptions where status = 'active')
  );
$$;
revoke all on function public.daily_report_stats() from public;
revoke all on function public.daily_report_stats() from anon;
revoke all on function public.daily_report_stats() from authenticated;
grant execute on function public.daily_report_stats() to service_role;
