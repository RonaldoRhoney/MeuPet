-- Parceiros autoatendidos (seção Parceiros) não devem aparecer misturados
-- no Mapa de petshops nem na Loja/Produtos — só no carrossel de Parceiros
-- e na página de detalhes dele. Rodar uma vez no SQL Editor.

-- Mapa (petshops_near) passa a ignorar quem tem owner_id (autocadastro)
create or replace function public.petshops_near(p_lat double precision, p_lng double precision, p_radius_km integer default 10)
returns setof public.petshops
language sql stable as $$
  select * from public.petshops
  where owner_id is null
    and earth_box(ll_to_earth(p_lat, p_lng), p_radius_km * 1000) @> ll_to_earth(lat, lng)
    and earth_distance(ll_to_earth(p_lat, p_lng), ll_to_earth(lat, lng)) <= p_radius_km * 1000
  order by earth_distance(ll_to_earth(p_lat, p_lng), ll_to_earth(lat, lng)) asc;
$$;

-- Loja (products_feed) passa a mostrar só produto curado pelo admin
create or replace view public.products_feed as
select p.* from public.products p
where p.petshop_id is null;

alter view public.products_feed set (security_invoker = true);
grant select on public.products_feed to anon, authenticated;
