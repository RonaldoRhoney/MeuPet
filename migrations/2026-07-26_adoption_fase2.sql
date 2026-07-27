-- Fase 2: página de detalhes, solicitação estruturada, vídeo, contatos da
-- ONG e ordenação (mais próximo/recente/antigo/favoritado/visto/nome).

-- ============================================================
-- Campos novos em adoption_listings
-- ============================================================
alter table public.adoption_listings
  add column necessidades_especiais boolean,
  add column video_url text check (video_url is null or char_length(video_url) <= 300),
  add column ong_whatsapp text check (ong_whatsapp is null or char_length(ong_whatsapp) <= 30),
  add column ong_instagram text check (ong_instagram is null or char_length(ong_instagram) <= 100),
  add column ong_site text check (ong_site is null or char_length(ong_site) <= 300);

-- ============================================================
-- Solicitação estruturada de interesse (complementa a revelação direta de
-- WhatsApp via reveal_adoption_contact, que continua existindo como está)
-- ============================================================
create table public.adoption_requests (
  id uuid primary key default uuid_generate_v4(),
  listing_id uuid not null references public.adoption_listings(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) <= 120),
  phone text not null check (char_length(phone) <= 30),
  email text not null check (char_length(email) <= 200),
  message text check (message is null or char_length(message) <= 500),
  accepted_terms boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.adoption_requests enable row level security;

create policy "adoption_requests_insert_own" on public.adoption_requests
  for insert with check (auth.uid() = requester_id and accepted_terms = true);
create policy "adoption_requests_select_owner_or_requester" on public.adoption_requests
  for select using (
    requester_id = auth.uid()
    or exists (select 1 from public.adoption_listings l where l.id = listing_id and (l.created_by = auth.uid() or public.is_admin()))
  );

-- ============================================================
-- Visualizações (insert público simples, mesmo molde de ad_impressions;
-- só serve pra ordenação "mais visto", não é analytics individualizado)
-- ============================================================
create table public.adoption_views (
  id uuid primary key default uuid_generate_v4(),
  listing_id uuid not null references public.adoption_listings(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.adoption_views enable row level security;
create policy "adoption_views_insert_any" on public.adoption_views for insert with check (true);
create policy "adoption_views_select_public" on public.adoption_views for select using (true);

-- ============================================================
-- Piggyback de segurança: adoption_update_own tinha o mesmo buraco de
-- adoption_geo_update_own corrigido na Fase 1 (using sem with check permite
-- reatribuir created_by pra outro dono via update malicioso).
-- ============================================================
drop policy if exists "adoption_update_own" on public.adoption_listings;
create policy "adoption_update_own" on public.adoption_listings
  for update using (created_by = auth.uid() or public.is_admin())
  with check (created_by = auth.uid() or public.is_admin());
