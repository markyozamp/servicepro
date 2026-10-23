-- New flag types (enum values go in their own step)
alter type flag_type add value if not exists 'leased_unit';
alter type flag_type add value if not exists 'crew_mismatch';
