-- Bellview Gardens Levy Tracker - single Supabase setup/update script.
-- Run this in Supabase SQL Editor. It is safe to run on a fresh database
-- or after older Bellview Gardens tables already exist.

create extension if not exists pgcrypto;

create table if not exists admins (
  id uuid primary key default gen_random_uuid(),
  username text unique not null,
  auth_user_id uuid unique references auth.users(id),
  created_at timestamptz default now()
);

create table if not exists units (
  id uuid primary key default gen_random_uuid(),
  unit_number text unique not null,
  resident_name text,
  resident_phone text,
  resident_email text,
  landlord_name text,
  landlord_phone text,
  landlord_email text,
  username text unique not null,
  login_password text,
  auth_user_id uuid unique references auth.users(id),
  is_active boolean not null default true,
  created_at timestamptz default now()
);

alter table units
  add column if not exists resident_phone text,
  add column if not exists resident_email text,
  add column if not exists landlord_name text,
  add column if not exists landlord_phone text,
  add column if not exists landlord_email text,
  add column if not exists login_password text;

create table if not exists levy_rates (
  id uuid primary key default gen_random_uuid(),
  amount numeric(10,2) not null,
  effective_from date not null,
  set_by uuid references admins(id),
  created_at timestamptz default now()
);

create table if not exists levy_charges (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references units(id) on delete cascade,
  charge_month date not null,
  amount_owed numeric(10,2) not null,
  status text not null default 'unpaid' check (status in ('unpaid','paid')),
  paid_date date,
  receipt_number text unique,
  payment_method text,
  payment_reference text,
  recorded_by uuid references admins(id),
  notes text,
  created_at timestamptz default now(),
  unique (unit_id, charge_month)
);

alter table levy_charges
  add column if not exists payment_method text,
  add column if not exists payment_reference text;

create or replace function is_admin()
returns boolean language sql security definer stable as $$
  select exists (select 1 from admins where auth_user_id = auth.uid());
$$;

alter table admins enable row level security;
alter table units enable row level security;
alter table levy_rates enable row level security;
alter table levy_charges enable row level security;

drop policy if exists "Admins view admin list" on admins;
create policy "Admins view admin list" on admins
  for select using (is_admin());

drop policy if exists "Admins view all units" on units;
create policy "Admins view all units" on units
  for select using (is_admin());

drop policy if exists "Residents view own unit" on units;
create policy "Residents view own unit" on units
  for select using (auth_user_id = auth.uid());

drop policy if exists "Admins insert units" on units;
create policy "Admins insert units" on units
  for insert with check (is_admin());

drop policy if exists "Admins update units" on units;
create policy "Admins update units" on units
  for update using (is_admin()) with check (is_admin());

drop policy if exists "Admins delete units" on units;
create policy "Admins delete units" on units
  for delete using (is_admin());

drop policy if exists "Authenticated users view rates" on levy_rates;
create policy "Authenticated users view rates" on levy_rates
  for select using (auth.uid() is not null);

drop policy if exists "Admins set rates" on levy_rates;
create policy "Admins set rates" on levy_rates
  for insert with check (is_admin());

drop policy if exists "Admins view all charges" on levy_charges;
create policy "Admins view all charges" on levy_charges
  for select using (is_admin());

drop policy if exists "Residents view own charges" on levy_charges;
create policy "Residents view own charges" on levy_charges
  for select using (unit_id in (select id from units where auth_user_id = auth.uid()));

create or replace function generate_monthly_charges(target_month date)
returns void language plpgsql security definer as $$
declare
  current_rate numeric(10,2);
begin
  if not is_admin() then
    raise exception 'Only admins can generate charges';
  end if;

  select amount into current_rate
  from levy_rates
  where effective_from <= target_month
  order by effective_from desc limit 1;

  if current_rate is null then
    raise exception 'No levy rate set for %', target_month;
  end if;

  insert into levy_charges (unit_id, charge_month, amount_owed, status)
  select id, target_month, current_rate, 'unpaid'
  from units where is_active = true
  on conflict (unit_id, charge_month) do nothing;
end;
$$;

create or replace function add_unit_arrears_history(
  p_unit_id uuid,
  p_from_month date,
  p_to_month date,
  p_amount numeric,
  p_notes text default null
)
returns integer language plpgsql security definer as $$
declare
  v_inserted integer;
begin
  if not is_admin() then
    raise exception 'Only admins can add arrears history';
  end if;

  if p_from_month is null or p_to_month is null then
    raise exception 'Select from and to months';
  end if;

  if date_trunc('month', p_from_month)::date > date_trunc('month', p_to_month)::date then
    raise exception 'From month must be before or equal to to month';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;

  insert into levy_charges (unit_id, charge_month, amount_owed, status, notes)
  select
    p_unit_id,
    month_value::date,
    p_amount,
    'unpaid',
    nullif(trim(coalesce(p_notes, '')), '')
  from generate_series(
    date_trunc('month', p_from_month)::date,
    date_trunc('month', p_to_month)::date,
    interval '1 month'
  ) as months(month_value)
  where exists (select 1 from units where id = p_unit_id)
  on conflict (unit_id, charge_month) do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

create or replace function update_unit(
  p_unit_id uuid,
  p_unit_number text,
  p_resident_name text default null,
  p_resident_phone text default null,
  p_resident_email text default null,
  p_landlord_name text default null,
  p_landlord_phone text default null,
  p_landlord_email text default null,
  p_username text default null,
  p_login_password text default null,
  p_is_active boolean default true
)
returns units language plpgsql security definer set search_path = public as $$
declare
  v_unit units;
begin
  if not is_admin() then
    raise exception 'Only admins can update units';
  end if;

  if p_unit_id is null then
    raise exception 'Unit id is required';
  end if;

  if nullif(trim(coalesce(p_unit_number, '')), '') is null then
    raise exception 'Unit number is required';
  end if;

  if nullif(trim(coalesce(p_username, '')), '') is null then
    raise exception 'Username is required';
  end if;

  update units
  set unit_number = trim(p_unit_number),
      resident_name = nullif(trim(coalesce(p_resident_name, '')), ''),
      resident_phone = nullif(trim(coalesce(p_resident_phone, '')), ''),
      resident_email = nullif(trim(coalesce(p_resident_email, '')), ''),
      landlord_name = nullif(trim(coalesce(p_landlord_name, '')), ''),
      landlord_phone = nullif(trim(coalesce(p_landlord_phone, '')), ''),
      landlord_email = nullif(trim(coalesce(p_landlord_email, '')), ''),
      username = trim(p_username),
      login_password = nullif(trim(coalesce(p_login_password, '')), ''),
      is_active = coalesce(p_is_active, true)
  where id = p_unit_id
  returning * into v_unit;

  if v_unit.id is null then
    raise exception 'Unit not found';
  end if;

  return v_unit;
end;
$$;

create or replace function record_payment(
  p_charge_id uuid,
  p_paid_date date,
  p_payment_method text default null,
  p_payment_reference text default null,
  p_notes text default null
)
returns text language plpgsql security definer as $$
declare
  v_unit_number text;
  v_charge_month date;
  v_receipt text;
begin
  if not is_admin() then
    raise exception 'Only admins can record payments';
  end if;

  select u.unit_number, lc.charge_month into v_unit_number, v_charge_month
  from levy_charges lc join units u on u.id = lc.unit_id
  where lc.id = p_charge_id;

  if v_unit_number is null then
    raise exception 'Charge not found';
  end if;

  v_receipt := 'RCT-' || to_char(v_charge_month, 'YYYYMM') || '-' || v_unit_number;

  update levy_charges
  set status = 'paid',
      paid_date = p_paid_date,
      receipt_number = v_receipt,
      payment_method = nullif(trim(coalesce(p_payment_method, '')), ''),
      payment_reference = nullif(trim(coalesce(p_payment_reference, '')), ''),
      notes = nullif(trim(coalesce(p_notes, '')), ''),
      recorded_by = (select id from admins where auth_user_id = auth.uid())
  where id = p_charge_id;

  return v_receipt;
end;
$$;

create or replace function delete_unit(p_unit_id uuid)
returns void language plpgsql security definer as $$
begin
  if not is_admin() then
    raise exception 'Only admins can delete units';
  end if;

  delete from levy_charges where unit_id = p_unit_id;
  delete from units where id = p_unit_id;
end;
$$;
