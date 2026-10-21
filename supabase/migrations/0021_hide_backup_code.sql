-- The store's backup check-in code (hashed) must not be readable or changeable by app users directly.
-- It is set only through set_backup_code() and checked only inside tech_checkin() (both security definer).
revoke select, insert, update on sites from authenticated, anon;
grant select (id, customer_id, name, address, zip, region_id, lat, lon, geofence_radius_ft, access_notes, require_checkin,
  require_checkout, eta_alert_minutes, timezone, created_at, property_type, owner_id, owner_approval_above, emergency_limit)
  on sites to authenticated;
grant insert (id, customer_id, name, address, zip, region_id, lat, lon, geofence_radius_ft, access_notes, require_checkin,
  require_checkout, eta_alert_minutes, timezone, created_at, property_type, owner_id, owner_approval_above, emergency_limit)
  on sites to authenticated;
grant update (customer_id, name, address, zip, region_id, lat, lon, geofence_radius_ft, access_notes, require_checkin,
  require_checkout, eta_alert_minutes, timezone, property_type, owner_id, owner_approval_above, emergency_limit)
  on sites to authenticated;
