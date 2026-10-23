-- Sites use column-level read grants; the apps read busy hours directly
grant select (busy_hours) on sites to authenticated;
