-- =====================================================================
-- ServicePro v2 — the life of a job:
--   open call (diagnosis PO) → assign visit → drive (ETA, 5-min alert)
--   → arrive → check-in code → document → request PO letters (escalation)
--   → finish visit: completed / parts needed / return needed / quote needed
--   → complete job → warranty, bill within 7 days, fees
-- =====================================================================

create or replace function _set_status(p_wo uuid, p_status wo_status) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _allow_internal();
  update work_orders set status = p_status where id = p_wo and status is distinct from p_status;
  perform _end_internal();
end $$;

-- ---------- Opening a call -------------------------------------------
create or replace function create_work_order(
  p_site uuid,
  p_issue_type uuid default null,
  p_description text default null,
  p_equipment uuid default null,
  p_priority smallint default null,
  p_store_po_number text default null,
  p_kind wo_kind default 'service',
  p_contractor uuid default null,
  p_require_checkin boolean default null,
  p_id uuid default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare
  m profiles := me(); s sites; cu customers; it issue_types; v_contractor uuid; a agreements;
  w work_orders; v_amount numeric; v_after boolean; v_desc text; v_resp int; wr record;
begin
  if m.id is null then raise exception 'Not signed in.'; end if;
  select * into s from sites where id = p_site;
  if s.id is null then raise exception 'Unknown site.'; end if;
  select * into cu from customers where id = s.customer_id;
  if p_issue_type is not null then
    select * into it from issue_types where id = p_issue_type and active;
    if it.id is null then raise exception 'Unknown problem type.'; end if;
  end if;

  if m.customer_id is not null then
    if m.customer_id <> s.customer_id or not profile_sees_site(m.id, p_site) then raise exception 'That location is not yours.'; end if;
    if not (m.can_open_calls or m.is_org_admin) then raise exception 'You are not set up to open service calls.'; end if;
    if p_kind = 'service' and it.id is null then raise exception 'Pick what the problem is from the list.'; end if;
    v_contractor := coalesce(p_contractor, (select contractor_id from customer_contractors
                     where customer_id = s.customer_id order by is_primary desc, created_at limit 1));
  elsif m.contractor_id is not null and (m.is_org_admin or m.can_dispatch) then
    v_contractor := m.contractor_id;
  else
    raise exception 'Your role cannot open service calls.';
  end if;
  if not exists (select 1 from customer_contractors where contractor_id = v_contractor and customer_id = s.customer_id) then
    raise exception 'That contractor does not serve this customer.';
  end if;
  if p_equipment is not null and not exists (select 1 from equipment where id = p_equipment and site_id = p_site) then
    raise exception 'That equipment is not at this location.';
  end if;

  v_desc := coalesce(nullif(trim(p_description), ''), it.name);
  if v_desc is null then raise exception 'Describe the problem.'; end if;
  a := active_agreement(v_contractor, p_site);
  v_after := is_after_hours(p_site);
  v_amount := case when it.id is not null or a.diagnosis_amount is not null
                   then diagnosis_amount(p_site, it.id, v_contractor) end;

  insert into work_orders (id, kind, contractor_id, customer_id, site_id, equipment_id, trade_id, issue_type_id,
                           agreement_id, priority, after_hours, issue_description, store_po_number,
                           require_checkin, require_checkout, created_by)
  values (coalesce(p_id, gen_random_uuid()), p_kind, v_contractor, s.customer_id, p_site, p_equipment, it.trade_id, it.id,
          a.id, coalesce(p_priority, it.priority, 2), v_after, v_desc, nullif(trim(p_store_po_number), ''),
          coalesce(p_require_checkin, s.require_checkin), s.require_checkout, m.id)
  returning * into w;

  -- Response-time commitment from the agreement
  v_resp := case w.priority when 1 then a.response_emergency_min when 2 then a.response_normal_min else a.response_low_min end;
  if v_resp is not null then
    perform _allow_internal();
    update work_orders set response_due_at = created_at + make_interval(mins => v_resp) where id = w.id returning * into w;
    perform _end_internal();
  end if;

  -- PO base line: the diagnosis amount the store authorizes
  if v_amount is not null then
    insert into po_lines (work_order_id, seq, kind, amount, description, status, requested_by, decided_by, decided_at)
    values (w.id, 0, case p_kind when 'install' then 'install'::po_line_kind else 'diagnosis' end, v_amount,
            case when v_after then 'Diagnosis (after hours)' else 'Diagnosis' end ||
            case when m.contractor_id is not null then ' — entered by contractor' else '' end,
            'approved', m.id, case when m.customer_id is not null then m.id end, now());
  end if;

  if m.customer_id is not null then
    perform _notify_office(w.id, 'new_call', format('New %scall #%s at %s: %s',
      case when w.priority = 1 then 'EMERGENCY ' else '' end, w.number, s.name, w.issue_description));
  else
    perform _notify_customer(w.id, 'new_call', format('%s opened call #%s at %s: %s',
      (select name from contractors where id = v_contractor), w.number, s.name, w.issue_description));
  end if;

  -- Warranty heads-up for both sides
  if p_equipment is not null then
    for wr in select * from warranties where equipment_id = p_equipment and ends_on >= current_date loop
      perform _notify_customer(w.id, 'warranty', format('Call #%s: this unit has %s warranty until %s (%s).',
        w.number, wr.kind, to_char(wr.ends_on, 'Mon DD, YYYY'), wr.description), 'warranty:' || w.id || ':' || wr.id);
      perform _notify_office(w.id, 'warranty', format('Call #%s: unit under %s warranty until %s (%s).',
        w.number, wr.kind, to_char(wr.ends_on, 'Mon DD, YYYY'), wr.description), 'warranty:' || w.id || ':' || wr.id);
    end loop;
  end if;
  return w;
end $$;

create or replace function cancel_work_order(p_wo uuid, p_reason text)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo for update;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for cancelling.'; end if;
  if is_customer_member(w.customer_id) and can_see_site(w.site_id) then
    if w.status not in ('created','assigned') then
      raise exception 'The technician is already on the way or has been there; call the contractor to cancel.';
    end if;
  elsif not is_contractor_dispatcher(w.contractor_id) then
    raise exception 'Not allowed.';
  end if;
  if w.status in ('completed','invoiced','cancelled') then raise exception 'This call is already closed.'; end if;
  update visits set status = 'cancelled' where work_order_id = p_wo and status in ('assigned','en_route');
  perform _allow_internal();
  update work_orders set status = 'cancelled', cancelled_at = now(),
         work_summary = coalesce(work_summary || E'\n', '') || 'Cancelled: ' || trim(p_reason)
   where id = p_wo returning * into w;
  perform _end_internal();
  perform _notify_customer(p_wo, 'completed', format('Call #%s was cancelled: %s', w.number, trim(p_reason)));
  return w;
end $$;

-- ---------- Dispatch: a new visit (or reassignment) ------------------
create or replace function assign_work_order(p_wo uuid, p_tech uuid, p_note text default null)
returns visits language plpgsql security definer set search_path = public as $$
declare w work_orders; t profiles; v visits; old visits; n int;
begin
  select * into w from work_orders where id = p_wo for update;
  if not is_contractor_dispatcher(w.contractor_id) then raise exception 'Only dispatch can assign technicians.'; end if;
  select * into t from profiles where id = p_tech and is_technician and active and contractor_id = w.contractor_id;
  if t.id is null then raise exception 'That person is not an active technician of this contractor.'; end if;
  if w.status not in ('created','assigned','en_route','waiting_parts','return_needed','awaiting_approval') then
    raise exception 'This call is % — it cannot be assigned now.', w.status;
  end if;
  -- A tech already on site cannot be swapped out from the office
  if exists (select 1 from visits where work_order_id = p_wo and status = 'on_site') then
    raise exception 'A technician is on site. They must finish their visit first.';
  end if;
  -- Replace a visit that has not reached the site yet
  select * into old from visits where work_order_id = p_wo and status in ('assigned','en_route') for update;
  if old.id is not null then
    if old.technician_id = p_tech then return old; end if;
    update visits set status = 'cancelled', outcome_note = 'Reassigned' where id = old.id;
    perform _notify(old.technician_id, p_wo, 'assigned', format('Job #%s was reassigned to someone else.', w.number));
  end if;

  select coalesce(max(visit_no), 0) + 1 into n from visits where work_order_id = p_wo;
  insert into visits (work_order_id, visit_no, technician_id, checkin_required, outcome_note)
  values (p_wo, n, p_tech, w.require_checkin, p_note) returning * into v;
  if w.require_checkin then
    insert into visit_codes (visit_id, code) values (v.id, lpad((floor(random() * 10000))::int::text, 4, '0'));
  end if;

  perform _set_status(p_wo, 'assigned');
  perform _notify(p_tech, p_wo, 'assigned', format('%s job #%s assigned to you.',
    case when n > 1 then 'Return visit for' else 'New' end, w.number));
  perform _notify_customer(p_wo, 'assigned', format('%s is assigned to call #%s%s.', t.full_name, w.number,
    case when n > 1 then ' (return visit)' else '' end));
  return v;
end $$;

-- ---------- Technician actions (all take the visit id) ---------------
create or replace function _my_visit(p_visit uuid) returns visits
language plpgsql security definer set search_path = public as $$
declare v visits;
begin
  select * into v from visits where id = p_visit for update;
  if v.id is null or v.technician_id is distinct from auth.uid() then
    raise exception 'This visit is not assigned to you.';
  end if;
  if v.status = 'cancelled' then raise exception 'This visit was cancelled or reassigned.'; end if;
  perform 1 from work_orders where id = v.work_order_id for update;
  return v;
end $$;

-- The phone confirms it has downloaded the job (dispatch board shows "not yet received" until then)
create or replace function tech_received(p_visit uuid, p_at timestamptz default null)
returns visits language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit);
begin
  if v.received_at is null then
    update visits set received_at = least(_device_time(p_at), now()) where id = v.id returning * into v;
  end if;
  return v;
end $$;

create or replace function tech_start(p_visit uuid, p_at timestamptz default null,
  p_lat double precision default null, p_lon double precision default null)
returns visits language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); t timestamptz := _device_time(p_at); w work_orders;
begin
  if v.status <> 'assigned' then return v; end if;          -- duplicate sync
  update visits set status = 'en_route', started_at = greatest(t, assigned_at),
         received_at = coalesce(received_at, greatest(t, assigned_at)) where id = v.id returning * into v;
  perform _set_status(v.work_order_id, 'en_route');
  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, visit_id, lat, lon, event, recorded_at)
    values (auth.uid(), v.work_order_id, v.id, p_lat, p_lon, 'en_route', t);
  end if;
  select * into w from work_orders where id = v.work_order_id;
  perform _notify_customer(w.id, 'eta_update', format('Technician is on the way for call #%s.', w.number));
  return v;
end $$;

-- ETA from the phone's maps. The store gets the ETA, never the location.
create or replace function tech_update_eta(p_visit uuid, p_eta_at timestamptz)
returns visits language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); old_eta timestamptz := v.eta_at; w work_orders; s sites; alert int;
begin
  if v.status not in ('assigned','en_route') then return v; end if;      -- late sync after arrival
  if p_eta_at < now() - interval '5 minutes' or p_eta_at > now() + interval '24 hours' then
    raise exception 'ETA % is not plausible.', p_eta_at;
  end if;
  update visits set eta_at = p_eta_at where id = v.id returning * into v;
  select * into w from work_orders where id = v.work_order_id;
  select * into s from sites where id = w.site_id;
  alert := coalesce(s.eta_alert_minutes, (select default_eta_alert_min from platform_settings));
  if v.status = 'en_route' and v.eta_alert_sent_at is null and p_eta_at <= now() + make_interval(mins => alert) then
    update visits set eta_alert_sent_at = now() where id = v.id returning * into v;
    perform _notify_customer(w.id, 'eta_close', format('Technician is about %s minutes away for call #%s.%s',
      greatest(1, ceil(extract(epoch from (p_eta_at - now())) / 60))::int, w.number,
      case when v.checkin_required then ' Have your check-in code ready.' else '' end));
  elsif old_eta is null or abs(extract(epoch from (p_eta_at - old_eta))) >= 15 * 60 then
    perform _notify_customer(w.id, 'eta_update', format('Call #%s: technician expected at %s.', w.number,
      to_char(p_eta_at at time zone s.timezone, 'HH12:MI AM')));
  end if;
  return v;
end $$;

-- p_source: 'geofence' (automatic) or 'manual' (tech tapped Arrived)
create or replace function tech_arrive(p_visit uuid, p_at timestamptz default null,
  p_lat double precision default null, p_lon double precision default null, p_source text default 'geofence')
returns visits language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); t timestamptz := _device_time(p_at); w work_orders; s sites; d double precision; mins int;
begin
  if v.status in ('on_site','done') then return v; end if;
  if v.status <> 'en_route' then raise exception 'Tap Start before arriving.'; end if;
  update visits set status = 'on_site', arrived_at = greatest(t, started_at) where id = v.id returning * into v;
  select * into w from work_orders where id = v.work_order_id;
  select * into s from sites where id = w.site_id;
  perform _allow_internal();
  update work_orders set status = case when status = 'awaiting_approval' then status else 'on_site' end,
         first_arrived_at = coalesce(first_arrived_at, v.arrived_at),
         response_met = case when response_due_at is not null and first_arrived_at is null
                             then v.arrived_at <= response_due_at else response_met end
   where id = w.id returning * into w;
  perform _end_internal();

  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, visit_id, lat, lon, event, recorded_at)
    values (auth.uid(), w.id, v.id, p_lat, p_lon,
            case when p_source = 'geofence' then 'geofence_enter'::gps_event else 'arrived'::gps_event end, v.arrived_at);
  end if;
  if p_lat is null then
    perform _raise_flag(w.id, 'gps_mismatch', 'Arrival recorded with no GPS location.', false);
  elsif s.lat is not null then
    d := distance_ft(p_lat, p_lon, s.lat, s.lon);
    if d > s.geofence_radius_ft * 2 then
      perform _raise_flag(w.id, 'gps_mismatch',
        format('Arrival recorded %s ft from the site (geofence %s ft).', round(d::numeric), s.geofence_radius_ft), true);
    end if;
  end if;

  mins := ceil(extract(epoch from (v.arrived_at - w.created_at)) / 60);
  perform _notify_customer(w.id, 'arrival', format('Technician arrived for call #%s at %s.%s', w.number,
    to_char(v.arrived_at at time zone s.timezone, 'HH12:MI AM'),
    case when w.response_due_at is not null and v.visit_no = 1 then
      format(' Arrived in %s — %s your %s agreement.', _hm(mins),
             case when w.response_met then 'within' else 'OUTSIDE' end,
             _hm(ceil(extract(epoch from (w.response_due_at - w.created_at)) / 60)::int))
    else '' end));
  return v;
end $$;

-- Meet-on-site check-in (and check-out with p_checkout = true).
-- Works offline: the phone stores what was entered with the time and sends it later.
-- The correct code is never sent to the phone, so it is checked here.
create or replace function tech_checkin(p_visit uuid, p_method checkin_method, p_code text default null,
  p_person text default null, p_reason text default null, p_at timestamptz default null, p_checkout boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); t timestamptz := _device_time(p_at); w work_orders; s sites; ok boolean; what text;
begin
  if v.arrived_at is null then raise exception 'Arrive on site first.'; end if;
  -- A verified check-in is final; an unverified one (wrong code) may be retried
  if not p_checkout and v.checkin_at is not null and v.checkin_verified then
    return jsonb_build_object('ok', true, 'already', true, 'verified', true);
  end if;
  if p_checkout and v.checkout_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  select * into w from work_orders where id = v.work_order_id;
  select * into s from sites where id = w.site_id;

  if p_method = 'code' then
    ok := exists (select 1 from visit_codes c where c.visit_id = v.id and c.code = trim(p_code));
  elsif p_method = 'backup_code' then
    if s.backup_code_hash is null then raise exception 'This store has no backup code set.'; end if;
    ok := s.backup_code_hash = extensions.crypt(trim(p_code), s.backup_code_hash);
  else
    if coalesce(trim(p_person), '') = '' or coalesce(length(trim(p_reason)), 0) < 5 then
      raise exception 'Enter the name of the person you met and why no code was available.';
    end if;
    ok := false;
  end if;

  what := case when p_checkout then 'Check-out' else 'Check-in' end;
  if p_checkout then
    update visits set checkout_at = greatest(t, arrived_at), checkout_method = p_method where id = v.id;
  else
    update visits set checkin_at = coalesce(checkin_at, greatest(t, arrived_at)), checkin_method = p_method, checkin_verified = ok,
           checkin_person = nullif(trim(p_person), ''), checkin_reason = nullif(trim(p_reason), '') where id = v.id;
  end if;

  if ok then
    update guardrail_flags set resolved_at = now(), resolution_note = 'Verified on retry'
     where work_order_id = w.id and flag = 'checkin_unverified' and resolved_at is null and not p_checkout;
    perform _notify_customer(w.id, 'checkin', format('%s confirmed for call #%s%s.', what, w.number,
      case when p_method = 'backup_code' then ' (store backup code used)' else '' end));
  else
    perform _raise_flag(w.id, 'checkin_unverified', format('%s not verified: %s%s', what,
      case p_method when 'name_only' then format('met %s — %s', trim(p_person), trim(p_reason))
                    else 'wrong code entered' end, ''), true, true);
    perform _notify_customer(w.id, 'checkin', format('%s for call #%s could NOT be verified (%s). Work continues; the contractor will review.',
      what, w.number, case p_method when 'name_only' then 'technician says they met ' || trim(p_person) else 'wrong code' end));
  end if;
  return jsonb_build_object('ok', true, 'verified', ok);
end $$;

create or replace function tech_depart(p_visit uuid, p_at timestamptz default null,
  p_lat double precision default null, p_lon double precision default null)
returns visits language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); t timestamptz := _device_time(p_at); w work_orders; s sites;
begin
  if v.departed_at is not null then return v; end if;
  if v.arrived_at is null then raise exception 'Not on site.'; end if;
  update visits set departed_at = greatest(t, arrived_at) where id = v.id returning * into v;
  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, visit_id, lat, lon, event, recorded_at)
    values (auth.uid(), v.work_order_id, v.id, p_lat, p_lon, 'geofence_exit', v.departed_at);
  end if;
  select * into w from work_orders where id = v.work_order_id;
  select * into s from sites where id = w.site_id;
  perform _notify_customer(w.id, 'departure', format('Technician left the site for call #%s at %s.', w.number,
    to_char(v.departed_at at time zone s.timezone, 'HH12:MI AM')));
  return v;
end $$;

-- Location pings queued on the phone while offline
create or replace function log_gps(p_points jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); n int;
begin
  if not coalesce(m.is_technician, false) then raise exception 'Technicians only.'; end if;
  insert into gps_logs (technician_id, work_order_id, visit_id, lat, lon, accuracy_m, event, recorded_at)
  select m.id, v.work_order_id, v.id, (pt->>'lat')::float8, (pt->>'lon')::float8, (pt->>'accuracy_m')::real, 'ping',
         least((pt->>'at')::timestamptz, now())
  from jsonb_array_elements(p_points) pt
  left join visits v on v.id = (pt->>'visit_id')::uuid and v.technician_id = m.id;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- Documenting the work -------------------------------------
create or replace function _on_site(v visits) returns void
language plpgsql set search_path = public as $$
begin
  if v.status <> 'on_site' then raise exception 'Arrive on site first.'; end if;
end $$;

create or replace function confirm_equipment(p_visit uuid, p_type_code text, p_manufacturer text,
  p_model text, p_serial text, p_location text default null, p_equipment uuid default null, p_refrigerant text default null)
returns equipment language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); w work_orders; e equipment; et uuid;
begin
  perform _on_site(v);
  select * into w from work_orders where id = v.work_order_id;
  if coalesce(trim(p_model), '') = '' or coalesce(trim(p_serial), '') = '' then
    raise exception 'Model and serial are both required. If the plate is unreadable, enter UNREADABLE and photograph it.';
  end if;
  select id into et from equipment_types where code = p_type_code and (contractor_id is null or contractor_id = w.contractor_id)
   order by contractor_id nulls last limit 1;
  if et is null then raise exception 'Unknown equipment type %.', p_type_code; end if;

  if p_equipment is not null then
    select * into e from equipment where id = p_equipment and site_id = w.site_id;
  end if;
  if e.id is null and upper(trim(p_serial)) <> 'UNREADABLE' then
    select * into e from equipment where site_id = w.site_id
      and lower(manufacturer) = lower(trim(p_manufacturer)) and lower(serial) = lower(trim(p_serial));
  end if;
  if e.id is null and w.equipment_id is not null then
    select * into e from equipment where id = w.equipment_id and not identity_confirmed;
  end if;
  if e.id is null then
    insert into equipment (customer_id, site_id, equipment_type_id, manufacturer, model, serial, refrigerant,
                           location_description, identity_confirmed, confirmed_by, confirmed_at)
    values (w.customer_id, w.site_id, et, trim(p_manufacturer), trim(p_model), trim(p_serial), p_refrigerant,
            p_location, true, auth.uid(), now()) returning * into e;
  else
    update equipment set equipment_type_id = et, manufacturer = trim(p_manufacturer), model = trim(p_model),
           serial = trim(p_serial), refrigerant = coalesce(p_refrigerant, refrigerant),
           location_description = coalesce(p_location, location_description),
           identity_confirmed = true, confirmed_by = auth.uid(), confirmed_at = now()
     where id = e.id returning * into e;
  end if;
  perform _allow_internal();
  update work_orders set equipment_id = e.id where id = w.id;
  perform _end_internal();
  update photos set equipment_id = e.id where work_order_id = w.id and kind in ('equipment','nameplate') and equipment_id is null;
  return e;
end $$;

create or replace function _apply_summary(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders; rt repair_types; e equipment; v_parts text; s text;
begin
  select * into w from work_orders where id = p_wo;
  select * into rt from repair_types where id = w.repair_type_id;
  select * into e from equipment where id = w.equipment_id;
  select string_agg(format('%s x%s', pt.name, _qty(pu.quantity)), ', ' order by pt.name)
    into v_parts from parts_used pu join parts pt on pt.id = pu.part_id where pu.work_order_id = p_wo;
  s := coalesce(rt.summary_template,
                case when w.kind = 'pm' then 'Preventive maintenance performed: ' ||
                     coalesce((select string_agg(x->>'item', '; ') from jsonb_array_elements(w.checklist) x), '') || '.'
                     else 'Service performed.' end);
  s := replace(s, '{equipment}', coalesce(nullif(concat_ws(' ', e.manufacturer, e.model), ''), 'unit'));
  s := replace(s, '{location}',  coalesce(e.location_description, 'on site'));
  s := s || case when v_parts is not null then ' Parts: ' || v_parts || '.'
                 when w.no_parts_used then ' No parts used.' else '' end;
  perform _allow_internal();
  update work_orders set work_summary = s where id = p_wo;
  perform _end_internal();
end $$;

create or replace function _upsert_part(p_wo uuid, p_visit uuid, p_part uuid, p_qty numeric, p_source part_source)
returns void language plpgsql security definer set search_path = public as $$
declare cov record; price numeric; cost numeric; covered boolean; kit boolean;
begin
  if p_qty <= 0 then
    delete from parts_used where work_order_id = p_wo and part_id = p_part and source = p_source;
    return;
  end if;
  select * into cov from _coverage(p_wo);
  select coalesce(unit_cost, 0) into cost from parts where id = p_part;
  -- PM kit parts are included in a PM visit's price / agreement
  kit := exists (select 1 from work_orders w join pm_plan_parts pp on pp.pm_plan_id = w.pm_plan_id
                 where w.id = p_wo and pp.part_id = p_part);
  covered := cov.parts or kit;
  price := case when covered then 0 else round(part_price(p_part) * (1 - cov.parts_disc / 100), 2) end;
  insert into parts_used (work_order_id, visit_id, part_id, quantity, source, unit_price, unit_cost, covered, added_by)
  values (p_wo, p_visit, p_part, p_qty, p_source, price, cost, covered, auth.uid())
  on conflict (work_order_id, part_id, source) do update set quantity = excluded.quantity;
end $$;

create or replace function set_repair_type(p_visit uuid, p_repair_type uuid, p_apply_kit boolean default true)
returns work_orders language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); w work_orders; rt repair_types; k record; added boolean := false;
begin
  perform _on_site(v);
  select * into w from work_orders where id = v.work_order_id;
  select * into rt from repair_types where id = p_repair_type and contractor_id = w.contractor_id and active;
  if rt.id is null then raise exception 'Unknown repair type.'; end if;
  perform _allow_internal();
  update work_orders set repair_type_id = rt.id, trade_id = coalesce(trade_id, rt.trade_id) where id = w.id;
  perform _end_internal();
  if p_apply_kit then
    for k in select part_id, quantity from repair_type_parts where repair_type_id = rt.id loop
      if not exists (select 1 from parts_used where work_order_id = w.id and part_id = k.part_id) then
        perform _upsert_part(w.id, v.id, k.part_id, k.quantity, 'truck');
        added := true;
      end if;
    end loop;
    if added then
      perform _allow_internal(); update work_orders set no_parts_used = false where id = w.id; perform _end_internal();
    end if;
  end if;
  perform _apply_summary(w.id);
  return recalc_work_order(w.id);
end $$;

create or replace function set_part_used(p_visit uuid, p_part uuid, p_qty numeric, p_source part_source default 'truck')
returns work_orders language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); w work_orders;
begin
  perform _on_site(v);
  select * into w from work_orders where id = v.work_order_id;
  if not exists (select 1 from parts where id = p_part and contractor_id = w.contractor_id) then
    raise exception 'Unknown part.';
  end if;
  perform _upsert_part(w.id, v.id, p_part, p_qty, p_source);
  if p_qty > 0 then
    perform _allow_internal(); update work_orders set no_parts_used = false where id = w.id; perform _end_internal();
  end if;
  perform _apply_summary(w.id);
  return recalc_work_order(w.id);
end $$;

create or replace function set_no_parts_used(p_visit uuid, p_value boolean)
returns work_orders language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit);
begin
  perform _on_site(v);
  if p_value and exists (select 1 from parts_used where work_order_id = v.work_order_id) then
    raise exception 'Remove the selected parts first, or keep them.';
  end if;
  perform _allow_internal(); update work_orders set no_parts_used = p_value where id = v.work_order_id; perform _end_internal();
  perform _apply_summary(v.work_order_id);
  return recalc_work_order(v.work_order_id);
end $$;

-- PM checklist item: done / reading / photo
create or replace function set_checklist_result(p_visit uuid, p_index int, p_done boolean,
  p_reading text default null, p_photo uuid default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); w work_orders; item jsonb;
begin
  perform _on_site(v);
  select * into w from work_orders where id = v.work_order_id;
  item := w.checklist -> p_index;
  if item is null then raise exception 'No checklist item %.', p_index; end if;
  if p_done and coalesce((item->>'photo')::boolean, false) and p_photo is null then
    raise exception '"%" needs a photo.', item->>'item';
  end if;
  if p_done and coalesce((item->>'reading')::text, '') <> '' and coalesce(trim(p_reading), '') = '' then
    raise exception '"%" needs a reading (%).', item->>'item', item->>'reading';
  end if;
  perform _allow_internal();
  update work_orders set checklist_results = checklist_results ||
    jsonb_build_object(p_index::text, jsonb_build_object('done', p_done, 'reading', p_reading, 'photo_id', p_photo, 'at', now()))
   where id = w.id returning * into w;
  perform _end_internal();
  return w;
end $$;

-- ---------- PO letters: request, route, decide, escalate --------------
create or replace function _chain_for(p_wo uuid) returns approval_chains
language sql stable security definer set search_path = public as $$
  select c.* from work_orders w join approval_chains c on c.customer_id = w.customer_id
  where w.id = p_wo and (c.all_sites = false and exists (
          select 1 from approval_chain_sites x where x.chain_id = c.id and x.site_id = w.site_id) or c.all_sites)
  order by c.all_sites asc, c.created_at limit 1
$$;

-- Total the job would be approved for if this line were approved
create or replace function _total_with(p_line uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(o.amount) filter (where o.status = 'approved'), 0) + l.amount
  from po_lines l join po_lines o on o.work_order_id = l.work_order_id
  where l.id = p_line group by l.amount
$$;

-- Send the request to the right person. p_from_step forces escalation upward.
create or replace function _route_po_line(p_line uuid, p_from_step int default null) returns int
language plpgsql security definer set search_path = public as $$
declare l po_lines; w work_orders; c approval_chains; cu customers; total numeric; st record; target int; msg text; n int := 0;
begin
  select * into l from po_lines where id = p_line;
  select * into w from work_orders where id = l.work_order_id;
  select * into cu from customers where id = w.customer_id;
  c := _chain_for(w.id);
  total := _total_with(l.id);
  msg := format('Approval needed — call #%s, %s: $%s for %s. Approved total would be $%s.',
                w.number, po_label(w.id, l.seq), l.amount, l.description, total);

  if c.id is null then
    -- No chain set up: everyone with approval rights and a high-enough limit for this site
    for st in select p.id from profiles p
              where p.customer_id = w.customer_id and p.active and p.can_approve
                and (p.approval_limit is null or p.approval_limit >= total) and profile_sees_site(p.id, w.site_id) loop
      perform _notify(st.id, w.id, 'approval_request', msg, 'po:' || l.id || ':' || st.id); n := n + 1;
    end loop;
    if n = 0 then   -- nobody high enough: the customer's admins
      for st in select p.id from profiles p where p.customer_id = w.customer_id and p.active and p.is_org_admin loop
        perform _notify(st.id, w.id, 'approval_request', msg, 'po:' || l.id || ':' || st.id);
      end loop;
    end if;
    update po_lines set routed_step = null, routed_at = now() where id = l.id;
    return null;
  end if;

  if p_from_step is null and w.priority = 1 and c.emergency_profile_id is not null then
    perform _notify(c.emergency_profile_id, w.id, 'approval_request', 'EMERGENCY — ' || msg, 'po:' || l.id || ':emergency');
    update po_lines set routed_step = 0, routed_at = now() where id = l.id;
    return 0;
  end if;

  select s.step_no into target
  from approval_chain_steps s join profiles p on p.id = s.profile_id
  where s.chain_id = c.id
    and s.step_no >= greatest(coalesce(p_from_step, 1), case when l.seq >= cu.letter_escalation_at then 2 else 1 end)
    and (p.approval_limit is null or p.approval_limit >= total)
    and p.active and profile_sees_site(p.id, w.site_id)          -- skip approvers who don't cover this store
  order by s.step_no limit 1;
  if target is null then
    select max(step_no) into target from approval_chain_steps where chain_id = c.id;
  end if;
  for st in select profile_id, backup_profile_id from approval_chain_steps where chain_id = c.id and step_no = target loop
    perform _notify(st.profile_id, w.id, 'approval_request', msg, 'po:' || l.id || ':' || st.profile_id);
    perform _notify(st.backup_profile_id, w.id, 'approval_request', '(Backup) ' || msg, 'po:' || l.id || ':' || st.backup_profile_id);
  end loop;
  update po_lines set routed_step = target, routed_at = now() where id = l.id;
  return target;
end $$;

-- Tech (on site) or office asks for the next letter: the repair NTE, an additional repair, …
-- p_breakdown is the simple repair quote: {"parts":[{"part_id":…,"name":…,"qty":1,"price":289}],"labor_hours":1.5,"notes":"…"}
create or replace function request_po_line(p_wo uuid, p_kind po_line_kind, p_amount numeric, p_description text,
  p_breakdown jsonb default null, p_store_po_number text default null, p_photo_ids uuid[] default null)
returns po_lines language plpgsql security definer set search_path = public as $$
declare w work_orders; l po_lines; n int; on_site visits;
begin
  select * into w from work_orders where id = p_wo for update;
  select * into on_site from visits where work_order_id = p_wo and status = 'on_site' limit 1;
  if not (is_contractor_office(w.contractor_id) or on_site.technician_id = auth.uid()) then
    raise exception 'Only the technician on site or the contractor office can request approval.';
  end if;
  if w.status in ('completed','invoiced','cancelled') then raise exception 'This call is closed.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter the amount needed.'; end if;
  if coalesce(trim(p_description), '') = '' then raise exception 'Say what the money is for.'; end if;
  if exists (select 1 from po_lines where work_order_id = p_wo and status = 'pending') then
    raise exception 'An approval request is already waiting on this call.';
  end if;
  select coalesce(max(seq), -1) + 1 into n from po_lines where work_order_id = p_wo;
  if n = 0 then n := 1; end if;   -- no diagnosis line: first request is still "A"
  if n > 26 then raise exception 'Too many PO letters on one call.'; end if;
  insert into po_lines (work_order_id, seq, kind, amount, description, breakdown, store_po_number, requested_by)
  values (p_wo, n, p_kind, round(p_amount, 2), trim(p_description), p_breakdown, nullif(trim(p_store_po_number), ''), auth.uid())
  returning * into l;
  if p_photo_ids is not null then
    update photos set po_line_id = l.id where id = any(p_photo_ids) and work_order_id = p_wo;
  end if;
  if w.status in ('on_site') then perform _set_status(p_wo, 'awaiting_approval'); end if;
  perform _raise_flag(p_wo, 'po_exceeded', format('%s requested: $%s — %s', po_label(p_wo, n), l.amount, l.description), false);
  perform _route_po_line(l.id);
  return l;
end $$;

-- Customer decides. Returns {"ok":true} or {"ok":false,"escalated":true,"message":…}
create or replace function decide_po_line(p_line uuid, p_approve boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); l po_lines; w work_orders; total numeric; my_step int; nxt int; tech uuid;
begin
  select * into l from po_lines where id = p_line for update;
  select * into w from work_orders where id = l.work_order_id for update;
  if m.customer_id is distinct from w.customer_id or not m.can_approve or not profile_sees_site(m.id, w.site_id) then
    raise exception 'You are not set up to approve spending for this location.';
  end if;
  if l.status <> 'pending' then raise exception 'Already decided.'; end if;
  total := _total_with(l.id);

  if p_approve and m.approval_limit is not null and total > m.approval_limit then
    select max(s.step_no) into my_step from approval_chain_steps s join approval_chains c on c.id = s.chain_id
     where c.customer_id = w.customer_id and (s.profile_id = m.id or s.backup_profile_id = m.id);
    nxt := _route_po_line(l.id, greatest(coalesce(my_step, 0), coalesce(l.routed_step, 0)) + 1);
    return jsonb_build_object('ok', false, 'escalated', true,
      'message', format('This brings the call to $%s, above your $%s limit. It has been sent up for approval.', total, m.approval_limit));
  end if;

  update po_lines set status = case when p_approve then 'approved'::approval_status else 'declined' end,
         decided_by = m.id, decided_at = now(), decided_limit = m.approval_limit,
         decline_reason = case when not p_approve then nullif(trim(p_reason), '') end
   where id = l.id returning * into l;

  perform _set_status(w.id, case
    when exists (select 1 from visits where work_order_id = w.id and status = 'on_site') then 'on_site'::wo_status
    when w.status = 'awaiting_approval' then 'return_needed'::wo_status
    else w.status end);
  if p_approve then
    update guardrail_flags set resolved_at = now(), resolved_by = m.id, resolution_note = 'Customer approved ' || po_label(w.id, l.seq)
     where work_order_id = w.id and flag in ('po_exceeded','po_near_cap') and resolved_at is null;
  end if;
  select technician_id into tech from visits where work_order_id = w.id and status = 'on_site' limit 1;
  perform _notify(tech, w.id, case when p_approve then 'approval_granted'::notify_type else 'approval_declined' end,
    format('Call #%s: %s %s ($%s).', w.number, po_label(w.id, l.seq), case when p_approve then 'APPROVED' else 'DECLINED' end, l.amount));
  perform _notify_office(w.id, case when p_approve then 'approval_granted'::notify_type else 'approval_declined' end,
    format('Call #%s: %s %s by %s ($%s)%s.', w.number, po_label(w.id, l.seq), case when p_approve then 'approved' else 'declined' end,
           m.full_name, l.amount, case when not p_approve and p_reason is not null then ': ' || p_reason else '' end));
  return jsonb_build_object('ok', true, 'status', l.status);
end $$;

-- Run every few minutes: unanswered requests move up the chain.
create or replace function escalate_stale_approvals() returns int
language plpgsql security definer set search_path = public as $$
declare l record; n int := 0; c approval_chains; last_step int;
begin
  for l in select pl.* from po_lines pl where pl.status = 'pending' and pl.routed_step is not null loop
    c := _chain_for(l.work_order_id);
    if c.id is null or l.routed_at > now() - make_interval(mins => c.timeout_minutes) then continue; end if;
    select max(step_no) into last_step from approval_chain_steps where chain_id = c.id;
    if l.routed_step >= last_step then continue; end if;
    perform _route_po_line(l.id, l.routed_step + 1);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- Finishing a visit ----------------------------------------
create or replace function completion_check(p_wo uuid, p_end timestamptz default null)
returns table (item text, message text)
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; e equipment; v visits; k record; cap numeric; i int; it jsonb; r jsonb;
begin
  if not can_see_work_order(p_wo) then raise exception 'Not allowed.'; end if;
  select * into w from work_orders where id = p_wo;
  select * into e from equipment where id = w.equipment_id;
  select * into v from visits where work_order_id = p_wo and status = 'on_site' limit 1;

  if v.id is null then item := 'status'; message := 'A technician must be on site to complete.'; return next; end if;
  if v.checkin_required and v.checkin_at is null then
    item := 'checkin'; message := 'Check in with the store person (enter their code).'; return next; end if;
  if w.require_checkout and v.checkout_at is null then
    item := 'checkout'; message := 'Check out with the store person before leaving.'; return next; end if;

  if w.kind in ('service','install') or w.equipment_id is not null then
    if e.id is null or not e.identity_confirmed or coalesce(e.model,'') = '' or coalesce(e.serial,'') = '' then
      item := 'equipment'; message := 'Confirm the equipment model and serial.'; return next; end if;
    if not exists (select 1 from photos where work_order_id = p_wo and kind in ('equipment','nameplate')) then
      item := 'equipment_photo'; message := 'Take a photo of the equipment nameplate.'; return next; end if;
  end if;
  if w.kind in ('service','install') then
    if not exists (select 1 from photos where work_order_id = p_wo and kind = 'before') then
      item := 'before_photo'; message := 'Take a BEFORE photo.'; return next; end if;
    if not exists (select 1 from photos where work_order_id = p_wo and kind = 'after') then
      item := 'after_photo'; message := 'Take an AFTER photo.'; return next; end if;
    if w.repair_type_id is null then item := 'repair_type'; message := 'Select the repair performed.'; return next; end if;
    if not exists (select 1 from parts_used where work_order_id = p_wo) and not w.no_parts_used then
      item := 'parts'; message := 'Select parts used, or tap "No parts used".'; return next; end if;
  end if;
  if w.kind = 'pm' then
    i := 0;
    for it in select * from jsonb_array_elements(w.checklist) loop
      r := w.checklist_results -> i::text;
      if coalesce((it->>'required')::boolean, true) and not coalesce((r->>'done')::boolean, false) then
        item := 'checklist_' || i; message := 'PM task not done: ' || (it->>'item'); return next;
      end if;
      i := i + 1;
    end loop;
  end if;
  if exists (select 1 from po_lines where work_order_id = p_wo and status = 'pending') then
    item := 'approval_pending'; message := 'Waiting for the customer to approve the added amount.'; return next; end if;
  if exists (select 1 from parts_orders where work_order_id = p_wo and status in ('needed','ordered')) then
    item := 'parts_open'; message := 'Parts are still on order for this call.'; return next; end if;
  cap := effective_cap(p_wo);
  if cap is not null then
    select * into k from compute_costs(p_wo, coalesce(p_end, now()));
    if k.total > cap then
      item := 'po_cap';
      message := format('Cost $%s is over the approved $%s. Request approval for $%s more.', k.total, cap, k.total - cap);
      return next;
    end if;
  end if;
end $$;

create or replace function run_guardrails(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders; rt repair_types; raw int; v_missing text; v_extra text;
begin
  select * into w from work_orders where id = p_wo;
  select * into rt from repair_types where id = w.repair_type_id;
  if rt.id is null then return; end if;
  select coalesce(sum(labor_minutes_raw), 0) into raw from visits where work_order_id = p_wo and status <> 'cancelled';
  if rt.expected_cost_min is not null and w.total_cost < rt.expected_cost_min and w.agreement_id is null then
    perform _raise_flag(p_wo, 'underbilling', format('Total $%s is below the usual $%s–$%s for "%s".',
      w.total_cost, rt.expected_cost_min, rt.expected_cost_max, rt.name));
  end if;
  if rt.expected_cost_max is not null and w.total_cost > rt.expected_cost_max then
    perform _raise_flag(p_wo, 'overbilling', format('Total $%s is above the usual $%s–$%s for "%s".',
      w.total_cost, rt.expected_cost_min, rt.expected_cost_max, rt.name));
  end if;
  if (rt.expected_labor_min is not null and raw < rt.expected_labor_min) or
     (rt.expected_labor_max is not null and raw > rt.expected_labor_max) then
    perform _raise_flag(p_wo, 'labor_out_of_range', format('%s min on site; "%s" usually takes %s–%s min.',
      raw, rt.name, rt.expected_labor_min, rt.expected_labor_max));
  end if;
  select string_agg(pt.name, ', ') into v_missing
  from repair_type_parts rp join parts pt on pt.id = rp.part_id
  where rp.repair_type_id = rt.id and not exists (select 1 from parts_used pu where pu.work_order_id = p_wo and pu.part_id = rp.part_id);
  if v_missing is not null and rt.parts_required then
    perform _raise_flag(p_wo, 'parts_missing', 'Usual parts not billed: ' || v_missing);
  end if;
  if exists (select 1 from repair_type_parts where repair_type_id = rt.id) then
    select string_agg(format('%s x%s', pt.name, _qty(pu.quantity)), ', ') into v_extra
    from parts_used pu join parts pt on pt.id = pu.part_id
    left join repair_type_parts rp on rp.repair_type_id = rt.id and rp.part_id = pu.part_id
    where pu.work_order_id = p_wo and (rp.part_id is null or pu.quantity > rp.quantity);
    if v_extra is not null then perform _raise_flag(p_wo, 'parts_excessive', 'Beyond the usual kit: ' || v_extra); end if;
  end if;
end $$;

create or replace function _refresh_invoice_ready(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _allow_internal();
  update work_orders w set invoice_ready = (w.status = 'completed' and not exists (
      select 1 from guardrail_flags f where f.work_order_id = w.id and f.blocking and f.resolved_at is null))
   where w.id = p_wo;
  perform _end_internal();
end $$;

create or replace function _billing_days(p_wo uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(a.billing_days, c.billing_days, ps.default_billing_days)
  from work_orders w join contractors c on c.id = w.contractor_id cross join platform_settings ps
  left join agreements a on a.id = w.agreement_id where w.id = p_wo
$$;

-- Platform fees for a completed job (see fee schedule). Caps are applied in the monthly run.
create or replace function _record_fees(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders; cu customers; c contractors; ps platform_settings; mon date; tech uuid;
begin
  select * into w from work_orders where id = p_wo;
  select * into cu from customers where id = w.customer_id;
  select * into c from contractors where id = w.contractor_id;
  select * into ps from platform_settings;
  mon := date_trunc('month', w.completed_at)::date;
  select technician_id into tech from visits where work_order_id = p_wo and status = 'done' order by visit_no desc limit 1;
  if cu.kind = 'commercial' then   -- homeowners pay nothing
    insert into platform_fees (org_kind, org_id, work_order_id, billing_month, amount, waived)
    values ('customer', cu.id, p_wo, mon, case when w.kind = 'pm' then ps.store_fee_per_pm else ps.store_fee_per_po end,
            coalesce(cu.fees_waived_until >= w.completed_at::date, false))
    on conflict do nothing;
  end if;
  insert into platform_fees (org_kind, org_id, work_order_id, technician_id, billing_month, amount, waived)
  values ('contractor', c.id, p_wo, tech, mon, case when w.kind = 'pm' then ps.contractor_fee_per_pm else ps.contractor_fee_per_po end,
          coalesce(c.fees_waived_until >= w.completed_at::date, false))
  on conflict do nothing;
end $$;

create or replace function _complete_job(p_wo uuid, p_at timestamptz) returns work_orders
language plpgsql security definer set search_path = public as $$
declare w work_orders; rt repair_types; s sites;
begin
  perform _allow_internal();
  update work_orders set status = 'completed', completed_at = p_at,
         invoice_due_at = p_at + make_interval(days => _billing_days(p_wo)) where id = p_wo;
  perform _end_internal();
  perform _apply_summary(p_wo);
  w := recalc_work_order(p_wo);
  perform run_guardrails(p_wo);
  perform _refresh_invoice_ready(p_wo);
  perform _record_fees(p_wo);
  -- Default warranty from the repair type (billing can change it at closeout)
  select * into rt from repair_types where id = w.repair_type_id;
  if rt.default_warranty_id is not null and w.equipment_id is not null then
    perform _apply_warranty(p_wo, rt.default_warranty_id);
  end if;
  -- PM: schedule the next one from the completion date
  if w.pm_plan_id is not null then
    update pm_plans set next_due_on = (p_at::date + make_interval(months => frequency_months))::date where id = w.pm_plan_id;
  end if;
  select * into w from work_orders where id = p_wo;
  select * into s from sites where id = w.site_id;
  perform _notify_customer(p_wo, 'completed', format('Call #%s at %s is complete. Bill pending — about $%s. Invoice due by %s.',
    w.number, s.name, w.total_cost, to_char(w.invoice_due_at at time zone s.timezone, 'Mon DD')));
  perform _notify_office(p_wo, 'completed', format('Call #%s completed — $%s. Invoice due by %s.',
    w.number, w.total_cost, to_char(w.invoice_due_at at time zone s.timezone, 'Mon DD')));
  return w;
end $$;

-- p_outcome: completed | parts_needed (p_parts required) | return_needed (p_note required) | quote_needed (a pending PO letter required)
-- p_parts: [{"description":"Compressor contactor 40A","part_id":null,"quantity":1,"supplier":"Johnstone","expected_on":"2026-10-20"}]
-- Returns {"ok":true,...} or {"ok":false,"missing":[…]}. Never half-finishes.
create or replace function tech_finish_visit(p_visit uuid, p_outcome visit_outcome, p_note text default null,
  p_parts jsonb default null, p_at timestamptz default null, p_lat double precision default null, p_lon double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); t timestamptz := _device_time(p_at); w work_orders; missing jsonb; pt jsonb; parts_text text;
begin
  if v.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  perform _on_site(v);
  t := greatest(t, v.arrived_at);
  select * into w from work_orders where id = v.work_order_id;

  if p_outcome = 'completed' then
    select jsonb_agg(jsonb_build_object('item', item, 'message', message)) into missing from completion_check(w.id, t);
  else
    -- Leaving without finishing still needs the basics recorded
    select jsonb_agg(jsonb_build_object('item', item, 'message', message)) into missing from completion_check(w.id, t)
     where item in ('checkin','equipment','equipment_photo','before_photo');
    if p_outcome = 'parts_needed' and coalesce(jsonb_array_length(p_parts), 0) = 0 then
      missing := coalesce(missing, '[]') || jsonb_build_array(jsonb_build_object('item','parts_list','message','List the parts needed.'));
    elsif p_outcome = 'return_needed' and coalesce(length(trim(p_note)), 0) < 5 then
      missing := coalesce(missing, '[]') || jsonb_build_array(jsonb_build_object('item','note','message','Say why a return visit is needed.'));
    elsif p_outcome = 'quote_needed' and not exists (select 1 from po_lines where work_order_id = w.id and status = 'pending') then
      missing := coalesce(missing, '[]') || jsonb_build_array(jsonb_build_object('item','quote','message','Send the repair quote for approval first.'));
    end if;
  end if;
  if missing is not null and jsonb_array_length(missing) > 0 then
    return jsonb_build_object('ok', false, 'missing', missing);
  end if;

  update visits set status = 'done', outcome = p_outcome, outcome_note = nullif(trim(p_note), ''), completed_at = t
   where id = v.id returning * into v;
  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, visit_id, lat, lon, event, recorded_at)
    values (auth.uid(), w.id, v.id, p_lat, p_lon, 'completed', t);
  end if;

  if p_outcome = 'completed' then
    w := _complete_job(w.id, t);
    return jsonb_build_object('ok', true, 'status', w.status, 'total_cost', w.total_cost, 'invoice_ready', w.invoice_ready);
  end if;

  if p_outcome = 'parts_needed' then
    for pt in select * from jsonb_array_elements(p_parts) loop
      insert into parts_orders (work_order_id, visit_id, part_id, description, quantity, supplier, expected_on, created_by)
      values (w.id, v.id, (pt->>'part_id')::uuid, coalesce(pt->>'description', (select name from parts where id = (pt->>'part_id')::uuid)),
              coalesce((pt->>'quantity')::numeric, 1), pt->>'supplier', (pt->>'expected_on')::date, auth.uid());
    end loop;
    select string_agg(description || coalesce(' (expected ' || to_char(expected_on, 'Mon DD') || ')', ''), ', ')
      into parts_text from parts_orders where work_order_id = w.id and status in ('needed','ordered');
    perform _set_status(w.id, 'waiting_parts');
    perform _notify_customer(w.id, 'parts_waiting', format('Call #%s is waiting for parts: %s. It stays open until the return visit.', w.number, parts_text));
    perform _notify_office(w.id, 'parts_waiting', format('Call #%s needs parts: %s.', w.number, parts_text));
  elsif p_outcome = 'return_needed' then
    perform _set_status(w.id, 'return_needed');
    perform _notify_customer(w.id, 'parts_waiting', format('Call #%s needs a return visit: %s', w.number, trim(p_note)));
    perform _notify_office(w.id, 'parts_waiting', format('Call #%s needs a return visit: %s', w.number, trim(p_note)));
  else
    perform _set_status(w.id, 'awaiting_approval');
  end if;
  perform recalc_work_order(w.id);
  return jsonb_build_object('ok', true, 'status', (select status from work_orders where id = w.id));
end $$;

-- ---------- Waiting for parts ----------------------------------------
create or replace function update_parts_order(p_order uuid, p_status parts_order_status,
  p_supplier text default null, p_expected_on date default null)
returns parts_orders language plpgsql security definer set search_path = public as $$
declare o parts_orders; w work_orders;
begin
  select * into o from parts_orders where id = p_order for update;
  select * into w from work_orders where id = o.work_order_id;
  if not is_contractor_office(w.contractor_id) then raise exception 'Only the contractor office can update parts orders.'; end if;
  update parts_orders set status = p_status, supplier = coalesce(p_supplier, supplier),
         expected_on = coalesce(p_expected_on, expected_on),
         received_at = case when p_status = 'received' then now() else received_at end
   where id = p_order returning * into o;
  if p_expected_on is not null then
    perform _notify_customer(w.id, 'parts_waiting', format('Call #%s: %s now expected %s.', w.number, o.description, to_char(p_expected_on, 'Mon DD')));
  end if;
  if not exists (select 1 from parts_orders where work_order_id = w.id and status in ('needed','ordered')) and w.status = 'waiting_parts' then
    perform _set_status(w.id, 'return_needed');
    perform _notify_office(w.id, 'parts_waiting', format('All parts are in for call #%s — schedule the return visit.', w.number));
    perform _notify_customer(w.id, 'parts_waiting', format('Parts are in for call #%s; the return visit is being scheduled.', w.number));
  end if;
  return o;
end $$;

-- ---------- Warranties -----------------------------------------------
create or replace function _apply_warranty(p_wo uuid, p_term uuid) returns int
language plpgsql security definer set search_path = public as $$
declare w work_orders; t warranty_terms; d date; n int := 0; k int;
begin
  select * into w from work_orders where id = p_wo;
  select * into t from warranty_terms where id = p_term and contractor_id = w.contractor_id;
  if t.id is null then raise exception 'Unknown warranty term.'; end if;
  if w.equipment_id is null then raise exception 'No equipment on this call to attach a warranty to.'; end if;
  delete from warranties where work_order_id = p_wo;
  d := coalesce(w.completed_at::date, current_date);
  if t.labor_days > 0 then
    insert into warranties (work_order_id, equipment_id, kind, starts_on, ends_on, description, created_by)
    values (p_wo, w.equipment_id, 'labor', d, d + t.labor_days, format('Labor on call #%s (%s)', w.number, t.name), auth.uid());
    n := n + 1;
  end if;
  if t.parts_days > 0 then
    insert into warranties (work_order_id, equipment_id, part_id, kind, starts_on, ends_on, description, created_by)
    select p_wo, w.equipment_id, pu.part_id, 'parts', d, d + t.parts_days, format('%s — call #%s', pt.name, w.number), auth.uid()
    from parts_used pu join parts pt on pt.id = pu.part_id where pu.work_order_id = p_wo;
    get diagnostics k = row_count;
    n := n + k;
  end if;
  return n;
end $$;

-- Closeout dropdown (billing/office)
create or replace function set_warranty(p_wo uuid, p_term uuid) returns int
language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo;
  if not is_contractor_office(w.contractor_id) then raise exception 'Only the contractor office sets warranties.'; end if;
  if w.status not in ('completed','invoiced') then raise exception 'Set the warranty at closeout, after the work is completed.'; end if;
  return _apply_warranty(p_wo, p_term);
end $$;

create or replace function mark_warranty_claim(p_wo uuid, p_is_claim boolean, p_reason text default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo for update;
  if not is_contractor_office(w.contractor_id) then raise exception 'Not allowed.'; end if;
  if not p_is_claim and coalesce(length(trim(p_reason)), 0) < 10 then
    raise exception 'Declining warranty needs a reason the store will see.';
  end if;
  perform _allow_internal();
  update work_orders set warranty_claim = p_is_claim, warranty_decline_reason = case when p_is_claim then null else trim(p_reason) end
   where id = p_wo returning * into w;
  perform _end_internal();
  perform _notify_customer(p_wo, 'warranty', format('Call #%s: %s', w.number,
    case when p_is_claim then 'handled as warranty work.' else 'NOT covered by warranty — ' || trim(p_reason) end));
  return w;
end $$;

-- ---------- Office review & billing ----------------------------------
create or replace function resolve_flag(p_flag uuid, p_note text)
returns guardrail_flags language plpgsql security definer set search_path = public as $$
declare f guardrail_flags; w work_orders;
begin
  select * into f from guardrail_flags where id = p_flag;
  select * into w from work_orders where id = f.work_order_id;
  if not is_contractor_office(w.contractor_id) then raise exception 'Not allowed.'; end if;
  if f.flag = 'billing_late' then raise exception 'This clears itself when the invoice is sent.'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Add a note explaining the resolution.'; end if;
  update guardrail_flags set resolved_at = now(), resolved_by = auth.uid(), resolution_note = trim(p_note)
   where id = p_flag returning * into f;
  perform _refresh_invoice_ready(w.id);
  return f;
end $$;

-- Logged correction of a visit time (dead phone, GPS lag). Visible to the store.
create or replace function override_time(p_visit uuid, p_field text, p_value timestamptz, p_reason text)
returns work_orders language plpgsql security definer set search_path = public as $$
declare v visits; w work_orders; old_val timestamptz;
begin
  select * into v from visits where id = p_visit for update;
  select * into w from work_orders where id = v.work_order_id for update;
  if not exists (select 1 from profiles where id = auth.uid() and active and contractor_id = w.contractor_id and is_org_admin) then
    raise exception 'Only a contractor admin can correct times.';
  end if;
  if w.status = 'invoiced' then raise exception 'Already invoiced.'; end if;
  if p_value > now() then raise exception 'Time cannot be in the future.'; end if;
  if p_field not in ('started_at','arrived_at','departed_at','completed_at') then raise exception 'Unknown time field.'; end if;
  execute format('select %I from visits where id = $1', p_field) into old_val using p_visit;
  insert into time_overrides (work_order_id, visit_id, field, old_value, new_value, reason, overridden_by)
  values (w.id, v.id, p_field, old_val, p_value, trim(p_reason), auth.uid());
  perform _allow_internal(true);
  execute format('update visits set %I = $1 where id = $2', p_field) using p_value, p_visit;
  perform _end_internal();
  select * into v from visits where id = p_visit;
  if v.arrived_at < v.started_at or v.completed_at < v.arrived_at or v.departed_at < v.arrived_at then
    raise exception 'Times would be out of order (start ≤ arrive ≤ complete).';
  end if;
  perform _raise_flag(w.id, 'time_override', format('Visit %s %s changed from %s to %s: %s',
    v.visit_no, replace(p_field, '_', ' '), coalesce(old_val::text, 'blank'), p_value, trim(p_reason)), false, true);
  w := recalc_work_order(w.id);
  if effective_cap(w.id) is not null and w.total_cost > effective_cap(w.id) then
    perform _raise_flag(w.id, 'po_exceeded', format('After the time correction, $%s exceeds the approved $%s. Get approval or adjust.',
      w.total_cost, effective_cap(w.id)), true);
  end if;
  perform _refresh_invoice_ready(w.id);
  return w;
end $$;

create or replace function mark_invoiced(p_wo uuid, p_invoice_id text)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo for update;
  if not (is_contractor_office(w.contractor_id) or current_user = 'service_role') then raise exception 'Not allowed.'; end if;
  if not w.invoice_ready then raise exception 'Resolve all review items before invoicing.'; end if;
  if coalesce(trim(p_invoice_id), '') = '' then raise exception 'Enter the invoice number.'; end if;
  update guardrail_flags set resolved_at = now(), resolution_note = 'Invoice sent'
   where work_order_id = p_wo and flag = 'billing_late' and resolved_at is null;
  perform _allow_internal();
  update work_orders set status = 'invoiced', qbo_invoice_id = trim(p_invoice_id), invoiced_at = now()
   where id = p_wo returning * into w;
  perform _end_internal();
  perform _notify_customer(p_wo, 'completed', format('Invoice %s sent for call #%s — $%s%s.', trim(p_invoice_id), w.number, w.total_cost,
    case when w.invoiced_at > w.invoice_due_at then ' (late)' else '' end));
  return w;
end $$;

-- Hourly: billing reminders, late-bill alerts (to BOTH sides), missed response times.
create or replace function billing_clock() returns int
language plpgsql security definer set search_path = public as $$
declare w record; n int := 0; ps platform_settings;
begin
  select * into ps from platform_settings;
  for w in select * from work_orders where status = 'completed' loop
    if now() >= w.completed_at + make_interval(days => ps.billing_reminder_days) and now() < w.invoice_due_at then
      perform _notify_office(w.id, 'billing_due', format('Invoice for call #%s is due by %s.', w.number,
        to_char(w.invoice_due_at, 'Mon DD')), 'billing_due:' || w.id);
    end if;
    if now() > w.invoice_due_at then
      perform _raise_flag(w.id, 'billing_late', format('Invoice not sent within %s days of completion (due %s).',
        _billing_days(w.id), to_char(w.invoice_due_at, 'Mon DD')), false, true);
      perform _notify_office(w.id, 'billing_overdue', format('OVERDUE: invoice for call #%s was due %s.', w.number,
        to_char(w.invoice_due_at, 'Mon DD')), 'billing_overdue:' || w.id);
      perform _notify_customer(w.id, 'billing_overdue', format('The bill for call #%s (about $%s) is late — it was due %s. Expect it soon.',
        w.number, w.total_cost, to_char(w.invoice_due_at, 'Mon DD')), 'billing_overdue:' || w.id);
      n := n + 1;
    end if;
  end loop;
  for w in select * from work_orders where response_due_at < now() and first_arrived_at is null
           and status not in ('cancelled','completed','invoiced') loop
    perform _notify_customer(w.id, 'sla_missed', format('Call #%s: the technician has not arrived within your agreement''s response time.', w.number),
      'sla:' || w.id);
    perform _notify_office(w.id, 'sla_missed', format('Call #%s has missed its agreed response time.', w.number), 'sla:' || w.id);
  end loop;
  return n;
end $$;

-- QuickBooks / printing payload
create or replace function invoice_payload(p_wo uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when can_see_work_order(p_wo) or current_user = 'service_role' then
  jsonb_build_object(
    'work_order_number', w.number, 'work_order_id', w.id, 'po_number', coalesce(w.store_po_number, 'PO' || w.number),
    'po_lines', (select jsonb_agg(jsonb_build_object('po', po_label(w.id, l.seq), 'kind', l.kind, 'amount', l.amount,
                  'description', l.description, 'approved_by', p.full_name, 'approved_at', l.decided_at) order by l.seq)
                 from po_lines l left join profiles p on p.id = l.decided_by where l.work_order_id = w.id and l.status = 'approved'),
    'customer', cu.name, 'qbo_customer_ref', cc.qbo_customer_ref, 'site', s.name, 'site_address', s.address,
    'equipment', concat_ws(' ', e.manufacturer, e.model, 'S/N ' || e.serial),
    'description', w.work_summary, 'agreement', a.name,
    'visits', (select jsonb_agg(jsonb_build_object('visit', vi.visit_no, 'technician', tp.full_name,
                 'arrived', vi.arrived_at, 'completed', vi.completed_at, 'hours', round(vi.labor_minutes_billed / 60.0, 2),
                 'labor', vi.labor_amount) order by vi.visit_no)
               from visits vi join profiles tp on tp.id = vi.technician_id where vi.work_order_id = w.id and vi.status = 'done'),
    'lines',
      coalesce((select jsonb_agg(jsonb_build_object('type','part','sku',pt.sku,'name',pt.name,'qty',pu.quantity,
                 'unit_price',pu.unit_price,'amount',pu.total_price,'covered',pu.covered) order by pt.name)
                from parts_used pu join parts pt on pt.id = pu.part_id where pu.work_order_id = w.id), '[]'::jsonb)
      || case when w.total_labor > 0 then jsonb_build_array(jsonb_build_object('type','labor','name','Labor',
                 'qty', round(w.labor_minutes_billed / 60.0, 2), 'amount', w.total_labor)) else '[]'::jsonb end
      || case when w.total_trip > 0 then jsonb_build_array(jsonb_build_object('type','trip','name','Trip charge','amount',w.total_trip)) else '[]'::jsonb end
      || case when w.flat_amount > 0 then jsonb_build_array(jsonb_build_object('type','flat','name','Preventive maintenance visit','amount',w.flat_amount)) else '[]'::jsonb end,
    'total', w.total_cost)
  end
  from work_orders w join customers cu on cu.id = w.customer_id join sites s on s.id = w.site_id
  left join customer_contractors cc on cc.contractor_id = w.contractor_id and cc.customer_id = w.customer_id
  left join equipment e on e.id = w.equipment_id
  left join agreements a on a.id = w.agreement_id
  where w.id = p_wo
$$;
