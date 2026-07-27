-- Correções pós-auditoria da Fase 2 (2026-07-26_adoption_fase2.sql).
--
-- I1 (bug funcional): "Mais favoritados" nunca funcionava — o client tentava
-- ler adoption_favorites de todo mundo, mas a RLS (correta) só deixa cada
-- usuário ver os próprios favoritos. Corrigido com uma função agregadora
-- security definer que devolve só contagens, nunca linhas por usuário.
--
-- M1 (médio): adoption_views tinha select público — dava pra baixar a
-- tabela inteira (custo de egress, e amplificação: qualquer um insere
-- milhões de linhas e todo visitante da seção passa a baixar tudo isso).
-- Corrigido: select fica restrito a admin (mesmo padrão de ad_impressions);
-- toda contagem passa pela função agregadora abaixo.
--
-- M2 (médio): adoption_requests_insert_own não bloqueava usuário banido
-- (todas as outras policies de insert do schema checam is_banned()) e não
-- tinha unicidade — um usuário podia floodar o mesmo anúncio com solicitações
-- repetidas. Corrigido: adiciona not is_banned() + unique(listing_id, requester_id).
--
-- B1 (baixo, LGPD): requerente não conseguia apagar a própria solicitação
-- (privacidade.html promete revogação de consentimento a qualquer momento).

-- ---------- I1 + M1: contagem agregada, sem expor linha crua ----------
drop policy if exists "adoption_views_select_public" on public.adoption_views;
create policy "adoption_views_select_admin" on public.adoption_views
  for select using (public.is_admin());

create or replace function public.adoption_counts(p_listing_ids uuid[])
returns table (listing_id uuid, fav_count integer, view_count integer)
language sql stable security definer set search_path = pg_catalog, public
as $$
  select l.id as listing_id,
         coalesce((select count(*) from public.adoption_favorites f where f.listing_id = l.id), 0)::int as fav_count,
         coalesce((select count(*) from public.adoption_views v where v.listing_id = l.id), 0)::int as view_count
  from public.adoption_listings l
  where l.id = any(p_listing_ids);
$$;
revoke all on function public.adoption_counts(uuid[]) from public;
grant execute on function public.adoption_counts(uuid[]) to anon, authenticated;

-- ---------- M2: bloqueia banido + evita flood repetido no mesmo anúncio ----------
alter table public.adoption_requests
  add constraint adoption_requests_unique_por_usuario unique (listing_id, requester_id);

drop policy if exists "adoption_requests_insert_own" on public.adoption_requests;
create policy "adoption_requests_insert_own" on public.adoption_requests
  for insert with check (auth.uid() = requester_id and accepted_terms = true and not public.is_banned());

-- ---------- B1: requerente pode apagar a própria solicitação ----------
create policy "adoption_requests_delete_own" on public.adoption_requests
  for delete using (requester_id = auth.uid());
