
-- Opportunity Fund: financial controls, blind requests, intent-only donation and auditable participation.
-- Checkout intentionally HARD DISABLED pending processor credentials, district rules, compliance review.
create table if not exists public.orbit_trip_funding_rules (
 trip_id uuid primary key references public.trips(id) on delete cascade,
 tenant_id uuid not null references public.districts(id),
 currency text not null default 'USD' check(currency='USD'),
 cost_cents integer not null check(cost_cents between 0 and 10000000),
 contribution_deadline timestamptz not null,
 assistance_deadline timestamptz not null,
 capacity integer check(capacity between 1 and 100000),
 donations_enabled boolean not null default false,
 assistance_enabled boolean not null default false,
 policy_approved boolean not null default false,
 checkout_enabled boolean not null default false check (checkout_enabled=false),
 updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default now(),
 check(assistance_deadline<=contribution_deadline)
);
comment on column public.orbit_trip_funding_rules.checkout_enabled is 'Cannot be set true until a future reviewed payment-processor integration migration';
create table if not exists public.orbit_trip_assistance_requests (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.districts(id),
 trip_id uuid not null references public.trips(id) on delete cascade,
 student_id uuid not null references public.students(id),
 requested_by uuid not null references auth.users(id),
 status text not null default 'requested' check(status in ('requested','reviewed','approved','declined','withdrawn')),
 created_at timestamptz not null default now(),
 unique(trip_id,student_id)
);
create table if not exists public.orbit_trip_donation_intents (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.districts(id),
 trip_id uuid not null references public.trips(id) on delete cascade,
 donor_user_id uuid not null references auth.users(id),
 amount_cents integer not null check(amount_cents between 100 and 1000000),
 status text not null default 'intent' check(status='intent'),
 created_at timestamptz not null default now()
);
comment on table public.orbit_trip_donation_intents is 'Pledge intents ONLY. No charge, settled payment or charitable tax receipt.';
create table if not exists public.orbit_trip_payment_ledger (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.districts(id),
 trip_id uuid not null references public.trips(id),
 student_id uuid references public.students(id),
 donation_intent_id uuid references public.orbit_trip_donation_intents(id),
 kind text not null check(kind in ('student_payment','donation','refund')),
 amount_cents integer not null check(amount_cents>0),
 currency text not null default 'USD' check(currency='USD'),
 provider text not null,
 provider_event_id text not null,
 provider_verified_at timestamptz not null,
 created_at timestamptz not null default now(),
 unique(provider,provider_event_id),
 check((kind='student_payment' and student_id is not null and donation_intent_id is null) or
       (kind='donation' and student_id is null and donation_intent_id is not null) or kind='refund')
);
comment on table public.orbit_trip_payment_ledger is 'Append-only server-side payment evidence. No direct user access.';
create table if not exists public.orbit_trip_assistance_awards (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.districts(id),
 trip_id uuid not null references public.trips(id),
 assistance_request_id uuid not null unique references public.orbit_trip_assistance_requests(id),
 amount_cents integer not null check(amount_cents>0),
 status text not null default 'proposed' check(status in ('proposed','approved','voided')),
 approved_by uuid references auth.users(id),
 approved_at timestamptz,
 created_at timestamptz not null default now(),
 check(status<>'approved' or (approved_by is not null and approved_at is not null))
);
create table if not exists public.orbit_trip_participation (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.districts(id),
 trip_id uuid not null references public.trips(id) on delete cascade,
 student_id uuid not null references public.students(id),
 status text not null default 'pending' check(status in ('pending','confirmed','waitlisted','not_selected','cancelled')),
 selection_method text not null default 'administrative' check(selection_method in ('administrative','capacity_lottery','guardian_cancelled')),
 decided_by uuid references auth.users(id),
 decided_at timestamptz,
 updated_at timestamptz not null default now(),
 unique(trip_id,student_id)
);
comment on table public.orbit_trip_participation is 'Never expose financial-assistance or donor status through participation.';
create table if not exists public.orbit_calendar_provider_connections (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.districts(id),
 user_id uuid not null references auth.users(id) on delete cascade,
 provider text not null check(provider in ('google','microsoft','apple_feed')),
 external_calendar_ref text,
 state text not null default 'not_connected' check(state in ('not_connected','connected','revoked')),
 created_at timestamptz not null default now(),
 unique(user_id,provider)
);
comment on table public.orbit_calendar_provider_connections is 'Metadata only. OAuth credentials MUST be kept in a secure vault in future implementation.';
create index if not exists orbit_assistance_trip_idx on public.orbit_trip_assistance_requests(tenant_id,trip_id);
create index if not exists orbit_donation_trip_idx on public.orbit_trip_donation_intents(tenant_id,trip_id);
create index if not exists orbit_participation_trip_idx on public.orbit_trip_participation(tenant_id,trip_id);

do $$ declare t text; begin
 foreach t in array array['orbit_trip_funding_rules','orbit_trip_assistance_requests','orbit_trip_donation_intents',
 'orbit_trip_payment_ledger','orbit_trip_assistance_awards','orbit_trip_participation','orbit_calendar_provider_connections'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('alter table public.%I force row level security',t);
  execute format('revoke all on table public.%I from public,anon,authenticated',t);
 end loop;
end $$;

create or replace function private.orbit_funding_validate() returns trigger language plpgsql
security definer set search_path='' as $$
begin
 if not exists(select 1 from public.trips t where t.id=new.trip_id and t.tenant_id=new.tenant_id) then
  raise exception 'Invalid trip tenant association' using errcode='23514'; end if;
 if tg_table_name in ('orbit_trip_assistance_requests','orbit_trip_participation','orbit_trip_payment_ledger') then
  if new.student_id is not null and not exists(select 1 from public.field_trip_student_invitations i
    where i.trip_id=new.trip_id and i.tenant_id=new.tenant_id and i.student_id=new.student_id
    and i.invitation_status='INVITED') then
   raise exception 'Student must be invited to trip' using errcode='23514'; end if;
 end if;
 if tg_table_name='orbit_trip_assistance_awards' then
  if not exists(select 1 from public.orbit_trip_assistance_requests r where
    r.id=new.assistance_request_id and r.trip_id=new.trip_id and r.tenant_id=new.tenant_id) then
   raise exception 'Assistance award mismatch' using errcode='23514'; end if;
 end if;
 if tg_table_name='orbit_trip_payment_ledger' and new.donation_intent_id is not null then
  if not exists(select 1 from public.orbit_trip_donation_intents d where
    d.id=new.donation_intent_id and d.trip_id=new.trip_id and d.tenant_id=new.tenant_id) then
   raise exception 'Payment donation reference mismatch' using errcode='23514'; end if;
 end if;
 return new;
end $$;
revoke all on function private.orbit_funding_validate() from public,anon,authenticated;
do $$ declare t text; begin
 foreach t in array array['orbit_trip_funding_rules','orbit_trip_assistance_requests','orbit_trip_donation_intents',
 'orbit_trip_payment_ledger','orbit_trip_assistance_awards','orbit_trip_participation'] loop
  execute format('create trigger orbit_funding_validate_trigger before insert or update on public.%I for each row execute function private.orbit_funding_validate()',t);
 end loop;
end $$;

-- Read cost/deadline rules only for authorized school administrators and invited parents/Pin accounts.
create policy orbit_funding_rules_read on public.orbit_trip_funding_rules for select to authenticated
using(tenant_id=(select public.jwt_tenant_id()) and (
 exists(select 1 from public.staff_profiles p join public.trips t on t.id=orbit_trip_funding_rules.trip_id
  where p.id=(select auth.uid()) and p.tenant_id=orbit_trip_funding_rules.tenant_id and p.is_active
    and p.role in ('Central','Principal','Superintendent') and (p.school_id is null or p.school_id=t.school_id))
 or exists(select 1 from public.field_trip_student_invitations i where i.trip_id=orbit_trip_funding_rules.trip_id
   and i.tenant_id=orbit_trip_funding_rules.tenant_id and i.invitation_status='INVITED'
   and (public.is_parent_of_student(i.student_id,(select auth.uid()))
   or exists(select 1 from public.student_app_accounts sa
    where sa.student_id=i.student_id and sa.user_id=(select auth.uid()) and sa.status='ACTIVE'
      and sa.tenant_id=i.tenant_id)))
));
create policy orbit_funding_rules_add on public.orbit_trip_funding_rules for insert to authenticated
with check(tenant_id=(select public.jwt_tenant_id()) and
 exists(select 1 from public.staff_profiles p join public.trips t on t.id=orbit_trip_funding_rules.trip_id
  where p.id=(select auth.uid()) and p.tenant_id=orbit_trip_funding_rules.tenant_id and p.is_active
    and p.role in ('Central','Principal','Superintendent') and (p.school_id is null or p.school_id=t.school_id)));
create policy orbit_funding_rules_update on public.orbit_trip_funding_rules for update to authenticated
using(tenant_id=(select public.jwt_tenant_id()) and exists(select 1 from public.staff_profiles p
 join public.trips t on t.id=orbit_trip_funding_rules.trip_id where p.id=(select auth.uid())
  and p.tenant_id=orbit_trip_funding_rules.tenant_id and p.is_active and p.role in ('Central','Principal','Superintendent')
  and (p.school_id is null or p.school_id=t.school_id)))
with check(tenant_id=(select public.jwt_tenant_id()) and exists(select 1 from public.staff_profiles p
 join public.trips t on t.id=orbit_trip_funding_rules.trip_id where p.id=(select auth.uid())
  and p.tenant_id=orbit_trip_funding_rules.tenant_id and p.is_active and p.role in ('Central','Principal','Superintendent')
  and (p.school_id is null or p.school_id=t.school_id)));
grant select,insert,update on public.orbit_trip_funding_rules to authenticated;

-- Explicit confidential assistance requests: requester-only SELECT; no donor or teacher access.
create policy orbit_assistance_own_read on public.orbit_trip_assistance_requests for select to authenticated
using(tenant_id=(select public.jwt_tenant_id()) and requested_by=(select auth.uid())
 and public.is_parent_of_student(student_id,(select auth.uid())));
create policy orbit_assistance_parent_insert on public.orbit_trip_assistance_requests for insert to authenticated
with check(tenant_id=(select public.jwt_tenant_id()) and requested_by=(select auth.uid())
 and public.is_parent_of_student(student_id,(select auth.uid()))
 and exists(select 1 from public.orbit_trip_funding_rules f where f.trip_id=orbit_trip_assistance_requests.trip_id
   and f.tenant_id=orbit_trip_assistance_requests.tenant_id and f.assistance_enabled
   and f.assistance_deadline>=now()));
grant select,insert on public.orbit_trip_assistance_requests to authenticated;

-- Donation intents carry no payment credentials and are not settled transactions.
create policy orbit_donation_own_read on public.orbit_trip_donation_intents for select to authenticated
using(tenant_id=(select public.jwt_tenant_id()) and donor_user_id=(select auth.uid()));
create policy orbit_donation_own_insert on public.orbit_trip_donation_intents for insert to authenticated
with check(tenant_id=(select public.jwt_tenant_id()) and donor_user_id=(select auth.uid())
 and exists(select 1 from public.orbit_trip_funding_rules f where f.trip_id=orbit_trip_donation_intents.trip_id
  and f.tenant_id=orbit_trip_donation_intents.tenant_id and f.donations_enabled and f.contribution_deadline>=now())
 and exists(select 1 from public.field_trip_student_invitations i where i.trip_id=orbit_trip_donation_intents.trip_id
  and i.tenant_id=orbit_trip_donation_intents.tenant_id and i.invitation_status='INVITED'
  and public.is_parent_of_student(i.student_id,(select auth.uid()))));
grant select,insert on public.orbit_trip_donation_intents to authenticated;

-- Participation outcome has no indication of which students received assistance.
create policy orbit_participation_read on public.orbit_trip_participation for select to authenticated
using(tenant_id=(select public.jwt_tenant_id()) and (
 public.is_parent_of_student(student_id,(select auth.uid()))
 or exists(select 1 from public.student_app_accounts sa where sa.student_id=orbit_trip_participation.student_id
  and sa.user_id=(select auth.uid()) and sa.tenant_id=orbit_trip_participation.tenant_id and sa.status='ACTIVE')
 or exists(select 1 from public.field_trip_teacher_assignments a where a.trip_id=orbit_trip_participation.trip_id
  and a.teacher_id=(select auth.uid()) and a.tenant_id=orbit_trip_participation.tenant_id)
 or exists(select 1 from public.staff_profiles p join public.trips t on t.id=orbit_trip_participation.trip_id
  where p.id=(select auth.uid()) and p.tenant_id=orbit_trip_participation.tenant_id and p.is_active
   and p.role in ('Central','Principal','Superintendent') and (p.school_id is null or p.school_id=t.school_id))
));
grant select on public.orbit_trip_participation to authenticated;

create policy orbit_calendar_provider_own_read on public.orbit_calendar_provider_connections for select to authenticated
using(tenant_id=(select public.jwt_tenant_id()) and user_id=(select auth.uid()));
grant select on public.orbit_calendar_provider_connections to authenticated;

-- Ledger updates/deletes are forbidden; corrections are new verified ledger events.
create or replace function private.orbit_funding_ledger_immutable() returns trigger
language plpgsql set search_path='' as $$
begin raise exception 'Orbit verified payment ledger is append-only'; end $$;
revoke all on function private.orbit_funding_ledger_immutable() from public,anon,authenticated;
create trigger orbit_payment_ledger_immutable before update or delete on public.orbit_trip_payment_ledger
 for each row execute function private.orbit_funding_ledger_immutable();
