-- Campos que faltavam no cadastro de parceiro: endereço completo, telefone/
-- WhatsApp, sobre o negócio, descrição do produto/serviço, e categorias
-- novas (Pet Sitter, Adestrador, Banho e Tosa). Rodar uma vez no SQL Editor.

alter table public.petshops add column if not exists street_address text;
alter table public.petshops drop constraint if exists petshops_street_address_len;
alter table public.petshops add constraint petshops_street_address_len
  check (street_address is null or char_length(street_address) <= 300);

alter table public.petshops add column if not exists phone text;
alter table public.petshops drop constraint if exists petshops_phone_len;
alter table public.petshops add constraint petshops_phone_len
  check (phone is null or char_length(phone) <= 30);

alter table public.petshops add column if not exists about text;
alter table public.petshops drop constraint if exists petshops_about_len;
alter table public.petshops add constraint petshops_about_len
  check (about is null or char_length(about) <= 2000);

alter table public.petshops drop constraint if exists petshops_business_type_check;
alter table public.petshops add constraint petshops_business_type_check
  check (business_type is null or business_type in
    ('petshop','veterinaria','produto','servico','outro','pet_sitter','adestrador','banho_tosa'));

alter table public.products add column if not exists description text;
alter table public.products drop constraint if exists products_description_len;
alter table public.products add constraint products_description_len
  check (description is null or char_length(description) <= 500);
