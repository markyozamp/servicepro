# ServicePro (working name)

Photo-driven, GPS-verified service platform for refrigeration/HVAC contractors,
their technicians, and the stores they serve.

## Layout

| Folder | What it is | Status |
|---|---|---|
| `supabase/migrations/` | Database: tables, business rules, security | **Done, tested** |
| `supabase/seed.sql` | Demo contractor, store, tech, parts, repair types | Done |
| `supabase/tests/` | End-to-end test of a full service call (42 checks) | Passing |
| `web/` | Contractor + customer portals (Next.js) | Next |
| `mobile/` | Technician app (Expo — iOS + Android) | After web |
| `docs/` | Build plan and decisions | Ongoing |

## How the system is built

- **One database (Supabase / Postgres) holds every rule.** The phone and the web
  portals can read what they're allowed to see, but every change goes through
  database functions that enforce the rules. No app can skip a step.
- **Offline-first ids.** Photos and records get their id on the phone, so a tech
  in a walk-in with no signal keeps working and the job syncs later without duplicates.
- **Row-level security** decides who sees what: a tech sees only assigned jobs,
  a store sees only its calls, customers never see the contractor's internal
  review flags (e.g. "underbilling").

## Functions the apps call

| Who | Function | Does |
|---|---|---|
| Store or office | `create_work_order` | Opens a call (optional PO number + $ cap) |
| Office | `assign_work_order` | Assigns/reassigns a tech, notifies tech + store |
| Store or office | `set_po_cap`, `cancel_work_order` | |
| Tech | `tech_start`, `tech_arrive`, `tech_depart` | Lifecycle; times from phone, sanity-checked |
| Tech | `tech_update_eta` | Phone reports expected arrival; store notified on first ETA and 15+ min changes |
| Tech | `log_gps` | Batch upload of location pings |
| Tech | `confirm_equipment` | Model + serial confirmed → builds equipment history |
| Tech | `set_repair_type` | Picks repair; auto-fills parts kit + writes the summary |
| Tech | `set_part_used`, `set_no_parts_used` | Adjust parts (0 = remove) |
| Anyone on the job | `completion_check` | The checklist of what's still missing |
| Tech | `tech_complete` | Completes, or returns the missing list. Runs guardrails + fees |
| Tech / office | `request_approval` | Ask store for $ above the cap |
| Store | `decide_approval` | Approve / decline |
| Office | `resolve_flag`, `override_time` | Review queue; logged time corrections |
| Office / export job | `invoice_payload`, `mark_exported` | QuickBooks hand-off |

## Run the tests locally

Needs PostgreSQL 15+.

```bash
PGHOST=/tmp PGPORT=54329 ./supabase/tests/run.sh
```

## Deploy to Supabase (when ready)

1. Create a Supabase project (free tier is fine for the pilot).
2. Install the Supabase CLI, `supabase link`, then `supabase db push` to apply `supabase/migrations/`.
3. Optionally load `supabase/seed.sql` into a **non-production** project for demos
   (it inserts into `auth.users` with fixed test ids).
