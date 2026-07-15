-- IMPORTANTE: a migration 2026-07-14_business_type_and_services.sql parece
-- não ter sido aplicada em produção (erro real visto no app: "Could not find
-- the 'business_type' column of 'petshops' in the schema cache"). Este
-- arquivo já inclui tudo de novo, de forma segura pra rodar mesmo que a
-- v1 tenha rodado parcialmente. Cole TUDO abaixo no SQL Editor do Supabase
-- (supabase.com/dashboard → seu projeto → SQL Editor → New query → Run).

alter table public.petshops
  add column if not exists business_type text;

alter table public.petshops
  drop constraint if exists petshops_business_type_check;
alter table public.petshops
  add constraint petshops_business_type_check
  check (business_type is null or business_type in ('petshop','veterinaria','produto','servico','outro'));

alter table public.petshops
  add column if not exists state text;
alter table public.petshops
  drop constraint if exists petshops_state_len;
alter table public.petshops
  add constraint petshops_state_len check (state is null or char_length(state) <= 100);

alter table public.products
  add column if not exists item_type text not null default 'produto';
alter table public.products
  drop constraint if exists products_item_type_check;
alter table public.products
  add constraint products_item_type_check check (item_type in ('produto','servico'));

-- confirma que as colunas existem (deve retornar 4 linhas: business_type,
-- state em petshops; item_type em products — mais uma pra petshops.state)
select table_name, column_name from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'petshops' and column_name in ('business_type','state'))
    or (table_name = 'products' and column_name = 'item_type')
  );
