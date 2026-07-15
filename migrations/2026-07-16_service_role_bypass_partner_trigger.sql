-- BUG (2 partes, achado em produção):
--
-- 1) is_admin() depende de auth.uid(), que não existe em conexões via
--    service role — os triggers protect_partner_columns e
--    protect_product_sponsor_column só aceitavam is_admin(), então
--    qualquer insert feito com a service role key tinha is_partner/
--    is_sponsored zerados sem aviso.
--
-- 2) a primeira tentativa de corrigir isso (adicionar
--    "current_user = 'service_role'") não funcionou porque as duas funções
--    eram SECURITY DEFINER — dentro de uma função assim, current_user vira
--    o DONO da função (ex: postgres), não quem está chamando de verdade.
--    A correção certa (usada aqui) é tirar o SECURITY DEFINER dessas duas
--    funções — is_admin(), chamada de dentro delas, continua SECURITY
--    DEFINER por conta própria, então ela funciona normalmente do mesmo jeito.
--
-- Reaplica mesmo que a v1 (com o bug do security definer) já tenha rodado.

create or replace function public.protect_partner_columns()
returns trigger language plpgsql as $$
begin
  if public.is_admin() or current_user = 'service_role' then
    return new;
  end if;
  if TG_OP = 'INSERT' then
    new.is_partner := false;
    new.partner_plan := null;
  else
    new.is_partner := old.is_partner;
    new.partner_plan := old.partner_plan;
  end if;
  return new;
end;
$$;

create or replace function public.protect_product_sponsor_column()
returns trigger language plpgsql as $$
begin
  if public.is_admin() or current_user = 'service_role' then
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
