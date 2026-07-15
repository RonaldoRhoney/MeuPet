-- Parceiro autoatendido: cadastra o próprio petshop (grátis) e gerencia os
-- próprios produtos na vitrine, sem esperar aprovação do admin. Rodar uma vez
-- no SQL Editor do Supabase (produção) para alinhar com meupet_schema.sql.

-- 1) petshops: só um negócio autoatendido por conta + limites de tamanho
--    (mesma defesa que partner_leads já tinha; petshops_insert_own/update_own
--    já existiam e permitiam self-insert, isso só reforça os dados).
alter table public.petshops
  add constraint petshops_owner_id_key unique (owner_id);

alter table public.petshops
  add constraint petshops_name_len check (char_length(name) <= 200),
  add constraint petshops_address_len check (address is null or char_length(address) <= 300),
  add constraint petshops_city_len check (char_length(city) <= 120),
  add constraint petshops_country_len check (char_length(country) <= 80),
  add constraint petshops_lat_range check (lat between -90 and 90),
  add constraint petshops_lng_range check (lng between -180 and 180);

-- 2) products: vincula ao petshop dono e reforça limites de tamanho
alter table public.products
  add column if not exists petshop_id uuid references public.petshops(id) on delete cascade;

create index if not exists idx_products_petshop on public.products(petshop_id);

alter table public.products
  add constraint products_name_len check (char_length(name) <= 200),
  add constraint products_price_nonneg check (price_cents >= 0),
  add constraint products_image_len check (image_url is null or char_length(image_url) <= 500),
  add constraint products_shop_name_len check (char_length(shop_name) <= 200),
  add constraint products_affiliate_len check (char_length(affiliate_url) <= 500),
  add constraint products_category_len check (category is null or char_length(category) <= 60);

-- 3) is_sponsored (destaque pago) só pode ser ligado por admin
create or replace function public.protect_product_sponsor_column()
returns trigger language plpgsql security definer as $$
begin
  if public.is_admin() then
    return new;
  end if;
  if TG_OP = 'INSERT' then
    new.is_sponsored := false;
  else
    new.is_sponsored := old.is_sponsored;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_products_protect_sponsor on public.products;
create trigger trg_products_protect_sponsor
  before insert or update on public.products
  for each row execute procedure public.protect_product_sponsor_column();

-- 4) RLS: dono do petshop gerencia os próprios produtos
drop policy if exists "products_owner_write" on public.products;
create policy "products_owner_write" on public.products for all using (
  petshop_id is not null and exists (select 1 from public.petshops p where p.id = products.petshop_id and p.owner_id = auth.uid())
) with check (
  petshop_id is not null and exists (select 1 from public.petshops p where p.id = products.petshop_id and p.owner_id = auth.uid())
);

-- 5) shop_name não pode ser um texto arbitrário do parceiro (evita
--    impersonação de outra loja) — sempre travado no nome real do petshop dono.
create or replace function public.lock_product_shop_name()
returns trigger language plpgsql security definer as $$
begin
  if new.petshop_id is not null then
    select name into new.shop_name from public.petshops where id = new.petshop_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_products_lock_shop_name on public.products;
create trigger trg_products_lock_shop_name
  before insert or update on public.products
  for each row execute procedure public.lock_product_shop_name();

-- 6) feed público da home: só produto curado pelo admin ou de parceiro já
--    verificado — produto autoatendido de negócio ainda não revisado pelo
--    admin não aparece pra todo mundo (mitiga spam/phishing na vitrine).
create or replace view public.products_feed as
select p.* from public.products p
left join public.petshops s on s.id = p.petshop_id
where p.petshop_id is null or s.is_partner = true;

alter view public.products_feed set (security_invoker = true);
grant select on public.products_feed to anon, authenticated;

-- 7) o formulário de lead anônimo saiu de uso (virou autoatendimento logado);
--    fecha o insert anônimo órfão que ficou aberto em partner_leads.
drop policy if exists "partner_leads_insert_any" on public.partner_leads;
create policy "partner_leads_insert_any" on public.partner_leads for insert with check (
  auth.uid() is not null and created_by = auth.uid()
);
