-- Flag for a visit that happened during a location's busy hours (emergency)
alter type flag_type add value if not exists 'busy_hours_visit';
