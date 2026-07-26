-- Correção pós-auditoria da migration anterior (2026-07-26_adoption_geo_photos_favorites.sql).
--
-- C1 (crítico): adoption_near() devolvia dist_km em precisão total de double,
-- permitindo recuperar lat/lng exatos por trilateração com só 3 chamadas
-- anônimas — anulava o propósito da migration anterior. Corrigido: a distância
-- agora é calculada sobre uma coordenada "snapada" num grid de ~1km (round a 2
-- casas decimais), não a coordenada exata — nenhuma quantidade de sondas
-- recupera mais que a célula do grid. Some com isso: raio máximo travado em
-- 100km e execução restrita a usuários autenticados (não anon).
--
-- M1 (médio): adoption_geo_update_own não tinha "with check" — dono de um
-- anúncio conseguia sobrescrever a linha de outro anúncio.
-- B1 (baixo): adoption_geo não tinha policy de delete pro dono.

create or replace function public.adoption_near(p_lat double precision, p_lng double precision, p_radius_km integer default 10)
returns table (
  id uuid, created_by uuid, pet_name text, species text, breed text, description text,
  photo_url text, ong_name text, city text, country text, status text, created_at timestamptz,
  age_years numeric, weight_kg numeric, sex text, size text, neutered boolean, vaccinated boolean,
  convive_criancas boolean, convive_gatos boolean, convive_caes boolean,
  nivel_energia text, motivo_adocao text, vermifugado boolean,
  dist_km double precision
)
language sql stable security definer set search_path = pg_catalog, public
as $$
  select l.id, l.created_by, l.pet_name, l.species, l.breed, l.description,
         l.photo_url, l.ong_name, l.city, l.country, l.status, l.created_at,
         l.age_years, l.weight_kg, l.sex, l.size, l.neutered, l.vaccinated,
         l.convive_criancas, l.convive_gatos, l.convive_caes,
         l.nivel_energia, l.motivo_adocao, l.vermifugado,
         round(
           (earth_distance(
             ll_to_earth(p_lat, p_lng),
             ll_to_earth(round(g.lat::numeric, 2)::float8, round(g.lng::numeric, 2)::float8)
           ) / 1000.0)::numeric,
           1
         )::double precision as dist_km
  from public.adoption_listings l
  join public.adoption_geo g on g.listing_id = l.id
  where l.status = 'available'
    and least(greatest(p_radius_km, 1), 100) >= 0
    and earth_box(ll_to_earth(p_lat, p_lng), least(greatest(p_radius_km, 1), 100) * 1000)
          @> ll_to_earth(round(g.lat::numeric, 2)::float8, round(g.lng::numeric, 2)::float8)
    and earth_distance(
          ll_to_earth(p_lat, p_lng),
          ll_to_earth(round(g.lat::numeric, 2)::float8, round(g.lng::numeric, 2)::float8)
        ) <= least(greatest(p_radius_km, 1), 100) * 1000
  order by dist_km asc
  limit 30;
$$;

revoke all on function public.adoption_near(double precision, double precision, integer) from public;
revoke all on function public.adoption_near(double precision, double precision, integer) from anon;
grant execute on function public.adoption_near(double precision, double precision, integer) to authenticated;

-- M1: fecha o buraco de reatribuição de linha em update
drop policy if exists "adoption_geo_update_own" on public.adoption_geo;
create policy "adoption_geo_update_own" on public.adoption_geo
  for update using (
    exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
  ) with check (
    exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
  );

-- B1: dono consegue remover a própria coordenada (direito de exclusão)
create policy "adoption_geo_delete_own" on public.adoption_geo
  for delete using (
    exists (select 1 from public.adoption_listings l where l.id = listing_id and l.created_by = auth.uid())
  );

-- M3: trava o limite de 5 fotos de forma real (constraint, não só trigger
-- baseado em count() que sofre TOCTOU sob inserts paralelos) — o client
-- nunca escolhe um order_index fora de 0..4, então o unique(listing_id,
-- order_index) já existente vira o teto de fato.
alter table public.adoption_photos
  add constraint adoption_photos_order_index_range check (order_index between 0 and 4);
