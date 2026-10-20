-- ServicePro 0019 — Keep a single link from a visit to a person (the technician), so the apps' lists of visits
-- with the technician's name keep working. scheduled_by stays as a plain id (who scheduled the trip).
alter table visits drop constraint if exists visits_scheduled_by_fkey;
