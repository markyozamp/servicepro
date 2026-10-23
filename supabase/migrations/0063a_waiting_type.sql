-- New alert type for "this is waiting on your answer" (reminders and escalations). Own migration: an enum value
-- can't be used in the same transaction that adds it.
alter type notify_type add value if not exists 'waiting';
