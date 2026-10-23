-- New alert type for the owner's Follow-through report (enum values must be added in their own step).
alter type notify_type add value if not exists 'followthrough';
