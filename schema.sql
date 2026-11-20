-- =====================================================================
-- LBA — Bot do Discord + Contratos + Finanças + Janelas de transferência
-- Rode DEPOIS do schema.sql, no SQL Editor do Supabase. Pode rodar de novo.
-- =====================================================================

-- ---------- tabelas que o site já usa mas que o schema.sql não criava ----------
create table if not exists entries (
  id uuid primary key default gen_random_uuid(),
  championship_id uuid not null references championships(id) on delete cascade,
  driver_id uuid not null references drivers(id) on delete cascade,
  team_id uuid references teams(id) on delete set null,
  number int,
  unique (championship_id, driver_id)
);
create table if not exists team_entries (
  id uuid primary key default gen_random_uuid(),
  championship_id uuid not null references championships(id) on delete cascade,
  team_id uuid not null references teams(id) on delete cascade,
  unique (championship_id, team_id)
);

-- ---------- novas colunas ----------
alter table teams    add column if not exists owner_name text;
alter table teams    add column if not exists owner_photo_url text;
alter table teams    add column if not exists owner_discord_id text;
alter table teams    add column if not exists balance numeric not null default 0;
alter table drivers  add column if not exists discord_id text;
alter table drivers  add column if not exists value numeric not null default 0;
alter table entries  add column if not exists role text not null default 'driver';   -- 'driver' | 'reserve'
alter table profiles add column if not exists discord_id text;
alter table races    add column if not exists finance_settled boolean not null default false;

do $$ begin
  alter table entries drop constraint if exists entries_role_check;
  alter table entries add constraint entries_role_check check (role in ('driver','reserve'));
end $$;

-- ---------- configuração do bot (dashboard) ----------
create table if not exists bot_config (key text primary key, value text);

-- canais e cargos do servidor (o bot preenche; o site só lê, para montar as listas)
create table if not exists discord_channels (id text primary key, name text, position int, category text);
create table if not exists discord_roles    (id text primary key, name text, position int);

-- fila de comandos site -> bot
create table if not exists bot_queue (
  id uuid primary key default gen_random_uuid(),
  action text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','done','error')),
  result text,
  requested_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
create index if not exists bot_queue_pending on bot_queue (status, created_at);

-- mensagens "vivas" do bot (painéis, plantel, monitor financeiro) para editar em vez de repostar
create table if not exists bot_state (key text primary key, value jsonb);

-- janelas de transferência (dias em que contratar/transferir é permitido)
create table if not exists transfer_days (day date primary key, note text);

-- contratos
create table if not exists contracts (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('sign','transfer','release')),
  status text not null default 'pending' check (status in ('pending','signed','declined','expired','cancelled')),
  driver_id uuid references drivers(id) on delete set null,
  team_id uuid references teams(id) on delete set null,
  from_team_id uuid references teams(id) on delete set null,
  championship_id uuid references championships(id) on delete set null,
  role text not null default 'driver' check (role in ('driver','reserve')),
  fee numeric not null default 0,
  bypass_window boolean not null default false,
  proposed_by text,             -- discord id de quem propôs
  driver_discord_id text,
  driver_name text,
  team_name text,
  owner_name text,
  note text,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  signed_at timestamptz
);
create index if not exists contracts_team on contracts (team_id, created_at desc);

-- inscrições feitas pelo Discord (/register)
create table if not exists applications (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('driver','team_principal','strategist')),
  discord_id text not null,
  discord_tag text,
  data jsonb not null default '{}'::jsonb,
  prev_nick text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  review_message_id text,
  decided_by text,
  created_at timestamptz not null default now()
);

-- presença (confirmo / ausento / em dúvida)
create table if not exists attendance (
  race_id uuid not null references races(id) on delete cascade,
  discord_id text not null,
  driver_id uuid references drivers(id) on delete cascade,
  response text not null check (response in ('confirm','absent','doubt')),
  updated_at timestamptz not null default now(),
  primary key (race_id, discord_id)
);

-- extrato financeiro (equipes e valor de mercado dos pilotos)
create table if not exists finance_log (
  id bigserial primary key,
  kind text not null check (kind in ('team','driver')),
  team_id uuid references teams(id) on delete set null,
  driver_id uuid references drivers(id) on delete set null,
  race_id uuid references races(id) on delete set null,
  amount numeric not null,
  balance_after numeric not null,
  reason text,
  created_at timestamptz not null default now()
);
create index if not exists finance_log_created on finance_log (created_at desc);

-- ---------- auditoria também nas tabelas novas ----------
create or replace function public.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare rid text;
begin
  if tg_table_name in ('settings','bot_config') then
    rid := coalesce(new.key, old.key);
  elsif tg_table_name = 'transfer_days' then
    rid := coalesce(new.day, old.day)::text;
  else
    rid := (case when tg_op = 'DELETE' then old.id else new.id end)::text;
  end if;
  insert into audit_log (user_id, action, table_name, row_id, old_data, new_data)
  values (auth.uid(), tg_op, tg_table_name, rid,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

do $$ declare t text; begin
  foreach t in array array['entries','team_entries','bot_config','transfer_days','contracts'] loop
    execute format('drop trigger if exists trg_audit on %I', t);
    execute format('create trigger trg_audit after insert or update or delete on %I for each row execute function public.audit()', t);
  end loop;
end $$;

-- ---------- RLS ----------
alter table entries          enable row level security;
alter table team_entries     enable row level security;
alter table bot_config       enable row level security;
alter table discord_channels enable row level security;
alter table discord_roles    enable row level security;
alter table bot_queue        enable row level security;
alter table bot_state        enable row level security;   -- sem policy: só o bot (service role) acessa
alter table transfer_days    enable row level security;
alter table contracts        enable row level security;
alter table applications     enable row level security;
alter table attendance       enable row level security;
alter table finance_log      enable row level security;

do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies where schemaname = 'public'
           and tablename in ('entries','team_entries','bot_config','discord_channels','discord_roles','bot_queue',
                             'transfer_days','contracts','applications','attendance','finance_log')
  loop execute format('drop policy if exists %I on public.%I', p.policyname, p.tablename); end loop;
end $$;

create policy "public_read_entries"       on entries       for select using (true);
create policy "public_read_team_entries"  on team_entries  for select using (true);
create policy "admin_entries"             on entries       for all using (is_admin()) with check (is_admin());
create policy "admin_team_entries"        on team_entries  for all using (is_admin()) with check (is_admin());

create policy "staff_read_bot_config"     on bot_config    for select using (is_staff());
create policy "admin_bot_config"          on bot_config    for all using (is_admin()) with check (is_admin());
create policy "staff_read_channels"       on discord_channels for select using (is_staff());
create policy "staff_read_roles"          on discord_roles    for select using (is_staff());
create policy "staff_read_queue"          on bot_queue     for select using (is_staff());
create policy "staff_insert_queue"        on bot_queue     for insert with check (is_staff() and requested_by = auth.uid());

create policy "public_read_transfer_days" on transfer_days for select using (true);
create policy "admin_transfer_days"       on transfer_days for all using (is_admin()) with check (is_admin());

create policy "staff_read_contracts"      on contracts     for select using (is_staff());
create policy "admin_contracts"           on contracts     for all using (is_admin()) with check (is_admin());
create policy "staff_read_applications"   on applications  for select using (is_staff());
create policy "staff_read_attendance"     on attendance    for select using (is_staff());
create policy "public_read_finance"       on finance_log   for select using (true);

-- ---------- FINANÇAS ----------
-- Lê um número/lista de bot_config com valor padrão.
create or replace function public.cfg(k text, d text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif((select value from bot_config where key = k), ''), d);
$$;

-- Ajusta o saldo de uma equipe (kind='team') ou o valor de um piloto (kind='driver') e registra no extrato.
-- Só administradores (ou o bot, via service role). Saldo/valor nunca ficam negativos, a menos que p_allow_negative.
create or replace function public.apply_finance(
  p_kind text, p_team uuid, p_driver uuid, p_amount numeric, p_reason text,
  p_race uuid default null, p_allow_negative boolean default false
) returns numeric
language plpgsql security definer set search_path = public as $$
declare nb numeric;
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'Sem permissão.'; end if;
  if p_kind = 'team' then
    update teams set balance = balance + p_amount where id = p_team returning balance into nb;
    if nb is null then raise exception 'Equipe não encontrada.'; end if;
    if nb < 0 and not p_allow_negative then raise exception 'Saldo insuficiente na equipe.'; end if;
    insert into finance_log (kind, team_id, driver_id, race_id, amount, balance_after, reason)
      values ('team', p_team, p_driver, p_race, p_amount, nb, p_reason);
  elsif p_kind = 'driver' then
    update drivers set value = greatest(0, value + p_amount) where id = p_driver returning value into nb;
    if nb is null then raise exception 'Piloto não encontrado.'; end if;
    insert into finance_log (kind, team_id, driver_id, race_id, amount, balance_after, reason)
      values ('driver', p_team, p_driver, p_race, p_amount, nb, p_reason);
  else
    raise exception 'Tipo inválido.';
  end if;
  return nb;
end $$;
revoke all on function public.apply_finance(text, uuid, uuid, numeric, text, uuid, boolean) from public, anon;
grant execute on function public.apply_finance(text, uuid, uuid, numeric, text, uuid, boolean) to authenticated, service_role;

-- Aplica o resultado de uma corrida ao dinheiro: muda o valor dos pilotos e paga prêmio às equipes.
-- Configurável em bot_config: fin_value_scale, fin_value_dnf, fin_prize_scale. Só roda uma vez por corrida.
create or replace function public.settle_race(p_race uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  r record; rc races; vs numeric[]; ps numeric[]; vdnf numeric; delta numeric; prize numeric; n int := 0;
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'Sem permissão.'; end if;
  select * into rc from races where id = p_race for update;
  if not found then raise exception 'Corrida não encontrada.'; end if;
  if rc.finance_settled then return 0; end if;
  vs   := string_to_array(cfg('fin_value_scale', '300000,250000,200000,150000,100000,75000,50000,25000'), ',')::numeric[];
  ps   := string_to_array(cfg('fin_prize_scale', '500000,400000,300000,200000,100000,50000'), ',')::numeric[];
  vdnf := cfg('fin_value_dnf', '-50000')::numeric;
  for r in select * from results where race_id = p_race and session like 'RACE%' loop
    delta := 0; prize := 0;
    if r.status = 'FIN' and r.position is not null then
      delta := coalesce(vs[r.position], 0);
      prize := coalesce(ps[r.position], 0);
    elsif r.status in ('DNF','DSQ') then
      delta := vdnf;
    end if;
    if delta <> 0 then
      perform apply_finance('driver', r.team_id, r.driver_id, delta,
        'Corrida: ' || rc.name || case when r.position is not null then ' (P' || r.position || ')' else ' (' || r.status || ')' end, p_race);
      n := n + 1;
    end if;
    if prize <> 0 and r.team_id is not null then
      perform apply_finance('team', r.team_id, r.driver_id, prize, 'Prêmio: ' || rc.name || ' (P' || r.position || ')', p_race);
      n := n + 1;
    end if;
  end loop;
  update races set finance_settled = true where id = p_race;
  return n;
end $$;
revoke all on function public.settle_race(uuid) from public, anon;
grant execute on function public.settle_race(uuid) to authenticated, service_role;

-- ---------- ASSINATURA DE CONTRATO (tudo numa transação) ----------
-- Valida janela de transferência, limite de pilotos e saldo; cobra a taxa; inscreve o piloto na equipe.
create or replace function public.sign_contract(p_contract uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  c contracts; tz text; today date; n_main int; n_res int; max_main int; max_res int; old_number int; seller uuid;
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'Sem permissão.'; end if;
  select * into c from contracts where id = p_contract for update;
  if not found or c.status <> 'pending' then raise exception 'Este contrato não está mais disponível.'; end if;
  if c.kind = 'release' then raise exception 'Dispensas não precisam de assinatura.'; end if;
  if c.expires_at is not null and c.expires_at < now() then
    update contracts set status = 'expired' where id = p_contract;
    return;  -- o bot confere o status depois
  end if;

  tz := cfg('timezone', 'America/Sao_Paulo');
  today := (now() at time zone tz)::date;
  if cfg('transfer_enforce', '1') <> '0' and not c.bypass_window
     and not exists (select 1 from transfer_days where day = today) then
    raise exception 'A janela de transferências está fechada hoje.';
  end if;

  max_main := cfg('max_main_drivers', '2')::int;
  max_res  := cfg('max_reserve_drivers', '1')::int;
  select count(*) filter (where role = 'driver'), count(*) filter (where role = 'reserve')
    into n_main, n_res from entries
   where championship_id = c.championship_id and team_id = c.team_id and driver_id <> c.driver_id;
  if c.role = 'driver'  and max_main > 0 and n_main >= max_main then raise exception 'A equipe já tem o máximo de pilotos titulares (%).', max_main; end if;
  if c.role = 'reserve' and max_res  > 0 and n_res  >= max_res  then raise exception 'A equipe já tem o máximo de pilotos reserva (%).', max_res; end if;

  -- dinheiro: a equipe compradora paga o valor do piloto; em transferência, a equipe vendedora recebe
  if c.fee > 0 then
    perform apply_finance('team', c.team_id, c.driver_id, -c.fee,
      case when c.kind = 'transfer' then 'Transferência: compra de ' else 'Contratação de ' end || coalesce(c.driver_name, 'piloto'));
    if c.kind = 'transfer' then
      select team_id into seller from entries where championship_id = c.championship_id and driver_id = c.driver_id;
      if seller is not null and seller <> c.team_id then
        perform apply_finance('team', seller, c.driver_id, c.fee, 'Transferência: venda de ' || coalesce(c.driver_name, 'piloto'));
      end if;
    end if;
  end if;

  select number into old_number from entries where championship_id = c.championship_id and driver_id = c.driver_id;
  insert into entries (championship_id, driver_id, team_id, number, role)
    values (c.championship_id, c.driver_id, c.team_id, old_number, c.role)
  on conflict (championship_id, driver_id) do update set team_id = excluded.team_id, role = excluded.role;
  insert into team_entries (championship_id, team_id) values (c.championship_id, c.team_id)
    on conflict (championship_id, team_id) do nothing;
  update drivers set team_id = c.team_id where id = c.driver_id;
  update contracts set status = 'signed', signed_at = now() where id = p_contract;
end $$;
revoke all on function public.sign_contract(uuid) from public, anon;
grant execute on function public.sign_contract(uuid) to authenticated, service_role;

-- ---------- AO VIVO (Realtime) ----------
do $$ begin
  begin alter publication supabase_realtime add table finance_log; exception when others then null; end;
  begin alter publication supabase_realtime add table teams;       exception when others then null; end;
  begin alter publication supabase_realtime add table drivers;     exception when others then null; end;
end $$;

-- ---------- valores padrão do bot (só insere o que ainda não existe) ----------
insert into bot_config (key, value) values
  ('roles_notify', '1542916445971947570,1542916789489639545'),
  ('pilot_age_min', '18'), ('pilot_age_max', '20'),
  ('currency_symbol', '$'), ('timezone', 'America/Sao_Paulo'),
  ('transfer_enforce', '1'), ('contract_lang', 'en'),
  ('max_main_drivers', '2'), ('max_reserve_drivers', '1'),
  ('fin_default_value', '1000000'),
  ('fin_value_scale', '300000,250000,200000,150000,100000,75000,50000,25000'),
  ('fin_value_dnf', '-50000'),
  ('fin_prize_scale', '500000,400000,300000,200000,100000,50000'),
  ('nick_format', '{nome} | {nacionalidade} |')
on conflict (key) do nothing;

-- se você já tinha rodado a versão anterior deste arquivo, ajusta os dois padrões antigos
update bot_config set value = '$'  where key = 'currency_symbol' and value = 'R$';
update bot_config set value = 'en' where key = 'contract_lang'   and value = 'pt';
