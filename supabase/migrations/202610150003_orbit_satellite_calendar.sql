
-- Satellite calendar: scoped to assigned field trips and existing Central oversight.
-- Read-only; never exposes funding, donation, awards or payment data.
create or replace function public.orbit_satellite_calendar(p_from date,p_to date)
returns table(event_id uuid,trip_id uuid,school_id uuid,event_kind text,title text,event_date date,
 starts_at timestamptz,ends_at timestamptz,event_status text,permission_deadline timestamptz)
language sql stable security invoker set search_path='' as $$
select e.id,e.trip_id,e.school_id,e.event_type,e.title,e.event_date,e.starts_at,e.ends_at,
 e.status,e.permission_deadline
from public.orbit_calendar_events e
where e.tenant_id=(select public.jwt_tenant_id())
 and e.event_date between p_from and p_to
 and (
  (e.trip_id is not null and exists(select 1 from public.field_trip_teacher_assignments a
   where a.trip_id=e.trip_id and a.teacher_id=(select auth.uid()) and a.tenant_id=e.tenant_id))
  or (e.trip_id is not null and exists(select 1 from public.trips t
   where t.id=e.trip_id and t.tenant_id=e.tenant_id and t.lead_satellite_id=(select auth.uid())))
  or exists(select 1 from public.staff_profiles p where p.id=(select auth.uid())
   and p.tenant_id=e.tenant_id and p.is_active and p.role in ('Central','Principal','Superintendent')
   and (p.school_id is null or p.school_id=e.school_id))
 )
order by e.event_date,e.starts_at nulls last,e.title;
$$;
revoke all on function public.orbit_satellite_calendar(date,date) from public,anon;
grant execute on function public.orbit_satellite_calendar(date,date) to authenticated;

-- Prevent careless full-history reads from either calendar endpoint.
create or replace function private.orbit_calendar_validate_range(p_from date,p_to date)
returns boolean language sql immutable set search_path='' as $$
select p_from is not null and p_to is not null and p_from<=p_to and p_to<=p_from+interval '366 days';
$$;
revoke all on function private.orbit_calendar_validate_range(date,date) from public,anon,authenticated;
