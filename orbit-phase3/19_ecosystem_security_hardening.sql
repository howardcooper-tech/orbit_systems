-- Orbit ecosystem security and query-plan hardening.
-- Scope: staging-first; no production assumptions or data mutations.

-- New objects must be explicitly exposed to Supabase client roles.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke usage, select on sequences from anon, authenticated;
alter default privileges for role postgres
  revoke execute on functions from public, anon, authenticated;

-- Trigger functions are never valid REST RPC entry points.
revoke execute on function public.apply_student_scan_presence()
  from public, anon, authenticated;
revoke execute on function public.notify_field_trip_student_invitation()
  from public, anon, authenticated;
revoke execute on function public.sync_trip_status_from_handshake()
  from public, anon, authenticated;

-- Enforce tenant-consistent references on bus inspection rows. The original
-- bus foreign key validated only the UUID, not the tenant relationship.
do $$
begin
  if exists (
    select 1
    from public.bus_inspections i
    left join public.buses b
      on b.id = i.bus_id and b.tenant_id = i.tenant_id
    left join public.trips t
      on t.id = i.trip_id and t.tenant_id = i.tenant_id
    left join public.maintenance_work_orders w
      on w.id = i.work_order_id and w.tenant_id = i.tenant_id
    left join public.staff_profiles inspector
      on inspector.id = i.inspector_id and inspector.tenant_id = i.tenant_id
    left join public.staff_profiles submitter
      on submitter.id = i.submitted_by and submitter.tenant_id = i.tenant_id
    left join public.trusted_hardware h
      on h.id = i.source_device_id and h.tenant_id = i.tenant_id
    where b.id is null
       or (i.trip_id is not null and t.id is null)
       or (i.work_order_id is not null and w.id is null)
       or (i.inspector_id is not null and inspector.id is null)
       or (i.submitted_by is not null and submitter.id is null)
       or (i.source_device_id is not null and h.id is null)
  ) then
    raise exception 'Existing bus inspection rows contain cross-tenant references';
  end if;
end;
$$;

create or replace function private.validate_bus_inspection_tenant_links()
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
    raise exception 'BUS_INSPECTION_TENANT_MISMATCH'
      using errcode = '23514';
  end if;

  if new.trip_id is not null and not exists (
    select 1
    from public.trips t
    where t.id = new.trip_id
      and t.tenant_id = new.tenant_id
  ) then
    raise exception 'BUS_INSPECTION_TRIP_TENANT_MISMATCH'
      using errcode = '23514';
  end if;

  if new.work_order_id is not null and not exists (
    select 1
    from public.maintenance_work_orders w
    where w.id = new.work_order_id
      and w.tenant_id = new.tenant_id
  ) then
    raise exception 'BUS_INSPECTION_WORK_ORDER_TENANT_MISMATCH'
      using errcode = '23514';
  end if;

  if new.inspector_id is not null and not exists (
    select 1
    from public.staff_profiles s
    where s.id = new.inspector_id
      and s.tenant_id = new.tenant_id
  ) then
    raise exception 'BUS_INSPECTION_INSPECTOR_TENANT_MISMATCH'
      using errcode = '23514';
  end if;

  if new.submitted_by is not null and not exists (
    select 1
    from public.staff_profiles s
    where s.id = new.submitted_by
      and s.tenant_id = new.tenant_id
  ) then
    raise exception 'BUS_INSPECTION_SUBMITTER_TENANT_MISMATCH'
      using errcode = '23514';
  end if;

  if new.source_device_id is not null and not exists (
    select 1
    from public.trusted_hardware h
    where h.id = new.source_device_id
      and h.tenant_id = new.tenant_id
  ) then
    raise exception 'BUS_INSPECTION_DEVICE_TENANT_MISMATCH'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke execute on function private.validate_bus_inspection_tenant_links()
  from public, anon, authenticated;

drop trigger if exists trig_validate_bus_inspection_tenant_links
  on public.bus_inspections;
create trigger trig_validate_bus_inspection_tenant_links
before insert or update of
  tenant_id,
  bus_id,
  trip_id,
  work_order_id,
  inspector_id,
  submitted_by,
  source_device_id
on public.bus_inspections
for each row
execute function private.validate_bus_inspection_tenant_links();

-- Correct the tautological bus tenant comparison and make all Pilot/Halo
-- inspection paths explicitly tenant-bound.
alter policy bay_inspections_insert on public.bus_inspections
with check (
  private.bay_can_manage_tenant(tenant_id)
  or (
    tenant_id = (select public.jwt_tenant_id())
    and inspector_id = (select auth.uid())
    and submitted_by = (select auth.uid())
    and source_system = 'PILOT_APP'
    and (select public.get_my_role()) = any (array['Pilot', 'Halo'])
    and exists (
      select 1
      from public.buses b
      where b.id = bus_inspections.bus_id
        and b.tenant_id = bus_inspections.tenant_id
        and b.assigned_pilot_id = (select auth.uid())
    )
  )
);

alter policy bay_inspections_read on public.bus_inspections
using (
  private.bay_can_view_tenant(tenant_id)
  or (
    tenant_id = (select public.jwt_tenant_id())
    and inspector_id = (select auth.uid())
    and (select public.get_my_role()) = any (array['Pilot', 'Halo'])
    and exists (
      select 1
      from public.buses b
      where b.id = bus_inspections.bus_id
        and b.tenant_id = bus_inspections.tenant_id
        and b.assigned_pilot_id = (select auth.uid())
    )
  )
);

alter policy bay_inspections_update on public.bus_inspections
using (
  private.bay_can_manage_tenant(tenant_id)
  or (
    tenant_id = (select public.jwt_tenant_id())
    and inspector_id = (select auth.uid())
    and submitted_by = (select auth.uid())
    and source_system = 'PILOT_APP'
    and inspection_status = 'In_Progress'
  )
)
with check (
  private.bay_can_manage_tenant(tenant_id)
  or (
    tenant_id = (select public.jwt_tenant_id())
    and inspector_id = (select auth.uid())
    and submitted_by = (select auth.uid())
    and source_system = 'PILOT_APP'
  )
);

-- Make the Duval tenant wall explicit on every non-deny policy over a public
-- tenant table. This also protects legacy role-only policies.
do $$
declare
  rec record;
  using_expr text;
  check_expr text;
begin
  for rec in
    select
      p.oid,
      p.polname,
      p.polcmd,
      n.nspname as schema_name,
      c.relname as table_name,
      pg_get_expr(p.polqual, p.polrelid) as existing_using,
      pg_get_expr(p.polwithcheck, p.polrelid) as existing_check
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and exists (
        select 1
        from pg_attribute a
        where a.attrelid = c.oid
          and a.attname = 'tenant_id'
          and a.attnum > 0
          and not a.attisdropped
      )
  loop
    using_expr := rec.existing_using;
    check_expr := rec.existing_check;

    if using_expr is not null
       and using_expr <> 'false'
       and position('jwt_tenant_id()' in using_expr) = 0 then
      using_expr := format(
        '((tenant_id = (select public.jwt_tenant_id())) and (%s))',
        using_expr
      );
    end if;

    if check_expr is not null
       and check_expr <> 'false'
       and position('jwt_tenant_id()' in check_expr) = 0 then
      check_expr := format(
        '((tenant_id = (select public.jwt_tenant_id())) and (%s))',
        check_expr
      );
    end if;

    -- PostgreSQL inherits UPDATE WITH CHECK from USING when omitted. Make the
    -- invariant explicit while the policy is being hardened.
    if rec.polcmd in ('w', '*')
       and check_expr is null
       and using_expr is not null then
      check_expr := using_expr;
    end if;

    if rec.polcmd = 'a' then
      if check_expr is not null then
        execute format(
          'alter policy %I on %I.%I with check (%s)',
          rec.polname,
          rec.schema_name,
          rec.table_name,
          check_expr
        );
      end if;
    elsif rec.polcmd in ('r', 'd') then
      if using_expr is not null then
        execute format(
          'alter policy %I on %I.%I using (%s)',
          rec.polname,
          rec.schema_name,
          rec.table_name,
          using_expr
        );
      end if;
    else
      execute format(
        'alter policy %I on %I.%I using (%s) with check (%s)',
        rec.polname,
        rec.schema_name,
        rec.table_name,
        coalesce(using_expr, 'true'),
        coalesce(check_expr, using_expr, 'true')
      );
    end if;
  end loop;
end;
$$;

-- Cache auth.uid() once per statement in the policies identified by the
-- Supabase auth_rls_initplan advisor.
do $$
declare
  rec record;
  using_expr text;
  check_expr text;
begin
  for rec in
    with flagged(table_name, policy_name) as (
      values
        ('parents', 'parent_view_self'),
        ('parents', 'parent_update_self'),
        ('guardian_profiles', 'parent_view_guardian_profile'),
        ('guardian_profiles', 'parent_update_guardian_profile'),
        ('student_sis_enrollment', 'parent_view_sis_enrollment'),
        ('student_device_authorizations', 'parent_view_device_auth'),
        ('custody_waiver_logs', 'parent_view_own_waivers'),
        ('custody_waiver_logs', 'parent_insert_waivers'),
        ('bus_telemetry_logs', 'pilot_insert_telemetry'),
        ('emergency_flares', 'flare_visibility'),
        ('comms_messages', 'msg_visibility'),
        ('outbound_alerts', 'alert_view_personal'),
        ('field_trip_teacher_assignments', 'field_trip_assignment_staff_select'),
        ('transit_student_presence_events', 'transit_student_presence_ops_select'),
        ('satellite_units', 'satellite_units_staff_all'),
        ('transit_trips', 'transit_trips_staff_select'),
        ('transit_satellite_roster', 'transit_roster_staff_select'),
        ('field_trip_student_invitations', 'field_trip_invite_parent_staff_select'),
        ('field_trip_permissions', 'field_trip_permission_parent_staff_select'),
        ('field_trip_chaperone_applications', 'field_trip_chaperone_parent_staff_select'),
        ('trip_adult_presence_events', 'adult_presence_ops_select'),
        ('venue_mesh_search_notifications', 'venue_mesh_search_notifications_recipient_select'),
        ('venue_mesh_point_event_logs', 'venue_mesh_point_event_logs_parent_select'),
        ('venue_mesh_student_emergency_profiles', 'venue_mesh_student_emergency_profiles_authorized_read'),
        ('venue_mesh_emergency_action_packets', 'venue_mesh_emergency_action_packets_authorized_read'),
        ('venue_mesh_drone_dispatches', 'venue_mesh_drone_dispatches_authorized_read'),
        ('venue_mesh_appearance_snapshots', 'venue_mesh_appearance_snapshots_read')
    )
    select
      p.polname,
      p.polcmd,
      n.nspname as schema_name,
      c.relname as table_name,
      pg_get_expr(p.polqual, p.polrelid) as existing_using,
      pg_get_expr(p.polwithcheck, p.polrelid) as existing_check
    from flagged f
    join pg_class c on c.relname = f.table_name
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
    join pg_policy p on p.polrelid = c.oid and p.polname = f.policy_name
  loop
    using_expr := replace(rec.existing_using, 'auth.uid()', '(select auth.uid())');
    check_expr := replace(rec.existing_check, 'auth.uid()', '(select auth.uid())');

    if rec.polcmd = 'a' then
      execute format(
        'alter policy %I on %I.%I with check (%s)',
        rec.polname,
        rec.schema_name,
        rec.table_name,
        check_expr
      );
    elsif rec.polcmd in ('r', 'd') then
      execute format(
        'alter policy %I on %I.%I using (%s)',
        rec.polname,
        rec.schema_name,
        rec.table_name,
        using_expr
      );
    else
      execute format(
        'alter policy %I on %I.%I using (%s) with check (%s)',
        rec.polname,
        rec.schema_name,
        rec.table_name,
        using_expr,
        coalesce(check_expr, using_expr)
      );
    end if;
  end loop;
end;
$$;

-- Consolidate overlapping permissive SELECT policies. Each replacement keeps
-- the original OR semantics while evaluating the tenant wall only once.
drop policy if exists alert_view_district on public.outbound_alerts;
drop policy if exists alert_view_personal on public.outbound_alerts;
create policy alert_view_authorized
  on public.outbound_alerts
  for select
  to authenticated
  using (
    tenant_id = (select public.jwt_tenant_id())
    and (
      (
        (select public.get_my_role()) = any (array['Superintendent', 'Command', 'Central'])
        and alert_type is distinct from 'Safety_Report_Notice'
      )
      or recipient_id = (select auth.uid())
    )
  );

drop policy if exists scan_events_command_select on public.student_scan_events;
drop policy if exists scan_events_pilot_select on public.student_scan_events;
create policy scan_events_authorized_select
  on public.student_scan_events
  for select
  to authenticated
  using (
    tenant_id = (select public.jwt_tenant_id())
    and (
      (
        (select public.get_my_role()) = any (array['Command', 'Central', 'Superintendent'])
        and trip_id in (
          select t.id
          from public.trips t
          where t.district_id = (select public.get_my_district())
            and t.tenant_id = student_scan_events.tenant_id
        )
      )
      or public.pilot_assigned_manifest_scan(student_id, bus_id, trip_id)
    )
  );

drop policy if exists command_view_sis_enrollment on public.student_sis_enrollment;
drop policy if exists parent_view_sis_enrollment on public.student_sis_enrollment;
create policy sis_enrollment_authorized_select
  on public.student_sis_enrollment
  for select
  to authenticated
  using (
    tenant_id = (select public.jwt_tenant_id())
    and (
      (
        (select public.get_my_role()) = any (
          array['Command', 'Central', 'Superintendent', 'Principal']
        )
        and school_id in (
          select s.id
          from public.schools s
          where s.district_id = (select public.get_my_district())
            and s.tenant_id = student_sis_enrollment.tenant_id
        )
      )
      or sis_student_id in (
        select s.sis_student_id
        from public.students s
        join public.student_guardians sg on sg.student_id = s.id
        where sg.parent_id = (select auth.uid())
          and s.tenant_id = student_sis_enrollment.tenant_id
          and sg.tenant_id = student_sis_enrollment.tenant_id
      )
    )
  );

drop policy if exists transit_roster_admin_write on public.transit_satellite_roster;
drop policy if exists transit_roster_staff_select on public.transit_satellite_roster;
create policy transit_roster_authorized_select
  on public.transit_satellite_roster
  for select
  to authenticated
  using (
    tenant_id = (select public.jwt_tenant_id())
    and (
      staff_id = (select auth.uid())
      or (select public.get_my_role()) = any (
        array[
          'Command', 'Central', 'Superintendent', 'Principal',
          'Lead_Satellite', 'Satellite', 'Staff_Teacher', 'Teacher'
        ]
      )
    )
  );
create policy transit_roster_admin_insert
  on public.transit_satellite_roster
  for insert
  to authenticated
  with check (
    tenant_id = (select public.jwt_tenant_id())
    and (select public.get_my_role()) = any (array['Command', 'Central'])
  );
create policy transit_roster_admin_update
  on public.transit_satellite_roster
  for update
  to authenticated
  using (
    tenant_id = (select public.jwt_tenant_id())
    and (select public.get_my_role()) = any (array['Command', 'Central'])
  )
  with check (
    tenant_id = (select public.jwt_tenant_id())
    and (select public.get_my_role()) = any (array['Command', 'Central'])
  );
create policy transit_roster_admin_delete
  on public.transit_satellite_roster
  for delete
  to authenticated
  using (
    tenant_id = (select public.jwt_tenant_id())
    and (select public.get_my_role()) = any (array['Command', 'Central'])
  );

drop policy if exists venue_mesh_point_event_logs_ops_select
  on public.venue_mesh_point_event_logs;
drop policy if exists venue_mesh_point_event_logs_parent_select
  on public.venue_mesh_point_event_logs;
create policy venue_mesh_point_event_logs_authorized_select
  on public.venue_mesh_point_event_logs
  for select
  to authenticated
  using (
    tenant_id = (select public.jwt_tenant_id())
    and (
      coalesce((select public.get_my_role()), '') = any (
        array['Central', 'Command', 'Superintendent']
      )
      or parent_id = (select auth.uid())
    )
  );

drop policy if exists venue_mesh_search_notifications_ops_select
  on public.venue_mesh_search_notifications;
drop policy if exists venue_mesh_search_notifications_recipient_select
  on public.venue_mesh_search_notifications;
create policy venue_mesh_search_notifications_authorized_select
  on public.venue_mesh_search_notifications
  for select
  to authenticated
  using (
    tenant_id = (select public.jwt_tenant_id())
    and (
      coalesce((select public.get_my_role()), '') = any (
        array['Central', 'Command', 'Superintendent']
      )
      or recipient_actor_id = (select auth.uid())
    )
  );

-- Add deterministic leading-column indexes for every currently uncovered
-- foreign key. This protects joins and cascading parent updates/deletes.
do $$
declare
  rec record;
  index_name text;
begin
  for rec in
    with foreign_keys as (
      select
        con.oid,
        con.conname,
        con.conrelid,
        con.conkey,
        n.nspname as schema_name,
        c.relname as table_name,
        (
          select string_agg(format('%I', a.attname), ', ' order by k.ordinality)
          from unnest(con.conkey) with ordinality k(attnum, ordinality)
          join pg_attribute a
            on a.attrelid = con.conrelid
           and a.attnum = k.attnum
        ) as columns_sql
      from pg_constraint con
      join pg_class c on c.oid = con.conrelid
      join pg_namespace n on n.oid = c.relnamespace
      where con.contype = 'f'
        and n.nspname in ('public', 'identity_vault', 'archive')
    )
    select fk.*
    from foreign_keys fk
    where not exists (
      select 1
      from pg_index i
      where i.indrelid = fk.conrelid
        and i.indisvalid
        and i.indisready
        and 0 = (
          select count(*)
          from unnest(fk.conkey) with ordinality k(attnum, ordinality)
          where (i.indkey::smallint[])[k.ordinality - 1] is distinct from k.attnum
        )
    )
  loop
    index_name := left(
      format('idx_fk_%s_%s', rec.table_name, substr(md5(rec.conname), 1, 10)),
      63
    );
    execute format(
      'create index if not exists %I on %I.%I (%s)',
      index_name,
      rec.schema_name,
      rec.table_name,
      rec.columns_sql
    );
  end loop;
end;
$$;
