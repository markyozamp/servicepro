# ServicePro — Build plan and decisions

Owner: Mark Yozamp. Built and maintained by Mark + Claude.

## Stack (decided)

- **Database, login, photo storage:** Supabase (Postgres)
- **Contractor + customer portals:** Next.js, hosted on Vercel
- **Technician app:** Expo (React Native) — one codebase for iOS and Android
- **AI nameplate reading:** vision model via API, tech confirms the result
- **Accounting:** QuickBooks Online API

Chose a fresh build over forking Atlas CMMS: Atlas is built for one company maintaining
its own equipment, not a contractor/technician/store three-party model, and its Java codebase
is much larger than what two people should maintain.

## Decisions made while building the foundation

| Topic | Decision | Why |
|---|---|---|
| Offline | Phone generates record ids; device timestamps accepted within limits (not in the future, ≤ 7 days old, never before dispatch) | Walk-ins, basements and steel buildings block signal |
| Labor | Billed from **arrival → completion**, rounded up to the contractor's increment, with a minimum (default 60 min in 15-min steps). Drive time billed only if the contractor turns it on | Completion is the tech's act; departure is recorded for the audit trail only |
| Parts | A repair type pre-fills its kit; tech unchecks unused parts. Repairs that need no parts (coil cleaning) are allowed via an explicit "No parts used" tap | Spec required parts on every job, but many real repairs use none |
| Equipment | Model + serial required. Unreadable plate → enter UNREADABLE and photograph it | Never blocks a tech in front of an old unit |
| PO cap | Warning at 80% (configurable). Over the cap blocks completion until the **store** approves. Only the store can approve | Protects the store from surprise bills, which is the point of the cap |
| Time corrections | Only a contractor admin, with a written reason (10+ chars). Logged, flagged, and **visible to the store**. If a correction pushes cost past the approved cap, a blocking flag is raised | Phones die and GPS lags, but corrections must never be silent |
| Review flags | Underbilling, overbilling, parts missing/excess, labor out of range, GPS mismatch. They block QuickBooks export until resolved with a note. Stores never see them | Internal QA for the contractor |
| GPS mismatch | Arrival > 2× the geofence radius from the store, or with no location → flagged for review, never blocks the tech | Honest record without stranding the tech |
| Platform fee | **Both sides pay** $5 per completed call, capped at $50/month each. A fee plan row overrides per organization (e.g. enterprise: per-call, no cap) | Decided by Mark 2026-10-15 |
| Store visibility of tech | **ETA only** — phone reports expected arrival; store is notified first time and when it shifts 15+ min. Store sees arrival/departure times, never the live position | Decided by Mark 2026-10-15 |
| PO warning | 80% of approved amount, configurable per contractor | Decided by Mark 2026-10-15 |
| Invoiced jobs | Locked | Once in QuickBooks, the record is final |

## Scope additions (Mark, 2026-10-15)

### 1. Preventive maintenance (PM) — parts and labor
The problem: contractors forget to do the PM, and stores don't find out until something fails.
Design:
- **PM plans** per store (or per unit): frequency (monthly / quarterly / semi-annual / annual), a task checklist, a parts kit (filters, belts, coil cleaner), expected labor, and pricing (flat per visit or time & materials).
- **The system schedules the PM itself.** A daily job creates the PM work order ahead of the due date; the contractor doesn't have to remember.
- **Every scheduled PM stays on the store manager's dashboard until it is completed** (decided by Mark 2026-10-15) — upcoming, due, and overdue ("PM overdue 12 days"), with text/email when it goes overdue. It cannot be hidden or dismissed; only completion removes it. The contractor sees a PM compliance % per customer.
- **PM visits need proof**, like service calls: checklist items with required photos and readings (e.g. new filter photo, coil before/after, amp draw), parts from the kit.
- Completing a PM schedules the next one from the completion date.

### 2. All trades, residential and commercial
- Trades: refrigeration, HVAC, plumbing, electrical, and others — a **trade** on every repair type, PM plan and work order.
- **Residential:** the customer is a homeowner and the site is the home. No PO numbers; the spending cap becomes an **estimate the homeowner approves** (same approval flow). Payment likely by card rather than net-30 invoice.
- **Equipment types move from a fixed list to a table** each contractor can extend (water heater, panel, sump pump, boiler, etc.).
- Work order **kinds**: service call, PM visit, install, estimate/quote.

### 3. Customer teams: store managers, maintenance managers, directors (Mark, 2026-10-15)
Each customer adds its own people, beyond the store manager — maintenance manager, director of operations, or whoever they choose.
- **Title is the customer's own wording** ("Maintenance Manager", "Director of Operations", "District Manager"); permissions are set separately.
- **Which stores each person sees:** one store, a list of stores/region, or all stores. A store manager sees their store; a maintenance manager or director sees all of them.
- **Permissions per person:** open service calls, approve added cost, manage PM plans, see invoices and spend, add/remove users.
- **Approval limits by dollar amount** (proposed): e.g. store manager approves up to $500, maintenance manager up to $2,500, director above that. A request over a person's limit goes up to the next person automatically.
- **Notifications per person:** who gets texted for arrivals, approvals, overdue PM, completions.
- **The customer's admin invites people by email**; no involvement from us or the contractor.
- The same team model applies on the contractor side (owner, office, dispatchers, techs).
This is part of the generalization step done first, since the current two customer roles would otherwise have to be migrated later.

### Order of work (proposed)
1c Technician app → **PM plans + auto-scheduling** → notifications → AI nameplate reading → QuickBooks → pilot.
The generalization changes (trades, equipment type table, work order kinds, customer teams and permissions) are done first, before real data exists, because they are cheapest now.

### Open questions
- Residential platform fee: does the homeowner pay $5, or the contractor only?
- PM pricing default: flat rate per visit under a contract, or time & materials?

## Phases

- [x] **1a. Database foundation** — schema, rules, security, 42-check test. **Live on Supabase** (project `Servicepro`, us-east-1) since 2026-10-15; smoke-tested end to end on the live database
- [x] **1b. Web portals v1** — live at https://servicepro-two.vercel.app (Vercel project `servicepro`, auto-deploys from GitHub `main`). Sign-in, store portal (new call, approvals, call detail), office dispatch board, review queue, mark invoiced. Demo logins share password `DemoService2026!` — remove the demo list on the sign-in page before real customers
- [ ] **1c. Technician app** — job list, Start/Arrive/Complete, photo capture, checklist, offline queue
- [ ] **2. AI** — nameplate photo → manufacturer/model/serial suggestion
- [ ] **3. Notifications** — push (tech), text/email (store)
- [ ] **4. QuickBooks Online** — Intuit developer app, OAuth connect, invoice export
- [ ] **5. Pilot** — one contractor, two stores
- [ ] **6. Parts photo recognition, truck inventory, polish**

## Accounts Mark will need (when we get there)

GitHub, Supabase, Vercel, Apple Developer ($99/yr), Google Play ($25 one-time),
Intuit Developer (free), and an AI vision API key.
