-- Fase 1: Pets para Adoção Próximos de Você (geolocalização real) +
-- correção de segurança pré-existente (lat/lng de adoption_listings
-- estava público via anon key, mesmo padrão de vazamento já corrigido
-- antes em profiles.lat/lng — ver comentário em meupet_schema.sql).
--
-- Extensões cube/earthdistance já existem (meupet_schema.sql), não recriar.

-- ============================================================
-- 1) Fix de segurança: mover lat/lng pra tabela owner-only
-- ============================================================
create table public.adoption_geo (
  listing_id uuid primary key references public.adoption_listings(id) on delete cascade,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180)
);
alter table public.adoption_geo enable row level security;

create policy "adoption_geo_select_own" on public.adoption_geo
  for select using (
    exists (select 1 from public.adoption_listings l where l.id = listing_id and (l.created_by = auth.uid() or public.is_admin()))
  );
create policy "adoption_geo_insert_own" on public.adoption_geo
  for insert with check (
    exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
  );
create policy "adoption_geo_update_own" on public.adoption_geo
  for update using (
    exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
  );

create index idx_adoption_geo_gist on public.adoption_geo using gist (ll_to_earth(lat, lng));

-- migra dados existentes antes de dropar as colunas
insert into public.adoption_geo (listing_id, lat, lng)
select id, lat, lng from public.adoption_listings
where lat is not null and lng is not null
on conflict (listing_id) do nothing;

alter table public.adoption_listings drop column lat;
alter table public.adoption_listings drop column lng;

-- ============================================================
-- 2) Novos campos estruturados
-- ============================================================
alter table public.adoption_listings
  add column convive_criancas boolean,
  add column convive_gatos boolean,
  add column convive_caes boolean,
  add column nivel_energia text check (nivel_energia in ('baixo','medio','alto')),
  add column motivo_adocao text check (motivo_adocao is null or char_length(motivo_adocao) <= 500),
  add column vermifugado boolean;

-- ============================================================
-- 3) Galeria de fotos (até 5 por anúncio, travado no banco)
-- ============================================================
create table public.adoption_photos (
  id uuid primary key default uuid_generate_v4(),
  listing_id uuid not null references public.adoption_listings(id) on delete cascade,
  url text not null,
  order_index int not null default 0,
  created_at timestamptz not null default now(),
  unique (listing_id, order_index)
);
alter table public.adoption_photos enable row level security;

create policy "adoption_photos_select_public" on public.adoption_photos for select using (true);
create policy "adoption_photos_insert_own" on public.adoption_photos for insert with check (
  exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
);
create policy "adoption_photos_update_own" on public.adoption_photos for update using (
  exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
);
create policy "adoption_photos_delete_own" on public.adoption_photos for delete using (
  exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
);

create or replace function public.check_adoption_photos_limit()
returns trigger language plpgsql as $$
begin
  if (select count(*) from public.adoption_photos where listing_id = new.listing_id) >= 5 then
    raise exception 'Máximo de 5 fotos por anúncio.';
  end if;
  return new;
end;
$$;
create trigger trg_adoption_photos_limit
  before insert on public.adoption_photos
  for each row execute function public.check_adoption_photos_limit();

-- ============================================================
-- 4) Favoritos persistidos
-- ============================================================
create table public.adoption_favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  listing_id uuid not null references public.adoption_listings(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);
alter table public.adoption_favorites enable row level security;

create policy "adoption_favorites_select_own" on public.adoption_favorites for select using (auth.uid() = user_id);
create policy "adoption_favorites_insert_own" on public.adoption_favorites for insert with check (auth.uid() = user_id);
create policy "adoption_favorites_delete_own" on public.adoption_favorites for delete using (auth.uid() = user_id);

-- ============================================================
-- 5) Busca por raio — molde de petshops_near(), mas security definer
--    (precisa ler adoption_geo de qualquer listing pra calcular distância,
--    mas o retorno NUNCA inclui lat/lng brutos, só dist_km computado)
-- ============================================================
create index idx_adoption_status_species on public.adoption_listings(status, species);

create or replace function public.adoption_near(p_lat double precision, p_lng double precision, p_radius_km integer default 10)
returns table (
  id uuid, created_by uuid, pet_name text, species text, breed text, description text,
  photo_url text, ong_name text, city text, country text, status text, created_at timestamptz,
  age_years numeric, weight_kg numeric, sex text, size text, neutered boolean, vaccinated boolean,
  convive_criancas boolean, convive_gatos boolean, convive_caes boolean,
  nivel_energia text, motivo_adocao text, vermifugado boolean,
  dist_km double precision
)
language sql stable security definer set search_path = public
as $$
  select l.id, l.created_by, l.pet_name, l.species, l.breed, l.description,
         l.photo_url, l.ong_name, l.city, l.country, l.status, l.created_at,
         l.age_years, l.weight_kg, l.sex, l.size, l.neutered, l.vaccinated,
         l.convive_criancas, l.convive_gatos, l.convive_caes,
         l.nivel_energia, l.motivo_adocao, l.vermifugado,
         earth_distance(ll_to_earth(p_lat, p_lng), ll_to_earth(g.lat, g.lng)) / 1000.0 as dist_km
  from public.adoption_listings l
  join public.adoption_geo g on g.listing_id = l.id
  where l.status = 'available'
    and earth_box(ll_to_earth(p_lat, p_lng), p_radius_km * 1000) @> ll_to_earth(g.lat, g.lng)
    and earth_distance(ll_to_earth(p_lat, p_lng), ll_to_earth(g.lat, g.lng)) <= p_radius_km * 1000
  order by dist_km asc
  limit 30;
$$;

revoke all on function public.adoption_near(double precision, double precision, integer) from public;
grant execute on function public.adoption_near(double precision, double precision, integer) to anon, authenticated;
