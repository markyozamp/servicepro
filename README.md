# Service Call Proof

Store-first service dispatch: photo-driven, GPS-verified, zero typing for the tech.
Built for refrigeration / HVAC / all-trade contractors, the stores and homes they serve,
and the wholesalers who refer stores.

## Layout

| Folder | What it is | Status |
|---|---|---|
| `supabase/migrations/` | Database v2: 45 tables, every business rule, security, schedules, catalog | **Live, tested** |
| `supabase/seed.sql` | Demo contractor, stores, homeowner, team, chain, agreement, PM plans | Live |
| `supabase/demo_calls.sql` | Demo calls in every state, created through the real rules | Live |
| `supabase/tests/` | End-to-end scenarios (349 checks) | Passing |
| `web/` | Store portal (`/store`) + contractor office portal (`/office`), Next.js on Vercel | v2 live |
| `web/app/tech` | Technician app — installable web app, works offline | Live |
| `e2e/` | Phone-size browser test of the tech app against the live site | Passing |
| `docs/BUILD_PLAN.md` | Full spec, decisions, fee schedule | Ongoing |

## How the system is built

- **One database (Supabase / Postgres 17) holds every rule.** Apps read through
  row-level security and change things only by calling database functions, so no
  app can skip a step. Guard triggers stop direct edits to statuses and visit times;
  time corrections are logged.
- **Offline-first ids.** Records get their id on the phone, so a tech in a walk-in
  with no signal keeps working and the job syncs later without duplicates.
- **Who sees what:** a tech sees assigned jobs; a store user sees only their
  locations; stores see the ETA but never live location; contractor review flags
  (underbilling etc.) stay internal unless marked visible.
- **Scheduled jobs (pg_cron):** approval escalation every 5 min, billing clock hourly,
  PM generation daily, monthly platform billing.

## Main functions the apps call

| Who | Function | Does |
|---|---|---|
| Store or office | `create_work_order` | Opens a call; issue dropdown sets the diagnosis PO (price list → region → after hours → agreement) |
| Office | `assign_work_order` | Assigns / reassigns / return visit; makes the check-in code |
| Tech | `tech_received`, `tech_start`, `tech_update_eta`, `tech_arrive`, `tech_depart`, `log_gps` | Lifecycle, 5-minute "close" alert, response-time SLA |
| Tech | `tech_checkin` | Code, store backup code, or name-only (flagged) |
| Tech | `confirm_equipment`, `set_repair_type`, `set_part_used`, `set_no_parts_used`, `set_checklist_result` | Equipment history, parts kits, PM checklist |
| Tech / office | `request_po_line` | Lettered POs (A, B, C…) routed by dollar limit and approval chain |
| Store | `decide_po_line` | Approve / decline; over-limit approvals escalate |
| Tech | `tech_finish_visit` | Complete, parts needed, return needed, or quote needed |
| Office | `update_parts_order`, `set_warranty`, `mark_warranty_claim`, `resolve_flag`, `override_time`, `mark_invoiced` | Closeout and billing |
| Office | `offer_agreement` / store `accept_agreement`, `agreement_value` | Maintenance agreements |
| Team | `update_member`, `save_approval_chain`, `set_backup_code`, `set_my_notifications` | Customer teams and chains |
| Tech / office | `clock`, `timesheet`, `approve_timesheet`, `correct_time_entry` | Timecards |
| Platform | `monthly_billing_run`, `mark_statement_paid`, `link_wholesaler` | Fees and wholesaler commission |

## Run the tests locally

Needs PostgreSQL 15+.

```bash
PGHOST=/tmp PGPORT=54329 ./supabase/tests/run.sh
```

## Demo logins

Password for every demo login: `DemoService2026!` — remove the demo list in
`web/app/page.js` before real customers use the site.
