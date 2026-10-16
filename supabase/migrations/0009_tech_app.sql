-- ServicePro 0009 — Technician app support: the live cost meter with a stop point, quotes built from
-- labor hours + parts, pre-approved emergency limits, the "can't run over" rules, and photo storage.

-- How long labor keeps counting while the tech waits for an approval (both sides agree; default 15 min).
alter table customer_contractors
  add column approval_wait_minutes int not null default 15 check (approval_wait_minutes between 0 and 120);

-- Emergency calls are pre-approved up to this total (set by the store / property manager). Null = none.
alter table sites add column emergency_limit numeric(10,2) check (emergency_limit is null or emergency_limit >= 0);

alter table po_lines add column emergency_preapproved boolean not null default false;

grant update (emergency_limit) on sites to authenticated;
grant insert (emergency_limit) on sites to authenticated;

-- ---------- The meter ------------------------------------------------------
-- Labor rate that actually lands on the bill for this job (0 when an agreement covers labor).
create or replace function _labor_rate_eff(p_wo uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when cov.labor or (w.kind = 'pm' and (cov.pm or w.flat_amount > 0)) then 0
              else round((case when w.after_hours then coalesce(c.after_hours_labor_rate, c.labor_rate) else c.labor_rate end)
                         * (1 - cov.labor_disc / 100), 2) end
  from work_orders w join contractors c on c.id = w.contractor_id cross join lateral _coverage(w.id) cov
  where w.id = p_wo
$$;

-- Everything the meter needs, right now. The stop point leaves room for the approval wait plus
-- 15 minutes to make the equipment safe, so the job never has to cross the approved limit.
create or replace function _meter(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; c contractors; k record; cap numeric; rate numeric; wait int; reserve numeric; stop numeric;
        lim_em numeric; pend po_lines;
begin
  select * into w from work_orders where id = p_wo;
  select * into c from contractors where id = w.contractor_id;
  select * into k from compute_costs(p_wo, now());
  cap := effective_cap(p_wo);
  rate := _labor_rate_eff(p_wo);
  select coalesce(approval_wait_minutes, 15) into wait from customer_contractors
   where contractor_id = w.contractor_id and customer_id = w.customer_id;
  wait := coalesce(wait, 15);
  reserve := round((wait + 15) / 60.0 * rate, 2);
  if cap is not null then
    stop := round(least(cap * c.po_warn_pct / 100, cap - reserve), 2);
    stop := greatest(stop, 0);
  end if;
  select emergency_limit into lim_em from sites where id = w.site_id;
  select * into pend from po_lines where work_order_id = p_wo and status = 'pending' limit 1;
  return jsonb_build_object(
    'limit', cap, 'used', k.total, 'labor', k.labor, 'parts', k.parts, 'trip', k.trip, 'flat', k.flat,
    'labor_minutes', k.labor_minutes, 'rate', rate, 'wait_minutes', wait, 'reserve', reserve, 'stop_at', stop,
    'warn_pct', c.po_warn_pct,
    'state', case when cap is null then 'no_limit' when k.total > cap then 'over' when k.total >= stop then 'stop' else 'ok' end,
    'pending', case when pend.id is null then null else jsonb_build_object('po', po_label(p_wo, pend.seq), 'amount', pend.amount,
                 'owner_status', pend.owner_status) end,
    'emergency_limit', case when w.priority = 1 then lim_em end,
    'at', now());
end $$;

create or replace function job_meter(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_see_work_order(p_wo) then raise exception 'Not allowed.'; end if;
  return _meter(p_wo);
end $$;

-- Every 5 minutes: jobs with a tech on site that reached the stop point (even if the phone is off).
create or replace function meter_watch() returns int
language plpgsql security definer set search_path = public as $$
declare r record; m jsonb; n int := 0; tech uuid;
begin
  for r in select w.* from work_orders w where w.status in ('on_site','awaiting_approval')
             and exists (select 1 from visits v where v.work_order_id = w.id and v.status = 'on_site') loop
    m := _meter(r.id);
    if m->>'state' in ('stop','over') and (m->'pending') = 'null'::jsonb then
      select technician_id into tech from visits where work_order_id = r.id and status = 'on_site' limit 1;
      perform _raise_flag(r.id, 'po_near_cap', format('Cost $%s has reached the stop point ($%s of the $%s approved). Request more before continuing.',
        m->>'used', m->>'stop_at', m->>'limit'), false, true);
      perform _notify(tech, r.id, 'guardrail_flag', format('Job #%s: STOP — $%s of $%s used. Request more before continuing.',
        r.number, m->>'used', m->>'limit'), 'meter_stop:' || r.id);
      perform _notify_office(r.id, 'guardrail_flag', format('Call #%s reached its stop point: $%s of $%s approved.',
        r.number, m->>'used', m->>'limit'), 'meter_stop:' || r.id);
      perform _notify_customer(r.id, 'guardrail_flag', format('Call #%s is near its approved limit ($%s of $%s). The technician must ask before doing more.',
        r.number, m->>'used', m->>'limit'), 'meter_stop:' || r.id);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------- Requests for more: emergencies within the pre-approved limit go through at once ----------
create or replace function request_po_line(p_wo uuid, p_kind po_line_kind, p_amount numeric, p_description text,
 p_breakdown jsonb default null, p_store_po_number text default null, p_photo_ids uuid[] default null)
returns po_lines language plpgsql security definer set search_path = public as $$
declare w work_orders; l po_lines; n int; on_site visits; s sites; total numeric;
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
  if n = 0 then n := 1; end if;
  if n > 26 then raise exception 'Too many PO letters on one call.'; end if;
  insert into po_lines (work_order_id, seq, kind, amount, description, breakdown, store_po_number, requested_by)
  values (p_wo, n, p_kind, round(p_amount, 2), trim(p_description), p_breakdown, nullif(trim(p_store_po_number), ''), auth.uid())
  returning * into l;
  if p_photo_ids is not null then
    update photos set po_line_id = l.id where id = any(p_photo_ids) and work_order_id = p_wo;
  end if;
  select * into s from sites where id = w.site_id;
  total := _total_with(l.id);
  if w.priority = 1 and s.emergency_limit is not null and total <= s.emergency_limit then
    -- Pre-approved by the customer's own emergency limit: work continues, the customer is told at once.
    update po_lines set emergency_preapproved = true where id = l.id;
    l := _finalize_po_line(l.id, true, null, null, null, 'the customer''s pre-approved emergency limit');
    perform _notify_customer(p_wo, 'approval_granted', format(
      'EMERGENCY call #%s: %s ($%s — %s) went ahead under your $%s pre-approved emergency limit. Call total now up to $%s.',
      w.number, po_label(p_wo, n), l.amount, l.description, s.emergency_limit, total), 'em_pre:' || l.id);
    return l;
  end if;
  if w.status in ('on_site') then perform _set_status(p_wo, 'awaiting_approval'); end if;
  perform _raise_flag(p_wo, 'po_exceeded', format('%s requested: $%s — %s', po_label(p_wo, n), l.amount, l.description), false);
  perform _route_po_line(l.id);
  return l;
end $$;

-- A quote from estimated hours + parts from the list. The amount is calculated, never typed.
create or replace function request_quote(p_wo uuid, p_hours numeric, p_parts jsonb, p_description text,
  p_photo_ids uuid[] default null) returns po_lines
language plpgsql security definer set search_path = public as $$
declare w work_orders; rate numeric; cov record; pt jsonb; prow parts; q numeric; price numeric;
        lines jsonb := '[]'; parts_total numeric := 0; labor numeric; v_kind po_line_kind;
begin
  select * into w from work_orders where id = p_wo;
  if coalesce(p_hours, 0) < 0 then raise exception 'Hours cannot be negative.'; end if;
  rate := _labor_rate_eff(p_wo);
  select * into cov from _coverage(p_wo);
  labor := round(coalesce(p_hours, 0) * rate, 2);
  for pt in select * from jsonb_array_elements(coalesce(p_parts, '[]')) loop
    select * into prow from parts where id = (pt->>'part_id')::uuid and contractor_id = w.contractor_id;
    if prow.id is null then raise exception 'Unknown part in the quote.'; end if;
    q := coalesce((pt->>'qty')::numeric, 1);
    price := case when cov.parts then 0 else round(part_price(prow.id) * (1 - cov.parts_disc / 100), 2) end;
    parts_total := parts_total + round(price * q, 2);
    lines := lines || jsonb_build_object('part_id', prow.id, 'name', prow.name, 'qty', q, 'price', price);
  end loop;
  if labor + parts_total <= 0 then raise exception 'Add hours or parts for the quote.'; end if;
  v_kind := case when exists (select 1 from po_lines l where l.work_order_id = p_wo and l.kind = 'repair') then 'additional' else 'repair' end;
  return request_po_line(p_wo, v_kind, labor + parts_total, p_description,
    jsonb_build_object('labor_hours', p_hours, 'labor_rate', rate, 'labor', labor, 'parts', lines, 'parts_total', parts_total),
    null, p_photo_ids);
end $$;

-- A part that would take the call over the approved limit can't be added until more is approved.
create or replace function set_part_used(p_visit uuid, p_part uuid, p_qty numeric, p_source part_source default 'truck')
returns work_orders language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); w work_orders; before_qty numeric; cap numeric; k record;
begin
  perform _on_site(v);
  select * into w from work_orders where id = v.work_order_id;
  if not exists (select 1 from parts where id = p_part and contractor_id = w.contractor_id) then
    raise exception 'Unknown part.';
  end if;
  select coalesce(sum(quantity), 0) into before_qty from parts_used where work_order_id = w.id and part_id = p_part and source = p_source;
  perform _upsert_part(w.id, v.id, p_part, p_qty, p_source);
  cap := effective_cap(w.id);
  if cap is not null and p_qty > before_qty then
    select * into k from compute_costs(w.id, now());
    if k.total > cap then
      raise exception 'Adding this part takes the call to $% — over the approved $%. Request more first.', k.total, cap;
    end if;
  end if;
  if p_qty > 0 then
    perform _allow_internal(); update work_orders set no_parts_used = false where id = w.id; perform _end_internal();
  end if;
  perform _apply_summary(w.id);
  return recalc_work_order(w.id);
end $$;

-- ---------- What the phone downloads (and keeps for no-signal work) ----------
create or replace function tech_jobs() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); jobs jsonb; cat jsonb; clock jsonb;
begin
  if m.id is null or not m.is_technician then raise exception 'Technicians only.'; end if;
  select coalesce(jsonb_agg(j order by (j->>'sort')), '[]') into jobs from (
    select jsonb_build_object(
      'sort', case v.status when 'on_site' then '0' when 'en_route' then '1' when 'assigned' then '2' else '3' end || coalesce(v.eta_at::text, v.assigned_at::text),
      'visit', jsonb_build_object('id', v.id, 'visit_no', v.visit_no, 'status', v.status, 'assigned_at', v.assigned_at,
         'received_at', v.received_at, 'started_at', v.started_at, 'eta_at', v.eta_at, 'arrived_at', v.arrived_at,
         'checkin_required', v.checkin_required, 'checkin_at', v.checkin_at, 'checkin_verified', v.checkin_verified,
         'completed_at', v.completed_at, 'departed_at', v.departed_at, 'outcome', v.outcome, 'note', v.outcome_note),
      'wo', jsonb_build_object('id', w.id, 'number', w.number, 'kind', w.kind, 'status', w.status, 'priority', w.priority,
         'problem', w.issue_description, 'issue', it.name, 'unit', w.unit, 'contact_name', w.contact_name,
         'contact_phone', w.contact_phone, 'entry_notes', w.entry_notes, 'after_hours', w.after_hours,
         'checklist', w.checklist, 'checklist_results', w.checklist_results, 'repair_type_id', w.repair_type_id,
         'no_parts_used', w.no_parts_used, 'equipment_id', w.equipment_id, 'po_number', coalesce(w.store_po_number, 'PO' || w.number),
         'equipment_type_code', it.equipment_type_code, 'agreement', a.name, 'summary', w.work_summary),
      'site', jsonb_build_object('id', s.id, 'name', s.name, 'address', s.address, 'lat', s.lat, 'lon', s.lon,
         'geofence_ft', s.geofence_radius_ft, 'access_notes', s.access_notes, 'timezone', s.timezone,
         'has_backup_code', s.backup_code_hash is not null),
      'customer', cu.name,
      'equipment', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'type', et.name, 'type_code', et.code,
           'manufacturer', e.manufacturer, 'model', e.model, 'serial', e.serial, 'location', e.location_description,
           'refrigerant', e.refrigerant, 'confirmed', e.identity_confirmed) order by e.id = w.equipment_id desc, et.name), '[]')
         from equipment e left join equipment_types et on et.id = e.equipment_type_id where e.site_id = s.id),
      'warranties', (select coalesce(jsonb_agg(jsonb_build_object('equipment_id', x.equipment_id, 'kind', x.kind,
           'ends_on', x.ends_on, 'description', x.description)), '[]')
         from warranties x join equipment e on e.id = x.equipment_id where e.site_id = s.id and x.ends_on >= current_date),
      'history', (select coalesce(jsonb_agg(h order by h->>'date' desc), '[]') from (
           select jsonb_build_object('number', h.number, 'date', h.completed_at::date, 'summary', h.work_summary) h
           from work_orders h where h.site_id = s.id and h.id <> w.id and h.status in ('completed','invoiced')
           order by h.completed_at desc limit 5) hh),
      'po_lines', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'po', po_label(w.id, l.seq), 'seq', l.seq, 'kind', l.kind,
           'amount', l.amount, 'description', l.description, 'status', l.status, 'owner_status', l.owner_status,
           'emergency', l.emergency_preapproved) order by l.seq), '[]') from po_lines l where l.work_order_id = w.id),
      'parts', (select coalesce(jsonb_agg(jsonb_build_object('part_id', pu.part_id, 'name', pt.name, 'qty', pu.quantity,
           'unit_price', pu.unit_price, 'covered', pu.covered, 'source', pu.source)), '[]')
         from parts_used pu join parts pt on pt.id = pu.part_id where pu.work_order_id = w.id),
      'photos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'visit_id', p.visit_id)), '[]')
         from photos p where p.work_order_id = w.id),
      'parts_orders', (select coalesce(jsonb_agg(jsonb_build_object('description', o.description, 'status', o.status,
           'expected_on', o.expected_on)), '[]') from parts_orders o where o.work_order_id = w.id),
      'meter', _meter(w.id),
      'rules', jsonb_build_object(
         'rate', _labor_rate_eff(w.id), 'min_minutes', c.min_labor_minutes, 'increment', c.labor_increment_min,
         'bill_travel', c.bill_travel_time, 'warn_pct', c.po_warn_pct,
         'trip_eff', case when cov.labor or (w.kind = 'pm' and (cov.pm or w.flat_amount > 0)) then 0 else c.trip_charge end,
         'parts_covered', cov.parts, 'parts_disc', cov.parts_disc, 'flat', w.flat_amount,
         'other_labor', (select coalesce(sum(vv.labor_amount), 0) from visits vv where vv.work_order_id = w.id and vv.id <> v.id and vv.status <> 'cancelled'),
         'other_trips', (select count(*) from visits vv where vv.work_order_id = w.id and vv.id <> v.id and vv.status <> 'cancelled' and vv.arrived_at is not null)))
    as j
    from visits v join work_orders w on w.id = v.work_order_id join sites s on s.id = w.site_id
    join customers cu on cu.id = w.customer_id join contractors c on c.id = w.contractor_id
    left join issue_types it on it.id = w.issue_type_id left join agreements a on a.id = w.agreement_id
    cross join lateral _coverage(w.id) cov
    where v.technician_id = m.id and (v.status in ('assigned','en_route','on_site')
          or (v.status = 'done' and v.completed_at > now() - interval '18 hours'))
  ) x(j);

  select jsonb_build_object(
    'equipment_types', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'trade_id', trade_id) order by trade_id, name), '[]')
       from equipment_types where contractor_id is null or contractor_id = m.contractor_id),
    'repair_types', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'trade_id', r.trade_id,
         'equipment_type_codes', r.equipment_type_codes,
         'kit', (select coalesce(jsonb_agg(jsonb_build_object('part_id', rp.part_id, 'qty', rp.quantity)), '[]') from repair_type_parts rp where rp.repair_type_id = r.id))
         order by r.name), '[]') from repair_types r where r.contractor_id = m.contractor_id and r.active),
    'parts', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name, 'category', p.category,
         'price', part_price(p.id)) order by p.category, p.name), '[]') from parts p where p.contractor_id = m.contractor_id and p.active)
  ) into cat;

  select jsonb_build_object('shift', (select jsonb_build_object('id', id, 'start_at', start_at) from time_entries
            where profile_id = m.id and kind = 'shift' and end_at is null order by start_at desc limit 1),
          'brk', (select jsonb_build_object('id', id, 'start_at', start_at) from time_entries
            where profile_id = m.id and kind = 'break' and end_at is null order by start_at desc limit 1)) into clock;

  return jsonb_build_object('me', jsonb_build_object('id', m.id, 'name', m.full_name, 'phone', m.phone),
    'jobs', jobs, 'catalog', cat, 'clock', clock, 'server_time', now());
end $$;

-- ---------- Security, schedule, photo storage --------------------------------
do $$ declare f text; begin
  foreach f in array array['job_meter(uuid)', 'request_quote(uuid,numeric,jsonb,text,uuid[])', 'tech_jobs()',
    'request_po_line(uuid,po_line_kind,numeric,text,jsonb,text,uuid[])', 'set_part_used(uuid,uuid,numeric,part_source)'] loop
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-meter', '*/5 * * * *', 'select public.meter_watch()');
  end if;
end $$;

-- Photos: private bucket; files live at <work order id>/<photo id>.jpg.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('job-photos', 'job-photos', false, 8388608, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do nothing;
    execute $p$create policy job_photos_read on storage.objects for select to authenticated
      using (bucket_id = 'job-photos' and public.can_see_work_order(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy job_photos_add on storage.objects for insert to authenticated
      with check (bucket_id = 'job-photos' and exists (select 1 from public.visits v
        where v.work_order_id = ((storage.foldername(name))[1])::uuid and v.technician_id = auth.uid()))$p$;
  end if;
end $$;
