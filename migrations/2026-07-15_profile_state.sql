-- Novo passo "Seus dados" no fluxo de virar parceiro precisa do Estado do
-- tutor (profiles já tinha city/country). Rodar uma vez no SQL Editor.
alter table public.profiles add column if not exists state text;
alter table public.profiles drop constraint if exists profiles_state_len;
alter table public.profiles add constraint profiles_state_len check (state is null or char_length(state) <= 100);
