-- Tipo de negócio no cadastro do parceiro (petshop/clínica/marca/serviço/outro)
-- e distinção produto x serviço na vitrine. Rodar uma vez no SQL Editor do
-- Supabase (produção) para alinhar com meupet_schema.sql.

alter table public.petshops
  add column if not exists business_type text;

-- "in (null, ...)" nunca rejeita nada no Postgres (vira NULL, não FALSE) —
-- troca pelo check correto. drop cobre tanto quem já rodou a v1 buggy da
-- migration quanto quem está rodando pela primeira vez (constraint inexistente).
alter table public.petshops
  drop constraint if exists petshops_business_type_check;
alter table public.petshops
  add constraint petshops_business_type_check
  check (business_type is null or business_type in ('petshop','veterinaria','produto','servico','outro'));

alter table public.products
  add column if not exists item_type text not null default 'produto'
  check (item_type in ('produto','servico'));
