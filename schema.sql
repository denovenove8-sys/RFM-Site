-- =====================================================================
-- RFM — Real Formula Motorsports  (v3)
-- Cole no SQL Editor do Supabase e execute. Pode rodar de novo sem problemas.
--
-- ANTES DE USAR O SITE (1 minuto):
--   Authentication → Providers → Email → DESLIGUE "Confirm email".
--   (O site usa só nome de usuário + senha; internamente cada usuário
--    vira um e-mail fictício "nome@rfm-liga.com", que nunca recebe nada.)
--
-- CONTA PRINCIPAL:
--   Quem se cadastrar com o nome de usuário  Haraguchi9020  vira
--   Administrador automaticamente. Cadastre essa conta LOGO depois de
--   rodar este script (antes que outra pessoa use o nome).
--   Somente essa conta pode dar/tirar o cargo de administrador e ela
--   nunca perde o acesso.
-- =====================================================================

create extension if not exists pgcrypto;

do $$ begin
  create type app_role as enum ('admin','staff','team_principal','driver','visitor');
exception when duplicate_object then null; end $$;

-- ---------- TABELAS ----------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique,
  avatar_url text,
  role app_role not null default 'visitor',
  status text not null default 'pending' check (status in ('pending','active','suspended')),
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_username_lower on profiles (lower(username));

create table if not exists seasons (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  year int not null,
  is_active boolean not null default false
);

-- "championships" = CATEGORIAS do site (cada uma com seu campeonato)
create table if not exists championships (
  id uuid primary key default gen_random_uuid(),
  season_id uuid references seasons(id) on delete cascade,
  name text not null,
  category text
);
alter table championships add column if not exists description text;
alter table championships add column if not exists image_url text;
alter table championships add column if not exists color text;
alter table championships add column if not exists points_scale text not null default '25,18,15,12,10,8,6,4,2,1';
alter table championships add column if not exists fl_bonus int not null default 1;

create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  short_name text,
  color text default '#b5322c',
  logo_url text,
  principal_id uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table teams add column if not exists championship_id uuid references championships(id) on delete set null;

create table if not exists drivers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references profiles(id) on delete set null,
  name text not null,
  nationality text,
  country_code text,
  number int,
  team_id uuid references teams(id) on delete set null,
  photo_url text,
  titles int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table drivers add column if not exists championship_id uuid references championships(id) on delete set null;

create table if not exists races (
  id uuid primary key default gen_random_uuid(),
  championship_id uuid references championships(id) on delete cascade,
  round int,
  name text not null,
  country text,
  country_code text,
  circuit text,
  race_date timestamptz not null,
  status text not null default 'upcoming' check (status in ('upcoming','live','finished')),
  image_url text
);
alter table races add column if not exists qualifying_date timestamptz;
alter table races add column if not exists laps int;
alter table races add column if not exists description text;
alter table races add column if not exists kind text not null default 'race';
alter table races add column if not exists format text;
alter table races add column if not exists sessions jsonb;
alter table races add column if not exists start_date timestamptz;

create table if not exists results (
  id uuid primary key default gen_random_uuid(),
  race_id uuid not null references races(id) on delete cascade,
  driver_id uuid not null references drivers(id) on delete cascade,
  team_id uuid references teams(id) on delete set null,
  grid int,
  position int,
  status text not null default 'FIN' check (status in ('FIN','DNF','DSQ','DNS')),
  penalty_seconds int not null default 0,
  penalty_points int not null default 0,
  fastest_lap boolean not null default false,
  pole boolean not null default false,
  points numeric not null default 0,
  unique (race_id, driver_id)
);

create table if not exists news (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text,
  image_url text,
  published boolean not null default true,
  author_id uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table news add column if not exists kind text not null default 'anuncio';
alter table news add column if not exists pinned boolean not null default false;

-- Personalização do site (nome, logo, cores, fonte, imagens, textos, CSS...)
create table if not exists settings (
  key text primary key,
  value text
);

create table if not exists audit_log (
  id bigserial primary key,
  user_id uuid,
  action text,
  table_name text,
  row_id text,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

-- ---------- FUNÇÕES DE PERMISSÃO (verificadas no servidor) ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin' and status = 'active');
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('admin','staff') and status = 'active');
$$;

-- Conta principal (dona do site)
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and lower(username) = 'haraguchi9020'
                 and role = 'admin' and status = 'active');
$$;

-- ---------- NOVO USUÁRIO -> PERFIL ----------
-- Conta "Haraguchi9020" nasce Administradora ativa. As demais nascem
-- Visitantes pendentes, até um administrador aprovar.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  un text := coalesce(nullif(new.raw_user_meta_data->>'username',''), split_part(new.email,'@',1));
  is_main boolean := lower(coalesce(nullif(new.raw_user_meta_data->>'username',''), split_part(new.email,'@',1))) = 'haraguchi9020';
begin
  insert into profiles (id, username, role, status)
  values (new.id, un,
          case when is_main then 'admin'::app_role else 'visitor'::app_role end,
          case when is_main then 'active' else 'pending' end)
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Regras de segurança dos perfis
create or replace function public.guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    if lower(old.username) = 'haraguchi9020' then
      if new.role <> 'admin' or new.status <> 'active' then
        raise exception 'A conta principal não pode perder o acesso.';
      end if;
      if lower(new.username) <> 'haraguchi9020' then
        raise exception 'O nome da conta principal não pode ser alterado.';
      end if;
    end if;
    if (new.role <> old.role or new.status <> old.status) and not is_admin() then
      raise exception 'Sem permissão para alterar cargo ou estado.';
    end if;
    if new.role <> old.role and (new.role = 'admin' or old.role = 'admin') and not is_owner() then
      raise exception 'Somente a conta principal pode dar ou tirar o cargo de administrador.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_profile on profiles;
create trigger trg_guard_profile before update on profiles
  for each row execute function public.guard_profile();

-- Administrador redefine a senha de um usuário (sem e-mail).
-- Só a conta principal pode redefinir a senha de outro administrador.
create or replace function public.admin_set_password(target uuid, new_password text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
declare trole app_role;
begin
  if not is_admin() then raise exception 'Sem permissão.'; end if;
  if length(coalesce(new_password, '')) < 8 then raise exception 'A senha precisa ter ao menos 8 caracteres.'; end if;
  select role into trole from profiles where id = target;
  if trole is null then raise exception 'Usuário não encontrado.'; end if;
  if trole = 'admin' and not is_owner() and target <> auth.uid() then
    raise exception 'Somente a conta principal pode redefinir a senha de um administrador.';
  end if;
  update auth.users set encrypted_password = crypt(new_password, gen_salt('bf')), updated_at = now() where id = target;
end $$;
revoke all on function public.admin_set_password(uuid, text) from public, anon;
grant execute on function public.admin_set_password(uuid, text) to authenticated;

-- ---------- PONTOS AUTOMÁTICOS (sistema PERSONALIZÁVEL por categoria) ----------
create or replace function public.calc_points() returns trigger
language plpgsql as $$
declare
  base numeric := 0;
  sc text;
  bonus int := 1;
  scale int[];
  n int;
begin
  if new.team_id is null then
    select team_id into new.team_id from drivers where id = new.driver_id;
  end if;
  select c.points_scale, coalesce(c.fl_bonus, 1) into sc, bonus
    from races r join championships c on c.id = r.championship_id where r.id = new.race_id;
  scale := string_to_array(coalesce(nullif(sc, ''), '25,18,15,12,10,8,6,4,2,1'), ',')::int[];
  n := coalesce(array_length(scale, 1), 0);
  if new.session = 'RACE SPRINT' then
    scale := array[8,7,6,5,4,3,2,1]; n := 8; bonus := 0;
  end if;
  if new.session like 'RACE%' and new.status = 'FIN' and new.position between 1 and n then
    base := scale[new.position];
    if new.fastest_lap then base := base + bonus; end if;
  end if;
  new.points := greatest(0, base - coalesce(new.penalty_points, 0));
  return new;
end $$;

drop trigger if exists trg_calc_points on results;
create trigger trg_calc_points before insert or update on results
  for each row execute function public.calc_points();

create or replace function public.recalc_championship() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.points_scale is distinct from old.points_scale or new.fl_bonus is distinct from old.fl_bonus then
    update results set penalty_points = penalty_points
     where race_id in (select id from races where championship_id = new.id);
  end if;
  return new;
end $$;

drop trigger if exists trg_recalc_championship on championships;
create trigger trg_recalc_championship after update on championships
  for each row execute function public.recalc_championship();

-- ---------- HISTÓRICO DE ALTERAÇÕES ----------
create or replace function public.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare rid text;
begin
  if tg_table_name = 'settings' then
    rid := coalesce(new.key, old.key);
  else
    rid := (case when tg_op = 'DELETE' then old.id else new.id end)::text;
  end if;
  insert into audit_log (user_id, action, table_name, row_id, old_data, new_data)
  values (
    auth.uid(), tg_op, tg_table_name, rid,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

do $$ declare t text; begin
  foreach t in array array['profiles','teams','drivers','seasons','championships','races','results','news','settings'] loop
    execute format('drop trigger if exists trg_audit on %I', t);
    execute format('create trigger trg_audit after insert or update or delete on %I for each row execute function public.audit()', t);
  end loop;
end $$;

-- ---------- ROW LEVEL SECURITY ----------
alter table profiles      enable row level security;
alter table teams         enable row level security;
alter table drivers       enable row level security;
alter table seasons       enable row level security;
alter table championships enable row level security;
alter table races         enable row level security;
alter table results       enable row level security;
alter table news          enable row level security;
alter table settings      enable row level security;
alter table audit_log     enable row level security;

do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies where schemaname = 'public'
           and tablename in ('profiles','teams','drivers','seasons','championships','races','results','news','settings','audit_log')
  loop execute format('drop policy if exists %I on public.%I', p.policyname, p.tablename); end loop;
end $$;

-- Leitura pública
create policy "public_read_teams"    on teams         for select using (true);
create policy "public_read_drivers"  on drivers       for select using (true);
create policy "public_read_seasons"  on seasons       for select using (true);
create policy "public_read_champs"   on championships for select using (true);
create policy "public_read_races"    on races         for select using (true);
create policy "public_read_results"  on results       for select using (true);
create policy "public_read_settings" on settings      for select using (true);
create policy "public_read_news"     on news          for select using (published or is_staff());

-- Perfis: cada um vê o seu; staff/admin veem todos
create policy "profiles_select"     on profiles for select using (id = auth.uid() or is_staff());
create policy "profiles_update_own" on profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy "profiles_admin_all"  on profiles for all using (is_admin()) with check (is_admin());

-- Administradores: escrita total
create policy "admin_teams"    on teams         for all using (is_admin()) with check (is_admin());
create policy "admin_drivers"  on drivers       for all using (is_admin()) with check (is_admin());
create policy "admin_seasons"  on seasons       for all using (is_admin()) with check (is_admin());
create policy "admin_champs"   on championships for all using (is_admin()) with check (is_admin());
create policy "admin_races"    on races         for all using (is_admin()) with check (is_admin());
create policy "admin_results"  on results       for all using (is_admin()) with check (is_admin());
create policy "admin_news"     on news          for all using (is_admin()) with check (is_admin());
create policy "admin_settings" on settings      for all using (is_admin()) with check (is_admin());

-- Staff: calendário, resultados e anúncios
create policy "staff_races"   on races   for all using (is_staff()) with check (is_staff());
create policy "staff_results" on results for all using (is_staff()) with check (is_staff());
create policy "staff_news"    on news    for all using (is_staff()) with check (is_staff());

-- Chefe de equipe: só edita a sua equipe (nome, cor, logo)
create policy "principal_team" on teams for update
  using (principal_id = auth.uid()) with check (principal_id = auth.uid());

-- Histórico: só administradores leem
create policy "audit_admin_read" on audit_log for select using (is_admin());

-- ---------- STORAGE ----------
insert into storage.buckets (id, name, public) values ('avatars','avatars', true) on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('media','media', true) on conflict (id) do nothing;

drop policy if exists "avatar_read"   on storage.objects;
drop policy if exists "avatar_insert" on storage.objects;
drop policy if exists "avatar_update" on storage.objects;
drop policy if exists "media_read"    on storage.objects;
drop policy if exists "media_insert"  on storage.objects;
drop policy if exists "media_update"  on storage.objects;
drop policy if exists "media_delete"  on storage.objects;

create policy "avatar_read"   on storage.objects for select using (bucket_id = 'avatars');
create policy "avatar_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatar_update" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "media_read"   on storage.objects for select using (bucket_id = 'media');
create policy "media_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and public.is_staff());
create policy "media_update" on storage.objects for update to authenticated
  using (bucket_id = 'media' and public.is_staff());
create policy "media_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and public.is_staff());

-- =====================================================================
-- Se você usou a versão anterior (login com e-mail), essas contas antigas
-- não entram mais pelo nome de usuário: apague-as em Authentication → Users
-- e cadastre de novo pelo site.
-- =====================================================================

-- Resultados por sessão (FP1, QUALI, RACE...)
alter table results add column if not exists session text not null default 'RACE';
alter table results drop constraint if exists results_race_id_driver_id_key;
alter table results drop constraint if exists results_race_session_driver_key;
alter table results add constraint results_race_session_driver_key unique (race_id, session, driver_id);

-- Melhor tempo de volta (treinos livres e qualificações), ex.: 1:32.456
alter table results add column if not exists lap_time text;

-- =====================================================================
-- v4 — PILOTOS E EQUIPES ÚNICOS + INSCRIÇÕES POR TEMPORADA
-- Piloto e equipe existem uma vez só na liga. Cada temporada/categoria
-- tem suas "inscrições" (piloto + equipe + número). A virada de
-- temporada só cria novas inscrições — nada é copiado.
-- =====================================================================
create table if not exists entries (
  id uuid primary key default gen_random_uuid(),
  championship_id uuid not null references championships(id) on delete cascade,
  driver_id uuid not null references drivers(id) on delete cascade,
  team_id uuid references teams(id) on delete set null,
  number int,
  created_at timestamptz not null default now(),
  unique (championship_id, driver_id)
);
create table if not exists team_entries (
  id uuid primary key default gen_random_uuid(),
  championship_id uuid not null references championships(id) on delete cascade,
  team_id uuid not null references teams(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (championship_id, team_id)
);

-- Pontos: a equipe do resultado vem da inscrição da categoria
create or replace function public.calc_points() returns trigger
language plpgsql as $$
declare
  base numeric := 0; sc text; bonus int := 1; scale int[]; n int; cid uuid;
begin
  select r.championship_id into cid from races r where r.id = new.race_id;
  if new.team_id is null then
    select e.team_id into new.team_id from entries e where e.championship_id = cid and e.driver_id = new.driver_id;
    if new.team_id is null then select team_id into new.team_id from drivers where id = new.driver_id; end if;
  end if;
  select c.points_scale, coalesce(c.fl_bonus, 1) into sc, bonus from championships c where c.id = cid;
  scale := string_to_array(coalesce(nullif(sc, ''), '25,18,15,12,10,8,6,4,2,1'), ',')::int[];
  n := coalesce(array_length(scale, 1), 0);
  if new.session = 'RACE SPRINT' then scale := array[8,7,6,5,4,3,2,1]; n := 8; bonus := 0; end if;
  if new.session like 'RACE%' and new.status = 'FIN' and new.position between 1 and n then
    base := scale[new.position];
    if new.fastest_lap then base := base + bonus; end if;
  end if;
  new.points := greatest(0, base - coalesce(new.penalty_points, 0));
  return new;
end $$;

-- ---------- MIGRAÇÃO (roda uma única vez, só se entries estiver vazia) ----------
-- Junta pilotos e equipes duplicados (mesmo nome em categorias/temporadas
-- diferentes) em um só e cria as inscrições a partir dos dados antigos.
do $$
declare r record;
begin
  if exists (select 1 from entries) then return; end if;

  -- 1) inscrições de pilotos a partir das linhas antigas
  insert into entries (championship_id, driver_id, team_id, number)
  select distinct on (championship_id, id) championship_id, id, team_id, number
    from drivers where championship_id is not null
  on conflict do nothing;
  -- pilotos que só aparecem nos resultados
  insert into entries (championship_id, driver_id, team_id)
  select distinct on (ra.championship_id, re.driver_id) ra.championship_id, re.driver_id, re.team_id
    from results re join races ra on ra.id = re.race_id
   where ra.championship_id is not null
  on conflict do nothing;

  -- 2) inscrições de equipes
  insert into team_entries (championship_id, team_id)
  select championship_id, id from teams where championship_id is not null on conflict do nothing;
  insert into team_entries (championship_id, team_id)
  select distinct championship_id, team_id from entries where team_id is not null on conflict do nothing;

  -- 3) junta equipes duplicadas (mesmo nome)
  for r in select (array_agg(id order by created_at, id::text))[1] as keep, array_agg(id order by created_at, id::text) as ids
             from teams group by lower(trim(name)) having count(*) > 1 loop
    update entries set team_id = r.keep where team_id = any(r.ids);
    update results set team_id = r.keep where team_id = any(r.ids);
    update drivers set team_id = r.keep where team_id = any(r.ids);
    insert into team_entries (championship_id, team_id)
      select championship_id, r.keep from team_entries where team_id = any(r.ids) on conflict do nothing;
    delete from teams where id = any(r.ids) and id <> r.keep;
  end loop;

  -- 4) junta pilotos duplicados (mesmo nome)
  for r in select (array_agg(id order by (profile_id is null), created_at, id::text))[1] as keep, array_agg(id) as ids,
                  (array_agg(profile_id) filter (where profile_id is not null))[1] as prof,
                  max(titles) as titles, bool_or(active) as active
             from drivers group by lower(trim(name)) having count(*) > 1 loop
    update drivers set profile_id = null where id = any(r.ids) and id <> r.keep;
    update results set driver_id = r.keep where driver_id = any(r.ids) and driver_id <> r.keep;
    insert into entries (championship_id, driver_id, team_id, number)
      select championship_id, r.keep, team_id, number from entries where driver_id = any(r.ids) and driver_id <> r.keep
    on conflict do nothing;
    delete from drivers where id = any(r.ids) and id <> r.keep;
    update drivers set profile_id = coalesce(profile_id, r.prof), titles = r.titles, active = r.active where id = r.keep;
  end loop;
end $$;

-- ---------- Segurança das tabelas novas ----------
alter table entries      enable row level security;
alter table team_entries enable row level security;
drop policy if exists "public_read_entries"      on entries;
drop policy if exists "admin_entries"            on entries;
drop policy if exists "public_read_team_entries" on team_entries;
drop policy if exists "admin_team_entries"       on team_entries;
create policy "public_read_entries"      on entries      for select using (true);
create policy "admin_entries"            on entries      for all using (is_admin()) with check (is_admin());
create policy "public_read_team_entries" on team_entries for select using (true);
create policy "admin_team_entries"       on team_entries for all using (is_admin()) with check (is_admin());

do $$ declare t text; begin
  foreach t in array array['entries','team_entries'] loop
    execute format('drop trigger if exists trg_audit on %I', t);
    execute format('create trigger trg_audit after insert or update or delete on %I for each row execute function public.audit()', t);
  end loop;
end $$;
