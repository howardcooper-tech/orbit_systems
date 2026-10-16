
-- Orbit Calendar staging migration: preserve existing Point schedules and Orbit Field permissions.
create table if not exists public.orbit_calendar_events (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.districts(id),
 school_id uuid not null references public.schools(id),
 trip_id uuid unique references public.trips(id) on delete cascade,
 event_type text not null check (event_type in ('field_trip','school_event')),
 title text not null check (length(btrim(title)) between 1 and 160),
 event_date date not null,
 starts_at timestamptz,
 ends_at timestamptz,
 status text not null default 'draft' check (status in ('draft','published','cancelled')),
 permission_deadline timestamptz,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint orbit_calendar_ref_chk check ((trip_id is null and event_type='school_event') or (trip_id is not null and event_type='field_trip')),
 constraint orbit_calendar_time_chk check (starts_at is null or ends_at is null or ends_at>starts_at)
);
create index if not exists orbit_calendar_school_date on public.orbit_calendar_events(tenant_id,school_id,event_date);
alter table public.orbit_calendar_events enable row level security;
alter table public.orbit_calendar_events force row level security;
revoke all on public.orbit_calendar_events from public, anon, authenticated;

create or replace function private.orbit_calendar_validate() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.schools s where s.id=new.school_id and s.tenant_id=new.tenant_id) then
  raise exception 'Invalid school tenant' using errcode='23514'; end if;
 if new.trip_id is not null and not exists (
   select 1 from public.trips t where t.id=new.trip_id and t.school_id=new.school_id
   and t.tenant_id=new.tenant_id and t.trip_date=new.event_date
 ) then raise exception 'Trip/calendar tenant school or date mismatch' using errcode='23514'; end if;
 new.updated_at=now(); return new;
end $$;
revoke all on function private.orbit_calendar_validate() from public,anon,authenticated;
create trigger orbit_calendar_validate_trigger before insert or update on public.orbit_calendar_events
 for each row execute function private.orbit_calendar_validate();

create or replace function private.orbit_field_trip_calendar_sync() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.trip_date is not null and new.trip_type not ilike 'Daily' then
  insert into public.orbit_calendar_events(tenant_id,school_id,trip_id,event_type,title,event_date)
  values (new.tenant_id,new.school_id,new.id,'field_trip',
   left(coalesce(nullif(btrim(new.destination),''),'School Field Trip'),160),new.trip_date)
  on conflict(trip_id) do update set event_date=excluded.event_date,
    title=excluded.title,school_id=excluded.school_id,tenant_id=excluded.tenant_id;
 end if;
 return new;
end $$;
revoke all on function private.orbit_field_trip_calendar_sync() from public,anon,authenticated;
create trigger orbit_field_trip_calendar_sync after insert or update of trip_date,destination,school_id,tenant_id,trip_type
 on public.trips for each row execute function private.orbit_field_trip_calendar_sync();
insert into public.orbit_calendar_events(tenant_id,school_id,trip_id,event_type,title,event_date)
select t.tenant_id,t.school_id,t.id,'field_trip',
 left(coalesce(nullif(btrim(t.destination),''),'School Field Trip'),160),t.trip_date
from public.trips t where t.trip_date is not null and t.trip_type not ilike 'Daily'
on conflict(trip_id) do nothing;

create policy orbit_calendar_events_read on public.orbit_calendar_events for select to authenticated
using (tenant_id=(select public.jwt_tenant_id()) and (
 exists (select 1 from public.staff_profiles p where p.id=(select auth.uid())
  and p.tenant_id=orbit_calendar_events.tenant_id and p.is_active
  and p.role in ('Central','Principal','Superintendent')
  and (p.school_id is null or p.school_id=orbit_calendar_events.school_id))
 or (trip_id is not null and exists (select 1 from public.field_trip_teacher_assignments a
  where a.trip_id=orbit_calendar_events.trip_id and a.teacher_id=(select auth.uid())
  and a.tenant_id=orbit_calendar_events.tenant_id))
 or (trip_id is not null and exists (select 1 from public.trips t
  where t.id=orbit_calendar_events.trip_id and t.lead_satellite_id=(select auth.uid())
  and t.tenant_id=orbit_calendar_events.tenant_id))
 or (status='published' and (
   (event_type='field_trip' and exists(select 1 from public.field_trip_student_invitations i
    where i.trip_id=orbit_calendar_events.trip_id and i.tenant_id=orbit_calendar_events.tenant_id
    and i.invitation_status='INVITED' and
    (public.is_parent_of_student(i.student_id,(select auth.uid()))
      or exists(select 1 from public.student_app_accounts sa
        where sa.student_id=i.student_id and sa.user_id=(select auth.uid())
          and sa.tenant_id=i.tenant_id and sa.status='ACTIVE'))))
   or (event_type='school_event' and exists(select 1 from public.students s
     where s.school_id=orbit_calendar_events.school_id and s.tenant_id=orbit_calendar_events.tenant_id
     and (public.is_parent_of_student(s.id,(select auth.uid()))
       or exists(select 1 from public.student_app_accounts sa where sa.student_id=s.id
           and sa.user_id=(select auth.uid()) and sa.status='ACTIVE' and sa.tenant_id=s.tenant_id))))
 ))
));
create policy orbit_calendar_events_insert on public.orbit_calendar_events for insert to authenticated
with check (trip_id is null and event_type='school_event' and tenant_id=(select public.jwt_tenant_id())
 and exists(select 1 from public.staff_profiles p where p.id=(select auth.uid())
  and p.tenant_id=orbit_calendar_events.tenant_id and p.is_active
  and p.role in ('Central','Principal','Superintendent')
  and (p.school_id is null or p.school_id=orbit_calendar_events.school_id)));
create policy orbit_calendar_events_update on public.orbit_calendar_events for update to authenticated
using (tenant_id=(select public.jwt_tenant_id()) and
 exists(select 1 from public.staff_profiles p where p.id=(select auth.uid())
  and p.tenant_id=orbit_calendar_events.tenant_id and p.is_active
  and p.role in ('Central','Principal','Superintendent')
  and (p.school_id is null or p.school_id=orbit_calendar_events.school_id)))
with check (tenant_id=(select public.jwt_tenant_id()) and
 exists(select 1 from public.staff_profiles p where p.id=(select auth.uid())
  and p.tenant_id=orbit_calendar_events.tenant_id and p.is_active
  and p.role in ('Central','Principal','Superintendent')
  and (p.school_id is null or p.school_id=orbit_calendar_events.school_id)));
grant select,insert,update on public.orbit_calendar_events to authenticated;

-- Invoker rights preserve RLS on the existing Point ride request / recurring schedule tables.
create or replace function public.orbit_my_calendar(p_from date,p_to date)
returns table(event_id uuid,event_kind text,student_id uuid,event_date date,end_date date,
 starts_at timestamptz,ends_at timestamptz,title text,event_status text,source_id uuid)
language sql stable security invoker set search_path='' as $$
with my_students as (
 select g.student_id from public.student_guardians g
  where g.parent_id=(select auth.uid()) and g.tenant_id=(select public.jwt_tenant_id())
 union
 select a.student_id from public.student_app_accounts a
  where a.user_id=(select auth.uid()) and a.tenant_id=(select public.jwt_tenant_id()) and a.status='ACTIVE'
)
select e.id,e.event_type,ms.student_id,e.event_date,e.event_date,e.starts_at,e.ends_at,e.title,e.status,e.trip_id
from public.orbit_calendar_events e
join public.students s on s.school_id=e.school_id and s.tenant_id=e.tenant_id
join my_students ms on ms.student_id=s.id
where e.status='published' and e.event_date between p_from and p_to
and (e.event_type='school_event' or exists (
 select 1 from public.field_trip_student_invitations i where i.trip_id=e.trip_id
 and i.student_id=ms.student_id and i.tenant_id=e.tenant_id and i.invitation_status='INVITED'))
union all
select d.id,'ride_exception',d.student_id,d.service_date,d.service_date,null::timestamptz,
 null::timestamptz,'Transportation: '||replace(d.transportation_mode,'_',' '),d.status,d.id
from public.student_daily_transport_plans d join my_students ms on ms.student_id=d.student_id
where d.tenant_id=(select public.jwt_tenant_id()) and d.service_date between p_from and p_to
union all
select r.id,'ride_schedule',r.student_id,r.start_date,r.end_date,null::timestamptz,
 null::timestamptz,'Recurring transport: '||replace(r.transportation_mode,'_',' '),r.status,r.id
from public.student_transport_schedules r join my_students ms on ms.student_id=r.student_id
where r.tenant_id=(select public.jwt_tenant_id()) and r.end_date>=p_from and r.start_date<=p_to;
$$;
revoke all on function public.orbit_my_calendar(date,date) from public,anon;
grant execute on function public.orbit_my_calendar(date,date) to authenticated;
