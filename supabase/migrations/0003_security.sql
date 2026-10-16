-- =====================================================================
-- ServicePro — who can see and change what (row-level security)
-- Reads: filtered per role.  Writes: almost entirely through functions.
-- =====================================================================

-- Start from nothing, then grant deliberately.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public;

grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;

-- Direct writes that are allowed (RLS below narrows them further)
grant update (issue_description, priority, scheduled_for, estimated_minutes, po_number, work_summary)
  on work_orders to authenticated;                         -- office edits
grant insert on photos to authenticated;                   -- phone uploads photo rows
grant update (read_at) on notifications to authenticated;  -- mark read
grant update (full_name, phone) on profiles to authenticated;
grant insert, update on sites, equipment, parts, repair_types, repair_type_parts, service_agreements to authenticated;
grant update (name, phone, email, labor_rate, min_labor_minutes, labor_increment_min, bill_travel_time,
              trip_charge, parts_markup_pct, po_warn_pct) on contractors to authenticated;
grant update (name, phone, email) on customers to authenticated;
grant delete on repair_type_parts to authenticated;

-- Functions the apps may call
grant execute on function
  me(), can_see_work_order(uuid), compute_costs(uuid, timestamptz), effective_cap(uuid),
  create_work_order(uuid, text, uuid, uuid, smallint, text, numeric, uuid),
  assign_work_order(uuid, uuid, timestamptz, int),
  set_po_cap(uuid, numeric, text), cancel_work_order(uuid, text),
  tech_start(uuid, timestamptz, double precision, double precision),
  tech_arrive(uuid, timestamptz, double precision, double precision, text),
  tech_depart(uuid, timestamptz, double precision, double precision),
  tech_update_eta(uuid, timestamptz),
  log_gps(jsonb),
  confirm_equipment(uuid, equipment_type, text, text, text, text, uuid, text),
  set_repair_type(uuid, uuid, boolean), set_part_used(uuid, uuid, numeric, part_source),
  set_no_parts_used(uuid, boolean),
  completion_check(uuid, timestamptz), tech_complete(uuid, timestamptz, double precision, double precision),
  request_approval(uuid, numeric, text), decide_approval(uuid, boolean),
  resolve_flag(uuid, text), override_time(uuid, text, timestamptz, text),
  mark_exported(uuid, text), invoice_payload(uuid), part_price(uuid), distance_ft(double precision, double precision, double precision, double precision)
to authenticated;
-- Needed by RLS policies (they run as the caller)
grant execute on function is_contractor_staff(uuid), is_contractor_office(uuid), is_customer_user(uuid),
  is_platform_admin(), has_agreement(uuid, uuid) to authenticated;

-- ---------- Enable RLS everywhere ------------------------------------
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- ---------- Policies -------------------------------------------------
-- Organizations
create policy contractors_read on contractors for select using (
  is_platform_admin() or is_contractor_staff(id)
  or exists (select 1 from service_agreements sa where sa.contractor_id = id and is_customer_user(sa.customer_id)));
create policy contractors_write on contractors for update using (
  exists (select 1 from profiles where id = auth.uid() and contractor_id = contractors.id and role = 'contractor_admin'));

create policy customers_read on customers for select using (
  is_platform_admin() or is_customer_user(id)
  or exists (select 1 from service_agreements sa where sa.customer_id = id and is_contractor_staff(sa.contractor_id)));
create policy customers_write on customers for update using (
  exists (select 1 from profiles where id = auth.uid() and customer_id = customers.id and role = 'customer_admin'));

create policy agreements_read on service_agreements for select using (
  is_platform_admin() or is_contractor_staff(contractor_id) or is_customer_user(customer_id));
create policy agreements_write on service_agreements for all using (is_contractor_office(contractor_id))
  with check (is_contractor_office(contractor_id));

create policy sites_read on sites for select using (
  is_platform_admin() or is_customer_user(customer_id)
  or exists (select 1 from service_agreements sa where sa.customer_id = sites.customer_id and is_contractor_staff(sa.contractor_id)));
create policy sites_write on sites for all using (
  exists (select 1 from profiles where id = auth.uid() and customer_id = sites.customer_id and role = 'customer_admin')
  or exists (select 1 from service_agreements sa where sa.customer_id = sites.customer_id and is_contractor_office(sa.contractor_id)))
  with check (
  exists (select 1 from profiles where id = auth.uid() and customer_id = sites.customer_id and role = 'customer_admin')
  or exists (select 1 from service_agreements sa where sa.customer_id = sites.customer_id and is_contractor_office(sa.contractor_id)));

-- People: yourself, your own organization, and the tech on a job you can see
create policy profiles_read on profiles for select using (
  id = auth.uid() or is_platform_admin()
  or (contractor_id is not null and is_contractor_staff(contractor_id))
  or (customer_id   is not null and is_customer_user(customer_id))
  or exists (select 1 from work_orders w where w.technician_id = profiles.id and is_customer_user(w.customer_id)));
create policy profiles_self_update on profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- Equipment
create policy equipment_read on equipment for select using (
  is_platform_admin() or is_customer_user(customer_id)
  or exists (select 1 from service_agreements sa where sa.customer_id = equipment.customer_id and is_contractor_staff(sa.contractor_id)));
create policy equipment_office_write on equipment for all using (
  exists (select 1 from service_agreements sa where sa.customer_id = equipment.customer_id and is_contractor_office(sa.contractor_id))
  or exists (select 1 from profiles where id = auth.uid() and customer_id = equipment.customer_id and role = 'customer_admin'))
  with check (
  exists (select 1 from service_agreements sa where sa.customer_id = equipment.customer_id and is_contractor_office(sa.contractor_id))
  or exists (select 1 from profiles where id = auth.uid() and customer_id = equipment.customer_id and role = 'customer_admin'));

-- Contractor catalogs (customers can read part names on their invoices)
create policy parts_read on parts for select using (
  is_contractor_staff(contractor_id)
  or exists (select 1 from service_agreements sa where sa.contractor_id = parts.contractor_id and is_customer_user(sa.customer_id)));
create policy parts_write on parts for all using (is_contractor_office(contractor_id)) with check (is_contractor_office(contractor_id));

create policy repair_types_read on repair_types for select using (
  is_contractor_staff(contractor_id)
  or exists (select 1 from service_agreements sa where sa.contractor_id = repair_types.contractor_id and is_customer_user(sa.customer_id)));
create policy repair_types_write on repair_types for all using (is_contractor_office(contractor_id)) with check (is_contractor_office(contractor_id));

create policy kit_read on repair_type_parts for select using (
  exists (select 1 from repair_types rt where rt.id = repair_type_id and is_contractor_staff(rt.contractor_id)));
create policy kit_write on repair_type_parts for all using (
  exists (select 1 from repair_types rt where rt.id = repair_type_id and is_contractor_office(rt.contractor_id)))
  with check (exists (select 1 from repair_types rt where rt.id = repair_type_id and is_contractor_office(rt.contractor_id)));

-- Work orders and their children
create policy wo_read on work_orders for select using (can_see_work_order(id));
create policy wo_office_update on work_orders for update using (is_contractor_office(contractor_id))
  with check (is_contractor_office(contractor_id));

create policy photos_read on photos for select using (can_see_work_order(work_order_id));
create policy photos_insert on photos for insert with check (
  uploaded_by = auth.uid() and exists (
    select 1 from work_orders w where w.id = work_order_id and w.technician_id = auth.uid()
    and w.status in ('en_route','on_site','awaiting_approval')));

create policy parts_used_read on parts_used for select using (can_see_work_order(work_order_id));
create policy approvals_read  on approvals  for select using (can_see_work_order(work_order_id));
create policy overrides_read  on time_overrides for select using (can_see_work_order(work_order_id));

-- Review flags are the contractor's internal QA — customers never see "underbilling".
create policy flags_read on guardrail_flags for select using (
  is_platform_admin() or exists (select 1 from work_orders w where w.id = work_order_id and is_contractor_office(w.contractor_id)));

-- Location: office sees its techs; tech sees own; customer sees only arrival/departure events on its jobs.
create policy gps_read on gps_logs for select using (
  technician_id = auth.uid() or is_platform_admin()
  or exists (select 1 from profiles t where t.id = technician_id and is_contractor_office(t.contractor_id))
  or (event <> 'ping' and work_order_id is not null and exists (
        select 1 from work_orders w where w.id = work_order_id and is_customer_user(w.customer_id))));

create policy notifications_own on notifications for select using (user_id = auth.uid());
create policy notifications_mark_read on notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Fees: each org sees its own; platform admin sees all
create policy fee_plans_read on fee_plans for select using (
  is_platform_admin()
  or (org_kind = 'contractor' and is_contractor_office(org_id))
  or (org_kind = 'customer' and exists (select 1 from profiles where id = auth.uid() and customer_id = org_id and role = 'customer_admin')));
create policy platform_fees_read on platform_fees for select using (
  is_platform_admin()
  or (org_kind = 'contractor' and is_contractor_office(org_id))
  or (org_kind = 'customer' and exists (select 1 from profiles where id = auth.uid() and customer_id = org_id and role = 'customer_admin')));

create policy audit_read on audit_log for select using (is_platform_admin());
