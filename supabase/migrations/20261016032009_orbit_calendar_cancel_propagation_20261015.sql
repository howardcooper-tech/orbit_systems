-- Trip remains canonical: explicit cancellation must propagate to the calendar.
create or replace function private.orbit_field_trip_calendar_sync() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.trip_date is not null and new.trip_type not ilike 'Daily' then
  insert into public.orbit_calendar_events
   (tenant_id,school_id,trip_id,event_type,title,event_date,status)
  values (new.tenant_id,new.school_id,new.id,'field_trip',
   left(coalesce(nullif(btrim(new.destination),''),'School Field Trip'),160),new.trip_date,
   case when new.status='canceled' then 'cancelled' else 'draft' end)
  on conflict(trip_id) do update set
   event_date=excluded.event_date,title=excluded.title,school_id=excluded.school_id,
   tenant_id=excluded.tenant_id,
   status=case when new.status='canceled' then 'cancelled'
     else public.orbit_calendar_events.status end;
 end if;
 return new;
end $$;
drop trigger if exists orbit_field_trip_calendar_sync on public.trips;
create trigger orbit_field_trip_calendar_sync after insert or update of trip_date,destination,school_id,tenant_id,trip_type,status
 on public.trips for each row execute function private.orbit_field_trip_calendar_sync();
update public.orbit_calendar_events e set status='cancelled'
 from public.trips t where t.id=e.trip_id and t.status='canceled' and e.status<>'cancelled';