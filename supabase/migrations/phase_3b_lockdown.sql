-- Phase 3B: Security Core lockdown for Orbit Systems
-- Enables pgcrypto, adds pin_hash, creates hardened RPC, and applies least-privilege

-- 1. Enable the pgcrypto extension inside the extensions schema
create extension if not exists pgcrypto schema extensions;

-- 2. Add the pin_hash column to the students table
alter table public.students
  add column if not exists pin_hash text;

comment on column public.students.pin_hash is 'Secure salted Blowfish hash of the student verification PIN for double-blind validation.';

-- 3. Create the StateRAMP-hardened RPC function
create or replace function public.verify_student_pin(
  p_student_id uuid,
  p_pin text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_stored_hash text;
  v_dummy_hash constant text := '$2a$06$012345678901234567890unpvI.xHqQ8gqR5QhS67T8U9V0W1X2Y.';
  v_is_valid boolean := false;
begin
  if p_student_id is null or p_pin is null or p_pin = '' then
    return false;
  end if;

  select pin_hash into v_stored_hash
  from public.students
  where id = p_student_id;

  if v_stored_hash is null then
    -- perform a dummy crypt operation to mitigate timing attacks
    perform extensions.crypt(p_pin, v_dummy_hash);
    return false;
  end if;

  if extensions.crypt(p_pin, v_stored_hash) = v_stored_hash then
    v_is_valid := true;
  end if;

  return v_is_valid;

exception
  when others then
    return false;
end;
$$;

-- 4. Apply Least Privilege Model controls
revoke execute on function public.verify_student_pin(uuid, text) from public;
revoke execute on function public.verify_student_pin(uuid, text) from anon;

grant execute on function public.verify_student_pin(uuid, text) to authenticated;
grant execute on function public.verify_student_pin(uuid, text) to service_role;
