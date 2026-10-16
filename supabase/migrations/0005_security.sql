-- =====================================================================
-- ServicePro v2 — who can see what (row-level security) and which
-- actions each signed-in person may call. Writes go through functions.
-- =====================================================================

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon;

grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;

-- Direct writes allowed (row-level security narrows them further)
grant update (issue_description, priority, store_po_number) on work_orders to authenticated;
grant insert on photos to authenticated;
grant update (read_at) on notifications to authenticated;
grant update (full_name, phone) on profiles to authenticated;
grant insert, update on equipment, parts, repair_types, warranty_terms, pm_plans, pm_plan_parts to authenticated;
grant insert (customer_id, name, address, zip, region_id, lat, lon, geofence_radius_ft, access_notes, require_checkin,
              require_checkout, eta_alert_minutes, timezone),
      update (name, address, zip, region_id, lat, lon, geofence_radius_ft, access_notes, require_checkin,
              require_checkout, eta_alert_minutes, timezone) on sites to authenticated;   -- backup code: set_backup_code only
grant delete on repair_type_parts, pm_plan_parts to authenticated;
grant insert on repair_type_parts to authenticated;
grant update (name, phone, email, labor_rate, after_hours_labor_rate, min_labor_minutes, labor_increment_min,
              bill_travel_time, trip_charge, parts_markup_pct, po_warn_pct, billing_days) on contractors to authenticated;
grant update (name, phone, email, letter_escalation_at) on customers to authenticated;

-- The actions the apps call
do $$ declare f text; begin
  foreach f in array array[
    'me()', 'can_see_work_order(uuid)', 'can_see_site(uuid)', 'effective_cap(uuid)', 'compute_costs(uuid,timestamptz)',
    'diagnosis_amount(uuid,uuid,uuid,timestamptz)', 'is_after_hours(uuid,timestamptz)', 'po_label(uuid,int)', 'part_price(uuid)',
    'create_work_order(uuid,uuid,text,uuid,smallint,text,wo_kind,uuid,boolean,uuid)', 'cancel_work_order(uuid,text)',
    'assign_work_order(uuid,uuid,text)',
    'tech_received(uuid,timestamptz)', 'tech_start(uuid,timestamptz,double precision,double precision)',
    'tech_update_eta(uuid,timestamptz)', 'tech_arrive(uuid,timestamptz,double precision,double precision,text)',
    'tech_checkin(uuid,checkin_method,text,text,text,timestamptz,boolean)',
    'tech_depart(uuid,timestamptz,double precision,double precision)', 'log_gps(jsonb)',
    'confirm_equipment(uuid,text,text,text,text,text,uuid,text)', 'set_repair_type(uuid,uuid,boolean)',
    'set_part_used(uuid,uuid,numeric,part_source)', 'set_no_parts_used(uuid,boolean)',
    'set_checklist_result(uuid,int,boolean,text,uuid)',
    'request_po_line(uuid,po_line_kind,numeric,text,jsonb,text,uuid[])', 'decide_po_line(uuid,boolean,text)',
    'completion_check(uuid,timestamptz)',
    'tech_finish_visit(uuid,visit_outcome,text,jsonb,timestamptz,double precision,double precision)',
    'update_parts_order(uuid,parts_order_status,text,date)', 'set_warranty(uuid,uuid)', 'mark_warranty_claim(uuid,boolean,text)',
    'resolve_flag(uuid,text)', 'override_time(uuid,text,timestamptz,text)', 'mark_invoiced(uuid,text)', 'invoice_payload(uuid)',
    'offer_agreement(uuid,text,date,date,coverage_kind,numeric,fee_interval,boolean,uuid[],int,int,numeric,numeric,numeric)',
    'accept_agreement(uuid)', 'mark_agreement_fee_invoiced(uuid)', 'agreement_value(uuid)',
    'update_member(uuid,text,jsonb,uuid[],boolean)', 'set_my_notifications(jsonb)', 'set_backup_code(uuid,text)',
    'save_approval_chain(uuid,text,boolean,uuid[],int,uuid,jsonb)',
    'clock(text,timestamptz,uuid,text)', 'timesheet(uuid,date)', 'approve_timesheet(uuid,date)',
    'correct_time_entry(uuid,timestamptz,timestamptz,text)', 'link_wholesaler(uuid,text)',
    'monthly_billing_run(date)', 'mark_statement_paid(uuid)',
    -- used inside row-level security policies (they run as the caller)
    'is_platform_admin()', 'is_contractor_member(uuid)', 'is_contractor_office(uuid)', 'is_contractor_dispatcher(uuid)',
    'is_customer_member(uuid)', 'is_customer_admin(uuid)', 'profile_sees_site(uuid,uuid)'] loop
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- ---------- Platform catalog: everyone signed in can read ------------
create policy read_all on trades           for select using (true);
create policy read_all on cost_regions     for select using (true);
create policy read_all on region_zip3      for select using (true);
create policy read_all on issue_types      for select using (true);
create policy read_all on platform_settings for select using (true);
create policy read_all on holidays         for select using (true);
create policy read_types on equipment_types for select using (contractor_id is null or is_contractor_member(contractor_id)
  or exists (select 1 from customer_contractors cc where cc.contractor_id = equipment_types.contractor_id and is_customer_member(cc.customer_id)));

-- ---------- Organizations --------------------------------------------
create policy read_own on wholesalers for select using (is_platform_admin()
  or exists (select 1 from profiles p where p.id = auth.uid() and p.wholesaler_id = wholesalers.id));

create policy read_c on contractors for select using (is_platform_admin() or is_contractor_member(id)
  or exists (select 1 from customer_contractors cc where cc.contractor_id = contractors.id and is_customer_member(cc.customer_id)));
create policy write_c on contractors for update using (exists (select 1 from profiles where id = auth.uid() and contractor_id = contractors.id and is_org_admin));

create policy read_cu on customers for select using (is_platform_admin() or is_customer_member(id)
  or exists (select 1 from customer_contractors cc where cc.customer_id = customers.id and is_contractor_member(cc.contractor_id))
  or exists (select 1 from profiles p where p.id = auth.uid() and p.wholesaler_id = customers.wholesaler_id));
create policy write_cu on customers for update using (is_customer_admin(id));

create policy read_cc on customer_contractors for select using (is_platform_admin() or is_contractor_member(contractor_id) or is_customer_member(customer_id));

create policy read_sites on sites for select using (can_see_site(id));
create policy write_sites on sites for all using (is_customer_admin(customer_id)
  or exists (select 1 from customer_contractors cc where cc.customer_id = sites.customer_id and is_contractor_office(cc.contractor_id)))
  with check (is_customer_admin(customer_id)
  or exists (select 1 from customer_contractors cc where cc.customer_id = sites.customer_id and is_contractor_office(cc.contractor_id)));

-- People: yourself, your organization, and the technician on a call you can see
create policy read_profiles on profiles for select using (id = auth.uid() or is_platform_admin()
  or (contractor_id is not null and is_contractor_member(contractor_id))
  or (customer_id is not null and is_customer_member(customer_id))
  or exists (select 1 from visits v where v.technician_id = profiles.id and can_see_work_order(v.work_order_id)));
create policy self_update on profiles for update using (id = auth.uid()) with check (id = auth.uid());

create policy read_ps on profile_sites for select using (profile_id = auth.uid()
  or exists (select 1 from profiles p where p.id = profile_sites.profile_id and p.customer_id is not null and is_customer_member(p.customer_id)));
create policy read_inv on invitations for select using (invited_by = auth.uid()
  or exists (select 1 from profiles p where p.id = invitations.invited_by and (
       (p.customer_id is not null and is_customer_admin(p.customer_id)) or
       (p.contractor_id is not null and exists (select 1 from profiles me where me.id = auth.uid() and me.contractor_id = p.contractor_id and me.is_org_admin)))));

create policy read_chain on approval_chains for select using (is_customer_member(customer_id));
create policy read_chain_sites on approval_chain_sites for select using (exists (select 1 from approval_chains c where c.id = chain_id and is_customer_member(c.customer_id)));
create policy read_chain_steps on approval_chain_steps for select using (exists (select 1 from approval_chains c where c.id = chain_id and is_customer_member(c.customer_id)));

-- ---------- Equipment & catalogs -------------------------------------
create policy read_eq on equipment for select using (can_see_site(site_id));
create policy write_eq on equipment for all using (is_customer_admin(customer_id)
  or exists (select 1 from customer_contractors cc where cc.customer_id = equipment.customer_id and is_contractor_office(cc.contractor_id)))
  with check (is_customer_admin(customer_id)
  or exists (select 1 from customer_contractors cc where cc.customer_id = equipment.customer_id and is_contractor_office(cc.contractor_id)));

create policy read_parts on parts for select using (is_contractor_member(contractor_id)
  or exists (select 1 from customer_contractors cc where cc.contractor_id = parts.contractor_id and is_customer_member(cc.customer_id)));
create policy write_parts on parts for all using (is_contractor_office(contractor_id)) with check (is_contractor_office(contractor_id));

create policy read_wt on warranty_terms for select using (is_contractor_member(contractor_id));
create policy write_wt on warranty_terms for all using (is_contractor_office(contractor_id)) with check (is_contractor_office(contractor_id));

create policy read_rt on repair_types for select using (is_contractor_member(contractor_id)
  or exists (select 1 from customer_contractors cc where cc.contractor_id = repair_types.contractor_id and is_customer_member(cc.customer_id)));
create policy write_rt on repair_types for all using (is_contractor_office(contractor_id)) with check (is_contractor_office(contractor_id));
create policy read_kit on repair_type_parts for select using (exists (select 1 from repair_types rt where rt.id = repair_type_id and is_contractor_member(rt.contractor_id)));
create policy write_kit on repair_type_parts for all using (exists (select 1 from repair_types rt where rt.id = repair_type_id and is_contractor_office(rt.contractor_id)))
  with check (exists (select 1 from repair_types rt where rt.id = repair_type_id and is_contractor_office(rt.contractor_id)));

-- ---------- Agreements & PM ------------------------------------------
create policy read_ag on agreements for select using (is_contractor_member(contractor_id) or is_customer_member(customer_id));
create policy read_ag_sites on agreement_sites for select using (exists (select 1 from agreements a where a.id = agreement_id
  and (is_contractor_member(a.contractor_id) or is_customer_member(a.customer_id))));

create policy read_pm on pm_plans for select using (is_contractor_member(contractor_id) or can_see_site(site_id));
create policy write_pm on pm_plans for all using (is_contractor_office(contractor_id)) with check (is_contractor_office(contractor_id));
create policy read_pm_parts on pm_plan_parts for select using (exists (select 1 from pm_plans p where p.id = pm_plan_id and is_contractor_member(p.contractor_id)));
create policy write_pm_parts on pm_plan_parts for all using (exists (select 1 from pm_plans p where p.id = pm_plan_id and is_contractor_office(p.contractor_id)))
  with check (exists (select 1 from pm_plans p where p.id = pm_plan_id and is_contractor_office(p.contractor_id)));

-- ---------- Jobs and everything on them ------------------------------
create policy read_wo on work_orders for select using (can_see_work_order(id));
create policy edit_wo on work_orders for update using (is_contractor_dispatcher(contractor_id)) with check (is_contractor_dispatcher(contractor_id));

create policy read_visits on visits for select using (can_see_work_order(work_order_id));
-- The check-in code: the STORE only. Not the technician, not the contractor office.
create policy read_codes on visit_codes for select using (exists (
  select 1 from visits v join work_orders w on w.id = v.work_order_id
  where v.id = visit_codes.visit_id and is_customer_member(w.customer_id) and can_see_site(w.site_id)));

create policy read_po on po_lines for select using (can_see_work_order(work_order_id));
create policy read_photos on photos for select using (can_see_work_order(work_order_id));
create policy add_photos on photos for insert with check (uploaded_by = auth.uid() and exists (
  select 1 from visits v where v.work_order_id = photos.work_order_id and v.technician_id = auth.uid()
  and v.status in ('en_route','on_site')));
create policy read_pu on parts_used for select using (can_see_work_order(work_order_id));
create policy read_po_orders on parts_orders for select using (can_see_work_order(work_order_id));
create policy read_overrides on time_overrides for select using (can_see_work_order(work_order_id));
create policy read_warranties on warranties for select using (exists (select 1 from equipment e where e.id = equipment_id and can_see_site(e.site_id)));

-- Review flags: contractor office sees all; the store sees only the ones meant for it
create policy read_flags on guardrail_flags for select using (is_platform_admin() or exists (
  select 1 from work_orders w where w.id = work_order_id and (is_contractor_office(w.contractor_id)
     or (visible_to_customer and is_customer_member(w.customer_id) and can_see_site(w.site_id)))));

-- Location: office sees its techs; a tech sees their own; the store sees arrival/departure events only — never pings
create policy read_gps on gps_logs for select using (technician_id = auth.uid() or is_platform_admin()
  or exists (select 1 from profiles t where t.id = technician_id and is_contractor_office(t.contractor_id))
  or (event <> 'ping' and work_order_id is not null and exists (
        select 1 from work_orders w where w.id = work_order_id and is_customer_member(w.customer_id) and can_see_site(w.site_id))));

create policy own_notes on notifications for select using (user_id = auth.uid());
create policy mark_read on notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- Timecards ------------------------------------------------
create policy read_time on time_entries for select using (profile_id = auth.uid()
  or exists (select 1 from profiles p where p.id = time_entries.profile_id and is_contractor_office(p.contractor_id)));
create policy read_ts on timesheet_approvals for select using (profile_id = auth.uid()
  or exists (select 1 from profiles p where p.id = timesheet_approvals.profile_id and is_contractor_office(p.contractor_id)));

-- ---------- Platform money -------------------------------------------
create policy read_fees on platform_fees for select using (is_platform_admin()
  or (org_kind = 'contractor' and exists (select 1 from profiles p where p.id = auth.uid() and p.contractor_id = org_id and (p.is_org_admin or p.can_bill)))
  or (org_kind = 'customer' and exists (select 1 from profiles p where p.id = auth.uid() and p.customer_id = org_id and (p.is_org_admin or p.can_see_billing))));
create policy read_statements on monthly_statements for select using (is_platform_admin()
  or (org_kind = 'contractor' and exists (select 1 from profiles p where p.id = auth.uid() and p.contractor_id = org_id and (p.is_org_admin or p.can_bill)))
  or (org_kind = 'customer' and exists (select 1 from profiles p where p.id = auth.uid() and p.customer_id = org_id and (p.is_org_admin or p.can_see_billing))));
create policy read_comm on commissions for select using (is_platform_admin()
  or exists (select 1 from profiles p where p.id = auth.uid() and p.wholesaler_id = commissions.wholesaler_id));

create policy read_audit on audit_log for select using (is_platform_admin());

-- Views run as the caller, so the policies above apply to them too
grant select on pm_status, pm_compliance, agreement_fees_due to authenticated;
