-- Passo 3 do cadastro de parceiro virou checklist de serviços/produtos
-- sugeridos (sem pedir link nessa etapa) — link passa a ser opcional,
-- o parceiro completa depois em "Meus produtos" se quiser.
alter table public.products alter column affiliate_url drop not null;

alter table public.products drop constraint if exists products_affiliate_len;
alter table public.products add constraint products_affiliate_len
  check (affiliate_url is null or char_length(affiliate_url) <= 2000);
