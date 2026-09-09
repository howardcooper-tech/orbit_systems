-- Orbit telemetry ingress integrity and abuse-resistance hardening.

do $$
begin
  if exists (
    select 1
    from public.bus_telemetry_logs l
    left join public.buses b
      on b.id = l.bus_id and b.tenant_id = l.tenant_id
    where l.tenant_id is null or b.id is null
  ) then
    raise exception 'Existing telemetry rows contain a missing or mismatched tenant';
  end if;
end;
$$;

alter table public.bus_telemetry_logs
  alter column tenant_id set not null;

create index if not exists bus_telemetry_logs_ingress_rate_idx
  on public.bus_telemetry_logs(bus_id, synced_at desc);

create or replace function private.validate_bus_telemetry_tenant_link()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.buses b
    where b.id = new.bus_id
      and b.tenant_id = new.tenant_id
  ) then
    raise exception 'BUS_TELEMETRY_TENANT_MISMATCH'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke execute on function private.validate_bus_telemetry_tenant_link()
  from public, anon, authenticated;

drop trigger if exists trig_validate_bus_telemetry_tenant_link
  on public.bus_telemetry_logs;
create trigger trig_validate_bus_telemetry_tenant_link
before insert or update of tenant_id, bus_id
on public.bus_telemetry_logs
for each row
execute function private.validate_bus_telemetry_tenant_link();

alter policy command_view_district_telemetry
  on public.bus_telemetry_logs
  using (
    tenant_id = (select public.jwt_tenant_id())
    and (select public.get_my_role()) = any (
      array['Command', 'Central', 'Superintendent']
    )
    and exists (
      select 1
      from public.buses b
      where b.id = bus_telemetry_logs.bus_id
        and b.tenant_id = bus_telemetry_logs.tenant_id
        and b.district_id = (select public.get_my_district())
    )
  );

alter policy pilot_insert_telemetry
  on public.bus_telemetry_logs
  with check (
    tenant_id = (select public.jwt_tenant_id())
    and (select public.get_my_role()) = any (array['Pilot', 'Halo'])
    and exists (
      select 1
      from public.buses b
      where b.id = bus_telemetry_logs.bus_id
        and b.tenant_id = bus_telemetry_logs.tenant_id
        and b.assigned_pilot_id = (select auth.uid())
    )
  );
