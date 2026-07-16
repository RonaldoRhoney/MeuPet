-- Marca negócios fictícios/seed de teste (não apaga nada) — achado da
-- auditoria de geolocalização: esse dado se passa por petshop real no
-- Mapa/carrossel porque owner_id null é o mesmo padrão de um petshop
-- curado de verdade pelo admin. Dá pra filtrar depois usando is_test.
alter table public.petshops add column if not exists is_test boolean not null default false;

-- marca todo owner_id-null existente como teste — hoje não há nenhum
-- petshop "curado pelo admin de verdade" na base, só os seeds fictícios
-- criados nas rodadas de teste do carrossel/mapa.
update public.petshops set is_test = true where owner_id is null;
