-- Seed de teste: 5 negócios verificados (is_partner=true) pra ver o carrossel
-- de parceiros funcionando na home. Rode uma vez no SQL Editor do Supabase.
-- Pra remover depois, veja o DELETE comentado no final do arquivo.

insert into public.petshops (name, business_type, city, country, lat, lng, is_partner)
values
  ('Petshop Amigo Fiel', 'petshop', 'São Paulo', 'Brasil', -23.5505, -46.6333, true),
  ('Clínica VetCare 24h', 'veterinaria', 'Rio de Janeiro', 'Brasil', -22.9068, -43.1729, true),
  ('Rações Naturais BichoFeliz', 'produto', 'Belo Horizonte', 'Brasil', -19.9167, -43.9345, true),
  ('Banho & Tosa PetSpa', 'servico', 'Curitiba', 'Brasil', -25.4284, -49.2733, true),
  ('ONG Patas Unidas', 'outro', 'Porto Alegre', 'Brasil', -30.0346, -51.2177, true);

-- pra remover os 5 de teste depois (rode só isso, separado):
-- delete from public.petshops where name in (
--   'Petshop Amigo Fiel', 'Clínica VetCare 24h', 'Rações Naturais BichoFeliz',
--   'Banho & Tosa PetSpa', 'ONG Patas Unidas'
-- ) and owner_id is null;
