
-- === Helpers ===
create or replace function norm_text(t text) returns text
language sql immutable as $$ select trim(lower(t)); $$;

create or replace function validate_employee(p_employee_id text, p_full_name text)
returns boolean
language plpgsql
security definer
as $$
declare ok boolean;
begin
  select exists(
    select 1 from employees
    where is_active
      and norm_text(employee_id)=norm_text(p_employee_id)
      and norm_text(full_name)=norm_text(p_full_name)
  ) into ok;
  return ok;
end;
$$;

create or replace function create_request(
  p_employee_id text, p_full_name text, p_phone text, p_designation text,
  p_passengers int, p_purpose text, p_note text,
  p_pickup jsonb, p_dropoff jsonb, p_requested_at timestamptz
)
returns uuid
language plpgsql
security definer
as $$
declare
  pmin int; pmax int; sopen time; sclose time;
  req_id uuid;
  req_time time;
begin
  select passenger_min, passenger_max, hours_open, hours_close
    into pmin, pmax, sopen, sclose
  from system_settings where id = 1;

  if not validate_employee(p_employee_id, p_full_name) then
    raise exception 'Invalid employee';
  end if;

  if p_passengers < pmin or p_passengers > pmax then
    raise exception 'Passengers out of allowed range (% to %)', pmin, pmax;
  end if;

  req_time := (p_requested_at at time zone 'UTC')::time;
  if req_time < sopen or req_time > sclose then
    null;
  end if;

  insert into requests(
    employee_id, full_name, phone, designation,
    passengers, purpose, note,
    pickup_location, dropoff_location, requested_at, status
  ) values (
    p_employee_id, p_full_name, p_phone, p_designation,
    p_passengers, p_purpose, p_note,
    p_pickup, p_dropoff, p_requested_at, 'Assigning'
  )
  returning id into req_id;

  insert into request_status_history(request_id, old_status, new_status, changed_by)
  values (req_id, null, 'Assigning', 'employee');

  return req_id;
end;
$$;

create or replace function driver_login(p_employee_id text, p_password_hash text)
returns table(session_token text, driver_id bigint, expires_at timestamptz)
language plpgsql
security definer
as $$
declare
  did bigint;
  tok text;
  exp timestamptz := now() + interval '7 days';
begin
  select id into did from drivers
  where is_active and norm_text(employee_id)=norm_text(p_employee_id)
    and password_hash = p_password_hash;

  if not found then
    return;
  end if;

  tok := encode(gen_random_bytes(24), 'hex');
  insert into driver_sessions(driver_id, session_token, expires_at)
  values (did, tok, exp);

  return query select tok, did, exp;
end;
$$;

create or replace function verify_driver_session(p_token text)
returns bigint
language plpgsql
security definer
as $$
declare did bigint;
begin
  select driver_id into did
  from driver_sessions
  where session_token=p_token and expires_at>now();
  return did;
end;
$$;

create or replace function driver_update_request(
  p_session_token text,
  p_request_id uuid,
  p_action text,
  p_eta_minutes int,
  p_reason text,
  p_status request_status
)
returns boolean
language plpgsql
security definer
as $$
declare
  did bigint;
  old request_status;
begin
  did := verify_driver_session(p_session_token);
  if did is null then
    return false;
  end if;

  select status into old from requests where id = p_request_id;
  if not found then return false; end if;

  if p_action = 'accept' then
    update requests
       set status = 'Assigned',
           status_updated_at = now(),
           assigned_driver_id = did
     where id = p_request_id;

    insert into request_status_history(request_id, old_status, new_status, changed_by, reason)
    values (p_request_id, old, 'Assigned', 'driver:'||did::text, 'ETA:'||coalesce(p_eta_minutes,0));

    return true;

  elsif p_action = 'reject' then
    update requests
       set status = 'Rejected',
           status_updated_at = now()
     where id = p_request_id;

    insert into request_status_history(request_id, old_status, new_status, changed_by, reason)
    values (p_request_id, old, 'Rejected', 'driver:'||did::text, p_reason);

    return true;

  elsif p_action = 'status' then
    update requests
       set status = p_status,
           status_updated_at = now()
     where id = p_request_id;

    insert into request_status_history(request_id, old_status, new_status, changed_by)
    values (p_request_id, old, p_status, 'driver:'||did::text);

    if p_status = 'Completed' then
      if exists (
        select 1
        from request_status_history h1
        join request_status_history h2
          on h2.request_id = h1.request_id
        where h1.request_id = p_request_id
          and h1.new_status = 'Started'
          and h2.new_status = 'Completed'
          and h2.created_at - h1.created_at >= interval '60 minutes'
      ) then
        insert into admin_alerts(alert_type, details)
        values ('LongTrip', jsonb_build_object('request_id', p_request_id));
      end if;
    end if;

    return true;
  end if;

  return false;
end;
$$;

create or replace function log_driver_search(p_session_token text, p_query text, p_viewed_request uuid)
returns boolean
language plpgsql
security definer
as $$
declare did bigint; r_created timestamptz;
begin
  did := verify_driver_session(p_session_token);
  if did is null then return false; end if;

  insert into driver_search_logs(driver_id, query, viewed_request_id)
  values (did, p_query, p_viewed_request);

  if p_viewed_request is not null then
    select created_at into r_created from requests where id=p_viewed_request;
    if r_created < now() - interval '2 days' then
      insert into admin_alerts(alert_type, details)
      values ('OldRequestViewed', jsonb_build_object('request_id', p_viewed_request, 'driver_id', did));
    end if;
  end if;

  return true;
end;
$$;

create or replace function get_requests_by_phone(p_phone text)
returns setof requests
language sql
security definer
as $$
  select * from requests where phone = p_phone order by created_at desc;
$$;

create or replace function get_request_by_id(p_id uuid)
returns requests
language sql
security definer
as $$
  select * from requests where id = p_id;
$$;

create or replace function cancel_request(p_id uuid, p_phone text)
returns boolean
language plpgsql
security definer
as $$
declare old request_status;
begin
  select status into old from requests where id=p_id and phone=p_phone;
  if not found then return false; end if;

  update requests set status='Canceled', status_updated_at=now()
  where id=p_id and phone=p_phone;

  insert into request_status_history(request_id, old_status, new_status, changed_by)
  values (p_id, old, 'Canceled', 'employee');

  return true;
end;
$$;

create or replace function get_driver_requests(
  p_session_token text,
  p_query text default null
)
returns setof requests
language plpgsql
security definer
as $$
declare did bigint;
begin
  did := verify_driver_session(p_session_token);
  if did is null then
    return;
  end if;

  return query
  select r.*
  from requests r
  where r.assigned_driver_id = did
    and (
      p_query is null
      or norm_text(cast(r.id as text)) like '%'||norm_text(p_query)||'%'
      or norm_text(coalesce(r.purpose,'')) like '%'||norm_text(p_query)||'%'
      or norm_text(coalesce(r.full_name,'')) like '%'||norm_text(p_query)||'%'
    )
  order by r.created_at desc;
end;
$$;
