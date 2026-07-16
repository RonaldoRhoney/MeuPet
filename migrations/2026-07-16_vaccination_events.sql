-- Campanhas de vacinação gratuita (ONGs, prefeituras) exibidas na
-- subseção "Onde vacinar agora" de Cuidados. Leitura pública (feature
-- anônima, sem necessidade de login), escrita só por admin via is_admin()
-- (já existe em meupet_schema.sql).
create extension if not exists "uuid-ossp";

create table if not exists public.vaccination_events (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  organizer text not null,
  type text not null check (type in ('gratuito','prefeitura','ong')),
  address text not null,
  city text not null,
  country text not null,
  lat double precision not null,
  lng double precision not null,
  date_start date not null,
  date_end date,
  time_start time,
  time_end time,
  species text[] default '{cao,gato}',
  vaccines_offered text[],
  phone text,
  instagram text,
  is_active boolean default true,
  created_at timestamptz default now()
);

create index if not exists idx_vaccination_events_city on public.vaccination_events(city);
create index if not exists idx_vaccination_events_active_dates on public.vaccination_events(is_active, date_end);

alter table public.vaccination_events enable row level security;

create policy "vaccination_events_select_public" on public.vaccination_events
  for select using (true);
create policy "vaccination_events_admin_write" on public.vaccination_events
  for all using (public.is_admin()) with check (public.is_admin());

-- realtime: front assina INSERT filtrado por city para a subseção "Onde
-- vacinar agora" aparecer sem recarregar quando um admin cadastra campanha
alter publication supabase_realtime add table public.vaccination_events;
