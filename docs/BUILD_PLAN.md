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
| Platform fee | See **Fee schedule** below (replaces the earlier $5-each/$50-cap rule) | Decided by Mark 2026-10-16 |
| Store visibility of tech | **ETA only** — phone reports expected arrival; store is notified first time and when it shifts 15+ min. Store sees arrival/departure times, never the live position | Decided by Mark 2026-10-15 |
| PO warning | 80% of approved amount, configurable per contractor | Decided by Mark 2026-10-15 |
| Invoiced jobs | Locked | Once in QuickBooks, the record is final |

## Positioning (decided by Mark 2026-10-15; store-first added 2026-10-16)
**Store first, contractor second.** The store's experience (arrival/departure notices, ETA, PO caps and approvals, PM visibility) drives design priority; the store protections are in every tier.
- **Known store-side competitors:** ServiceChannel (Fortive) and Corrigo (JLL) are customer-side platforms with technician check-in/out (app, phone IVR, GPS radius). They serve large national chains and require each contractor to work inside each client's portal. **Our gap:** independent and regional grocers, restaurant groups, c-stores and residential — simple and affordable — and the contractor runs their whole business in the same system instead of retyping into each chain's portal. Chains already on ServiceChannel/Corrigo are not early targets.
**ServicePro replaces ServiceTitan for contractors who find it too complex** — and adds what ServiceTitan lacks: customer-side protection (PO caps, the store's own approval chain with dollar limits, PM that stays on the store dashboard until done, meet-on-site check-in codes) and enforced proof of work.
- **Primary market:** stores and contractors **not using ServiceTitan — most likely not using any service software** today (paper, phone, QuickBooks). They need to be productive on day one with no training project.
- **Remaining scope additions are expected to be few**; the goal is one connected source system from call to invoice.
- **Pilot:** a contractor on **QuickBooks**, not on ServiceTitan (Mark will find one). QuickBooks link built first for whichever QuickBooks version that contractor runs.
- **Simplicity guardrails** (so the feature list doesn't recreate ServiceTitan's complexity): one main screen per role; sensible defaults so a contractor is running the first day; advanced features (escalation chains, job costing, install boards) stay hidden until turned on; nothing a tech does needs typing that a tap or photo can replace.
- **Later, for switchers:** import from ServiceTitan (customers, sites, equipment, history) so leaving it is painless.

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
- **Approval escalation by dollar amount — decided by Mark 2026-10-15.** E.g. store manager approves up to $500, maintenance manager up to $2,500, director above that; a request over a person's limit goes up the chain automatically. **The customer edits the chain and the rules themselves:** who is in it, the order, each person's limit, and which stores it covers (a different chain per region is allowed). Rule options to include:
  - time-based escalation: if nobody answers within N minutes, it moves up (a tech is waiting on site),
  - emergency rule: priority-1 calls can go straight to a named person,
  - a backup approver for each step (vacations, days off).
  - Every approval records who approved, at what limit, and when.
- **Notifications per person:** who gets texted for arrivals, approvals, overdue PM, completions.
- **The customer's admin invites people by email**; no involvement from us or the contractor.
- The same team model applies on the contractor side (owner, office, dispatchers, techs).
This is part of the generalization step done first, since the current two customer roles would otherwise have to be migrated later.

### 4. Meet-on-site and "5 minutes away" alert (Mark, 2026-10-15)
- **Meet-on-site required** — an option per call, with a default per store: the technician must check in with a store person on arrival before starting work (and, optionally, check out with them before leaving). The person met is recorded on the call with the time.
- **Verification: check-in code — decided by Mark 2026-10-15.** The store person gets a 4-digit code for that call (portal + text) and reads it to the tech, who enters it.
- **Backup plan when systems are down — layered, never strands the tech:**
  1. *Tech's phone has no signal* (walk-in, basement, rural): the tech enters the code anyway; the app saves it with the phone's time and the server checks it when the phone reconnects. The phone never holds the correct code, so it can't be guessed from the app. A wrong code raises a review flag and notifies the store.
  2. *Store person can't open the portal* (store internet down): the code also goes by text message, which often gets through when data doesn't.
  3. *No per-call code reachable at all:* each store keeps a **standing backup code** the store sets and can change (kept on the manager's sheet). Using it is recorded as "backup code used".
  4. *Nothing works:* the tech enters the name of the person met and a reason. Work continues (a failed walk-in can't wait), but the call is flagged for review and the store sees exactly what happened.
- **"Tech is 5 minutes away" alert** to the store person, from the phone's ETA (fits the ETA-only rule — the store still never sees live location). The 5 minutes is adjustable per store, and who receives it is set in each person's notification choices.
- The alert needs the tech app to report ETA every few minutes while driving; delivery by text/push comes with the notifications phase.

### 5. Technician app works fully with no service (Mark, 2026-10-15)
Compressor rooms, basements, walk-ins, rooftops behind steel: the tech must still see and do everything.
- **Everything for the tech's jobs is downloaded to the phone ahead of time** — the moment a job is assigned, and refreshed whenever there's signal: call details and problem description, site address and access notes, store contacts, PO/cap, the equipment record and its **full service history** (past calls, repairs, parts), PM checklists, and the contractor's repair types and parts catalog.
- **All actions work offline:** start, arrive, check-in code, photos, equipment confirmation, repair type, parts, notes, approval request, complete. They queue on the phone in order and sync automatically when signal returns. Nothing is lost if the app is closed or the phone restarts.
- **The screen always shows sync status:** "All synced", or "3 changes waiting to send — last synced 10:42". The tech never has to guess.
- **Changes made by the office while the tech is offline** (reassignment, cap raised, notes) show up on reconnect with a clear notice.
- **Honest limit:** a job assigned while the tech is already in a dead zone reaches the phone only when it gets signal — so the office sees "not yet received by tech" on the dispatch board.
- Cached job data on the phone is encrypted and cleared after the job closes (or on sign-out).

### 6. Multi-visit jobs, waiting for parts, quotes, install handoff, job costing (Mark, 2026-10-15)
- **A job can take several visits.** The model changes from "one call = one trip" to **job → visits**. Each visit has its own tech, check-in, arrival/departure, labor and photos; the job carries the totals. (Model change done before real data exists.)
- **Waiting for parts is an open status, never a closed one.** The tech marks "parts needed" with the part, supplier and expected date. The job stays open and visible on the store and office dashboards — with how long it has been waiting — until the return visit completes it. The store sees the expected date; overdue parts are flagged.
- **Repair quotes / job estimates.** Tech or office builds a quote: parts, labor hours, optional good/better/best options, photos of the problem. The customer approves through the same approval chain (dollar limits, escalation). An approved quote becomes the return visit or a new job, with the quoted amount as its cap.
- **Service call → install handoff.** When a repair becomes a replacement, the service job hands off to the install team as a **linked install job** carrying everything: equipment record, photos, readings, notes, the approved quote. The install team gets its own board; the store sees one connected history.
- **Job costing.** Every job tracks **quoted vs actual**: labor hours at the tech's cost rate, parts at cost, and the billed amount — so the contractor sees margin per job, per tech and per customer, and installs show budget vs actual as they progress.

### 7. Diagnosis PO → lettered not-to-exceed POs (decided by Mark 2026-10-16)
- **One PO number, lettered increases:** PO1100 = diagnosis; PO1100A = repair (not-to-exceed); PO1100B = additional repair (e.g. the repair revealed the original cause of failure); then C, D…
- Each letter carries: reason category (repair / additional failure found / parts price change / after-hours / other), photos, amount, and who approved it at what limit and when (through the escalation chain).
- Guardrail: past a set number of letters (default: C), the request goes to the maintenance manager automatically regardless of amount.
- Stores whose accounting needs separate PO numbers can enter their own number on any letter; lettered format is the default.
- The tech cannot exceed the current approved total; the invoice shows each letter's amount.

### 8. Issue dropdown with preset diagnosis amounts (decided by Mark 2026-10-16)
The store picks the problem from a list ("Walk-in freezer down", "Self-contained 2-door cooler down", "No heat"…); the system sets the diagnosis PO amount, priority and suggested equipment type. Layers:
1. **Platform price list** — issue → default diagnosis amount + priority; Mark edits it from an admin screen (e.g. walk-in cooler/freezer down $250; self-contained 2-door cooler down $125).
2. **Regional adjustment by %** — a small number of cost regions assigned by zip code (e.g. Los Angeles +40%, Cedar Rapids 0%).
3. **After-hours multiplier** — nights, weekends, holidays.
4. **Optional store–contractor agreement override.**
- The amount is what the **store authorizes**, not a price contractors must charge; contractors bill actual up to it. (Have a business attorney review platform-wide amounts before launch.)
- Later: set defaults from real completed-call data by issue and region.

### 9. Maintenance agreements (Mark, 2026-10-16)
For stores that already have an agreement with their contractor — and those that set one up because of the platform.
- **Agreement record:** term dates, covered sites and equipment, monthly/quarterly/annual fee, and coverage type: PM only; PM + labor; full coverage (PM, labor and parts); with discounted rates for anything not covered.
- **Response-time commitments** (e.g. emergency 4 hrs, normal next business day) tracked on every call and shown to the store: "Arrived in 2 h 10 m — within your 4-hour agreement." Misses are counted.
- **Calls price themselves from the agreement:** covered work shows $0 or the discounted rate; the diagnosis amount comes from the agreement when one applies.
- **PM in the agreement is scheduled automatically** and follows the PM-stays-on-dashboard rule.
- **Agreement fee invoiced automatically** to QuickBooks on schedule.
- **Store value report:** what the agreement covered vs. what it would have cost without it.
- **Easy setup in the platform:** standard agreement templates the contractor offers in-app; the store accepts through its approval chain. Renewal reminders before expiry.
- Basic agreements (coverage, response times, PM, billing) are in **Base**; the CRM side (agreement sales pipeline, renewal campaigns) is Enterprise.

### 10. Repair warranties (Mark, 2026-10-16)
- **Dropdown at closeout** (usually by the office/billing person): warranty term picked from a list — 90 days, 6 months, 1 year, 5 years, other. **Labor and parts are separate** (e.g. 90-day labor, 1-year parts, 5-year compressor). Each repair type pre-fills its usual terms so most closeouts are one click; the contractor edits its own list.
- **Warranty attaches to the equipment and the parts installed**, with start and end dates.
- **Automatic warning on any new call for that equipment while under warranty** — shown to the store when opening the call, on the dispatch board, and in the tech app: "Compressor replaced 3/12/2026 — parts under warranty until 3/12/2031; labor warranty expired."
- The contractor marks the call warranty / not warranty; **declining requires a reason the store can see.**
- Store dashboard: warranty list per store and unit, with end dates.

### 11. Billing deadline: invoice within 7 days (Mark, 2026-10-16)
Stores get surprised by bills sent months after the work and may have budgeted for something else.
- **The store sees the expected amount the moment work is completed** ("Completed — bill pending, about $582"), so it can budget even before the invoice arrives.
- **Invoice must go out within 7 days of completion** (default; adjustable per agreement). Day 5: reminder to the contractor. Day 7: overdue alert to **both** store and contractor, shown on both dashboards until the invoice is sent — it cannot be dismissed.
- The clock keeps running while review flags are open, so the contractor resolves them in time.
- Stores see each contractor's on-time billing record.

### 12. Fee schedule (decided by Mark 2026-10-16) — starting numbers, tested in the pilot
**Store**
| Plan | Monthly | Per use |
|---|---|---|
| Store | $0 | $5 per PO (diagnosis, every letter and every return visit included); completed PM visit $3; scheduled PM, quotes, warranty lookups free. All store protections included. |
| Store Multi | ~$29 per location | Same per-use fees; adds multi-contractor view, cross-store escalation chains, spend and contractor-performance reports, agreement value reports. |

**Contractor**
| Plan | Monthly | Per use |
|---|---|---|
| Base | $0 | $5 per PO, PM $3 — **capped at $40 per active tech per month** |
| Pro | +$25 per active tech | Full estimating, install handoff, job costing |
| Enterprise | Quote | CRM, multi-branch, ServiceTitan import |
- "Active tech" = completed at least one job that month.
- Residential: the contractor pays the $5; the homeowner pays nothing.
- Quotes are free; the fee applies when an approved quote becomes a PO.
- Pilot: free for both sides for 90 days.
- Billed monthly by card or bank draft (Stripe); no card required until the first bill.

### 13. Wholesaler commission — automatic (decided by Mark 2026-10-16)
- A store is tied to the wholesaler that brought it in, through the wholesaler's invite link or code at signup.
- Commission: 15–20% of that store's platform fees, **calculated automatically each month on fees actually collected** (net of refunds), for as long as the store stays on.
- **Paid automatically** through Stripe Connect transfers when the monthly billing run completes; the wholesaler gets a portal page with its stores, fees and payouts.
- Confirm tax reporting (1099s) with an accountant before the first payout.

### 14. Temperature monitoring (Mark, 2026-10-16)
Proof of temperature for bad-product claims, and early warning before product is lost.
- **Simple wireless sensors**, one per space to start: walk-in coolers/freezers, produce prep room coolers and cases (produce is the top concern); restaurants: cooler and freezer.
- **Every reading is recorded**; alarms (out of range for N minutes) go to the people the store chooses, using the same notification settings.
- **Alarms connect to service:** a sustained alarm can open a service call to the store's contractor automatically, with the temperature graph attached. The contractor also sees slow drift before failure.
- **Product-claim reports:** a temperature log for any space and date range, exportable for the wholesaler, insurer or health inspector.
- **Battery changes scheduled automatically** like a PM item, plus a low-battery alert.
- **Hardware: buy and resell an existing vendor's sensors — do not build hardware.** Requirements: lithium batteries with multi-year life; a **cellular gateway** so it doesn't depend on store Wi-Fi or IT; an API or webhook so readings flow into the platform. Candidate to evaluate: Monnit (cellular and Ethernet gateways, 7–10 year sensor batteries, published APIs).
- **Pricing models:** buy outright, or rent-to-own; the wholesaler can also buy for its stores. Monitoring service priced monthly per sensor.
- **Timing:** after the pilot; hardware brings shipping, installation and replacement support.

### 15. Timecards (Mark, 2026-10-16)
- **Tech clocks in and out from the app** (works offline); breaks recorded.
- **The day fills itself in** from the job records: drive time, on-site time per job (from GPS arrival/departure), and shop time.
- **Office approves the week**; corrections are logged with a reason, like time overrides.
- **Overtime calculated**, and approved hours export to QuickBooks for payroll, with hours tied to jobs for job costing.

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
