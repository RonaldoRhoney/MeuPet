-- MIGRATION MESTRA — junta tudo que ficou pendente das migrations
-- anteriores (2026-07-14_partner_leads_free, 2026-07-14_partner_selfservice_
-- products, 2026-07-14_business_type_and_services). Cole ESTE ARQUIVO
-- INTEIRO no SQL Editor do Supabase e rode uma vez. É seguro rodar de novo
-- se precisar (todo passo usa IF NOT EXISTS / DROP IF EXISTS antes de criar).

-- =========================================================================
-- 1) partner_leads: parceria virou 100% gratuita
-- =========================================================================
alter table public.partner_leads
  drop constraint if exists partner_leads_plan_interest_check;
alter table public.partner_leads
  alter column plan_interest drop not null;
alter table public.partner_leads
  add column if not exists website_url text;
alter table public.partner_leads
  drop constraint if exists partner_leads_website_url_check;
alter table public.partner_leads
  add constraint partner_leads_website_url_check
  check (char_length(website_url) <= 500 and website_url ~* '^https?://');

drop policy if exists "partner_leads_insert_any" on public.partner_leads;
create policy "partner_leads_insert_any" on public.partner_leads for insert with check (
  auth.uid() is not null and created_by = auth.uid()
);

-- =========================================================================
-- 2) petshops: autoatendimento do parceiro (1 negócio por conta) + limites
-- =========================================================================
alter table public.petshops
  drop constraint if exists petshops_owner_id_key;
alter table public.petshops
  add constraint petshops_owner_id_key unique (owner_id);

alter table public.petshops drop constraint if exists petshops_name_len;
alter table public.petshops add constraint petshops_name_len check (char_length(name) <= 200);
alter table public.petshops drop constraint if exists petshops_address_len;
alter table public.petshops add constraint petshops_address_len check (address is null or char_length(address) <= 300);
alter table public.petshops drop constraint if exists petshops_city_len;
alter table public.petshops add constraint petshops_city_len check (char_length(city) <= 120);
alter table public.petshops drop constraint if exists petshops_country_len;
alter table public.petshops add constraint petshops_country_len check (char_length(country) <= 80);
alter table public.petshops drop constraint if exists petshops_lat_range;
alter table public.petshops add constraint petshops_lat_range check (lat between -90 and 90);
alter table public.petshops drop constraint if exists petshops_lng_range;
alter table public.petshops add constraint petshops_lng_range check (lng between -180 and 180);

alter table public.petshops add column if not exists business_type text;
alter table public.petshops drop constraint if exists petshops_business_type_check;
alter table public.petshops add constraint petshops_business_type_check
  check (business_type is null or business_type in ('petshop','veterinaria','produto','servico','outro'));

alter table public.petshops add column if not exists state text;
alter table public.petshops drop constraint if exists petshops_state_len;
alter table public.petshops add constraint petshops_state_len check (state is null or char_length(state) <= 100);

-- =========================================================================
-- 3) products: vínculo com o petshop dono + tipo produto/serviço + limites
-- =========================================================================
alter table public.products
  add column if not exists petshop_id uuid references public.petshops(id) on delete cascade;
create index if not exists idx_products_petshop on public.products(petshop_id);

alter table public.products drop constraint if exists products_name_len;
alter table public.products add constraint products_name_len check (char_length(name) <= 200);
alter table public.products drop constraint if exists products_price_nonneg;
alter table public.products add constraint products_price_nonneg check (price_cents >= 0);
alter table public.products drop constraint if exists products_image_len;
alter table public.products add constraint products_image_len check (image_url is null or char_length(image_url) <= 500);
alter table public.products drop constraint if exists products_shop_name_len;
alter table public.products add constraint products_shop_name_len check (char_length(shop_name) <= 200);
alter table public.products drop constraint if exists products_affiliate_len;
alter table public.products add constraint products_affiliate_len check (char_length(affiliate_url) <= 500);
alter table public.products drop constraint if exists products_category_len;
alter table public.products add constraint products_category_len check (category is null or char_length(category) <= 60);

alter table public.products add column if not exists item_type text not null default 'produto';
alter table public.products drop constraint if exists products_item_type_check;
alter table public.products add constraint products_item_type_check check (item_type in ('produto','servico'));

-- =========================================================================
-- 4) triggers de proteção (parceiro autoatendido não pode se autopromover
--    nem se passar por outra loja)
-- =========================================================================
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

-- =========================================================================
-- 5) RLS: dono do petshop gerencia os próprios produtos
-- =========================================================================
drop policy if exists "products_owner_write" on public.products;
create policy "products_owner_write" on public.products for all using (
  petshop_id is not null and exists (select 1 from public.petshops p where p.id = products.petshop_id and p.owner_id = auth.uid())
) with check (
  petshop_id is not null and exists (select 1 from public.petshops p where p.id = products.petshop_id and p.owner_id = auth.uid())
);

-- =========================================================================
-- 6) feed público da home (Loja) — só produto do admin ou de parceiro já
--    verificado; autoatendido pendente não aparece pra todo mundo ainda
-- =========================================================================
create or replace view public.products_feed as
select p.* from public.products p
left join public.petshops s on s.id = p.petshop_id
where p.petshop_id is null or s.is_partner = true;
alter view public.products_feed set (security_invoker = true);
grant select on public.products_feed to anon, authenticated;

-- =========================================================================
-- 7) espécie livre no cadastro de adoção ("outro" + digitar) — limite de
--    tamanho pra não virar vetor de flood de armazenamento
-- =========================================================================
alter table public.adoption_listings drop constraint if exists adoption_listings_species_len;
alter table public.adoption_listings add constraint adoption_listings_species_len check (char_length(species) <= 40);

-- =========================================================================
-- 8) conferência final — confira manualmente que bate com o esperado
-- =========================================================================
select 'colunas' as check_type, table_name, column_name from information_schema.columns
where table_schema = 'public' and (
  (table_name = 'partner_leads' and column_name = 'website_url')
  or (table_name = 'petshops' and column_name in ('business_type','state'))
  or (table_name = 'products' and column_name in ('petshop_id','item_type'))
)
union all
select 'view', table_name, null from information_schema.views
where table_schema = 'public' and table_name = 'products_feed'
union all
select 'policy', tablename, policyname from pg_policies
where schemaname = 'public' and policyname in ('products_owner_write', 'partner_leads_insert_any')
order by check_type, table_name;
-- esperado: 5 linhas de "colunas", 1 de "view", 2 de "policy" — 8 no total
