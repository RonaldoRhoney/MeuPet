-- BUG encontrado: os triggers que protegem is_partner/is_sponsored só
-- reconheciam admin via is_admin() (checa auth.uid()) — a service role key
-- (usada por automação/backend) não tem auth.uid(), então is_admin() dava
-- false e os triggers zeravam is_partner/is_sponsored mesmo quando quem
-- inseriu tinha autorização de sobra (service role só é usada server-side,
-- nunca exposta ao navegador). Resultado prático: negócios inseridos via
-- service role sempre viravam is_partner=false, silenciosamente.
create or replace function public.protect_partner_columns()
returns trigger language plpgsql security definer as $$
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
returns trigger language plpgsql security definer as $$
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
