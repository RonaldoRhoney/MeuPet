-- MeuPet virou 100% gratuito: "Anuncie no MeuPet" deixou de ter planos pagos
-- e virou um cadastro de parceria gratuita. Rodar uma vez no SQL Editor do
-- Supabase (produção) para alinhar com meupet_schema.sql.

alter table public.partner_leads
  drop constraint if exists partner_leads_plan_interest_check;

alter table public.partner_leads
  alter column plan_interest drop not null;

alter table public.partner_leads
  add column if not exists website_url text
  check (char_length(website_url) <= 500 and website_url ~* '^https?://');
