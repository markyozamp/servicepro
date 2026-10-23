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

### 16. Property managers, building owners, one-off homeowners (Mark, 2026-10-16) — built
- **Property management companies are a customer type**, like a grocery chain: properties (residential or commercial), team, dollar-limit chain, PM until done, check-in codes. Calls carry unit/suite and who to meet (tenant, super) with phone and entry notes.
- **Building-owner approval.** Each property can have an owner (not a login) with a dollar limit from the management agreement. When the call's approved total would go over it, the manager's approval is not final: the PO letter waits on the owner. The owner answers from a **no-login link** (one tap, logged with time and device), or the manager records "owner OK'd by phone" with a note. Reminders after the owner's response time (default 24 h). **Emergencies** (priority 1): the manager approves and is reminded to tell the owner. A property the company owns itself has no owner step.
- **One-off homeowners never log in.** The office adds them in one step (name, address, phone) and opens the call. Quotes above the diagnosis are approved from the same no-login link, or the office records a phone approval. The contractor pays the per-call fee; the homeowner pays nothing. Property managers pay store fees.
- Until texting is built, the manager / office copies the link and sends it themselves.

### 17. Not-to-exceed, live cost meter, emergency override (Mark, 2026-10-16) — agreed, build with the tech app
- **A PO amount is a spending limit (not to exceed), not a price** — unless the contractor works flat rate (setting per contractor or repair type; then the letter is the price). Wording everywhere: "Approve up to $480 (not to exceed)", "Approved limit", bill shows "Actual cost $391 — under your $480 limit".
- **Quotes split labor and parts:** tech/office enters estimated hours + parts from the list; the limit is calculated (hours × rate or after-hours rate + parts + trip). Bill shows estimate vs actual for labor and parts separately. Labor is firm (GPS time × contractor's rules); parts are firm (picked from list, photographed).
- **Live meter on the tech's phone** (works offline): limit, used so far, labor + parts. At 80% the phone stops the tech: request the next letter before continuing. Before installing a part the tech adds it; if it would cross the limit, the app asks for the letter first. A server check every 5 minutes alerts office and store even if the phone is off.
- **Over without approval:** the store is never billed above the approved limit unless they approve it; the job can't close or invoice while over.
- **Emergency limit** set by each store/property (e.g. emergencies auto-approved up to $1,500).
- **Waiting for approval (Mark, confirmed):** labor counts for the first 15 minutes, then pauses. The 15 minutes is adjustable per contractor–customer relationship (both must agree).
- **It cannot run over — both sides covered (Mark, confirmed):**
  - **Stop point with a built-in reserve.** The tech is stopped *before* the limit, at 80% or at limit − (approval wait + 15 min wrap-up) × labor rate, whichever comes first. The reserve pays for the wait and for making the equipment safe, so the contractor is paid for every minute and the store never goes over.
  - **Parts that would cross the limit cannot be added** until the next letter is approved.
  - **No answer within the wait time:** the tech makes the equipment safe and leaves; the call goes to "awaiting approval — return visit". Total stays inside the limit.
  - **Billable labor stops at the approved limit.** Minutes past it are recorded but not billable unless approved, so nothing over the limit ever reaches an invoice.
  - **Emergencies:** each store/property sets an emergency limit that is pre-approved (e.g. $1,500). "Emergency: continue" works only up to that pre-approved limit (reason + photo, store told immediately). Above it the request runs up the chain to someone with authority (the chain should end with a no-limit approver); if nobody answers, the tech secures the equipment and stops. No unapproved work, so neither side carries the risk. Override use is reported per contractor.

### 18. Waiting at the door (Mark, 2026-10-16) — built
- **Labor starts at arrival** ("I'm here" or GPS), not at check-in — waiting for the store's code is paid time.
- So the store must not miss it: the moment the tech arrives on a check-in call, everyone at that store is alerted; the store portal shows a **pulsing red banner with the code**, beeps every refresh and pops up a phone/computer notification (once alerts are turned on). If nobody answers it **escalates person by person in the store's own approval-chain order** (Mark, 2026-10-16): **0 min** first person (store manager) → **5 min** second person and their backup (maintenance manager) → **10 min** third person (director) + the contractor office, and the wait is flagged on the call → **15 min** everyone who covers that store. People who don't cover the location are skipped; a store with no chain alerts everyone at once. The tech sees how long they've waited and, after 10 minutes, is pointed to the backup code / name-only check-in.
- When texting is built, the arrival alert also goes out as a text to the store manager's phone.
- **Store guest Wi-Fi (Mark, 2026-10-16):** the store's admin can enter a guest Wi-Fi name + password per location (Location settings). Only the store's people and a technician with an open job there can see it; it's on the tech's job screen even with no signal, with a Copy button. The phone remembers the network, so it reconnects on its own on later visits. A store app version could offer one-tap auto-join (phones always ask once). The same Location settings screen sets the **emergency pre-approved limit** and the **backup check-in code**.
- **Phone clock check (Mark, 2026-10-16):** at every sync the phone reports its clock. More than 2 minutes off → the tech sees a red bar ("set Date & Time to automatic") and the contractor office is told once a day. And no time from the phone can be earlier than that phone's last contact with the server — anything done offline happened after it — so a clock set back can't move arrival or work times earlier. Remaining limit: within an offline stretch the phone's clock is still the source; the store app version could add satellite (GPS) time.
- **Wrong check-in code (Mark, 2026-10-16):** simply try again. A wrong code is never counted as a check-in (the door alarm keeps going). Tries 1–2 just say "wrong code, try again (1 of 3)"; on the 3rd wrong try the store and contractor office are told and it's noted on the call, and the tech is pointed to the store's backup code or "No code available". The right code still works after that and clears the note. With no signal the code is checked when the phone reconnects; if it was wrong, the check-in screen comes back with the message.

### 19. Time Verify — the entry offering (Mark, 2026-10-20) — built 2026-10-20
- **Why:** contractors already on ServiceTitan, Corrigo, etc. won't switch. A store can still **require** them to use ServicePro just to prove the call: who called, when, arrival, departure, check-in.
- **Market position (honest):** store-first platforms exist (ServiceChannel, Corrigo) but they target 100+ location chains, quote-priced, months to set up, and charge contractors per invoice. Independent and regional grocers, c-store groups, restaurants and property managers are underserved. Pitch: "proof that protects both sides," not "catch cheating contractors." Sell to the owner / director who pays the bills.
- **Ladder:** Time Verify (entry) → Base → Pro → Enterprise.
- **Price (Mark, 2026-10-22 — replaces $25/month):** **$295 per location per year, one payment**, unlimited calls, all trades (plumbing, electrical, heating, refrigeration). One price regardless of equipment or call volume (tiers by equipment were considered and dropped: nobody can verify equipment counts online, and stores would under-enter equipment). Multi-location discount when 5+ locations (percent to set). **No free trial** — sold on a demo. **No refunds; cancel anytime to stop renewal**, stated plainly at checkout. Locations added mid-year are prorated to the account's renewal date. **Free for the contractor.** Pro/Enterprise (contractor side) priced per technician. Wholesaler commission applies.
- **What it does:** no double dispatch (any of the contractor's techs taps "I'm going" on the store's open call); tech: "I'm here" (GPS) → check-in code → "Leaving" (done / coming back / waiting for parts), photos optional, ~20 seconds per visit; a failed check-in never blocks payment (name-only fallback). Calls the contractor took by phone → the store confirms. **Invoice check:** invoice total + hours billed vs verified time on site. **Repeat-call flag:** same unit called again within 30 days. Door alarm, phone clock check, ETA all apply.
- **Residential:** supported, not led with. Homeowners never download or sign in — texts with links (on the way + ETA, arrived, finished with photos, quote approval, bill, maintenance reminders), which comes with the texting build. Property managers are the strong residential angle. Start the US carrier texting registration (can take weeks) about a week before building texting.

- **As built (2026-10-20):** the store chooses per contractor: *Time Verify* or *Full*.
  - **Store opens the call as a PO** — its own PO number (or PO + call number), problem from the list, optional not-to-exceed. A PO number can't be reused on an open call.
  - **Routed by trade:** "who gets which kind of call" per store (plumbing → Prairie, refrigeration → Arctic…), else the main contractor.
  - **Contractor alerted, must accept** — "on the way now", a scheduled window, or "can't take it" (store told at once). Not accepted in time (store sets it: 15 min emergency / 4 h other by default) → the store is told with the contractor's phone number, and can send the call to another contractor.
  - **Tech:** the call shows on every tech's phone; first to tap **I'm going** gets it (needs signal, so no double dispatch) → I'm here (GPS) → store's code → **Leaving**: done / coming back / waiting for parts, optional note and photos. **Parts run:** leaving → at the supplier (GPS) → back. Nothing else to fill in.
  - **Contractor-entered phone calls:** entered with who called; the store must confirm (and can add its PO) or say "we didn't request this" — on record for both sides.
  - **"The technician is here but hasn't checked in"** button for the store: records the arrival from the store side (the tech is paid from then), tells the tech and office, and starts the door alarm. If nobody took the call in the app, the office is told.
  - **QR sticker per unit** + store PIN (4–6 digits, 5 wrong tries locks it 15 min): any employee reports a problem with no login; the call knows the unit and who reported; no duplicate within 2 hours. Printable sticker sheet.
  - **Invoice check:** the contractor must enter the invoice # and total and hours billed (+ other hours with a reason, e.g. shop work). The store sees billed vs verified (on site, travel per "we pay travel: yes / no / after hours only", parts runs), with the contractor's minimum and billing steps applied; unexplained hours and over-the-limit are flagged; the store approves or questions it. The store can type in a paper invoice if the contractor doesn't.
  - **Repeat-call flag** (same unit, or same location + problem, within 30 days). **PO log** with search, flagged-only filter and spreadsheet export.
  - **Sign-in links, no passwords:** the store invites a contractor (link to email/text); the owner adds techs by mobile number → each gets a one-time link that signs that phone in. New link for a new phone.
  - **Alerts:** phone/computer push ("Turn on alerts" button; on iPhone after Add to Home Screen), sent every minute. Email is wired but needs a sending account (Resend) — Mark to sign up. Texting waits for carrier registration.
  - **Billing:** Time Verify calls carry no per-call fee; the store's monthly statement gets $25 × locations (included in Store Multi); the contractor pays nothing.
  - Demo: Prairie Plumbing (demo) — pete@prairieplumbing.demo (owner, goes on calls) and tony@prairieplumbing.demo (tech); store PIN 2468.

- **Every trip announced (Mark, 2026-10-20) — built:** each trip is scheduled with the store before it happens (which tech, day and window, or "going now"); the store is told and sees it under **Expected today** with that trip's code; the tech gets it on his phone plus a 6 am reminder. A tech's own "I'm going" announces a trip happening now. **In the building now** shows every contractor tech checked in, where and since when (safety + security). One-tap log for a visitor the store wasn't expecting (store and contractor office told). Missed window → store + office told, flagged. Store rule for time not verified in ServicePro: review or don't pay; an invoice with no recorded visit is flagged. The contractor agrees to the store's terms when signing in from the invite. Contractor record per store (on-time acceptance, check-ins with code, missed windows, unscheduled visits, unexplained hours). New calls alert the techs too (owner can turn off). Shop work stays as typed hours with a reason on the invoice. Limit: leaving/returning is known from the tech's taps (or the app being open) — background detection needs the store app.
- **Marketing copy** for these reasons (safety, security, proof for both sides, homeowner peace of mind incl. estimate visits) is kept in the project doc "ServicePro — Why It Matters".

### 20. Close-out override (Mark, 2026-10-20) — built
- When a visit can't be finished the normal way (no problem found / fixed before arrival, store closed, customer cancelled, unsafe or unreachable equipment, camera broken, other), the tech closes out **with an override**: pick a reason + explain what happened, then approval:
  - **Office code:** the tech calls the office; the office taps "Give override code" on the call, notes what the tech said, and reads the 6-digit one-time code to the tech.
  - **Owner (sole operator):** a tech who is the company owner approves it themselves by re-entering their password.
- Works from the check-in step too (store closed → can't check in). **Money rules are never overridden:** a pending approval or a cost over the approved limit still has to be handled first.
- The store sees it on the call: "Closed without full documentation — reason: explanation. Approved by Pat Dispatch (office, by phone)." The codes themselves are visible only to the contractor's office.

### 22. Name: Service Call Proof (Mark, 2026-10-20) — decided
- Mark bought servicecallproof.com and servicecallproof.app (2026-10-20). His USPTO search: no live SERVICE CALL PROOF; PROOF OF SERVICE and CALLPROF dead; other live PROOF marks unrelated.
- Rejected: ServicePro (crowded), All Service Flow (live SERVICEFLO, class 42 scheduling SaaS, first use 2023), plus many "Service + word" names (generic or taken). Lesson: "All/The/Pro" never distinguishes a name.
- Still to do before printing: attorney clearance check; file the trademark once in use. Tagline: "Service Call Proof — know who's in your building, and for how long."
- App renamed 2026-10-20; repo/database names unchanged.

### 21. Connections: QuickBooks only (Mark, 2026-10-20) — decided
- **No connections to ServiceTitan, Corrigo, ServiceChannel** or similar. They already do this for big companies; we serve smaller stores and the contractors who serve them. Later, win ServiceTitan users over on price and simplicity (they pay thousands a year and use a small part of it).
- **QuickBooks is the one connection:** invoice straight from ServicePro into QuickBooks (PO number on the invoice, customer matched, labor and parts lines), send the invoice from there, and read payments back. It also feeds job costing and estimating (Pro).
- Time Verify contractors on QuickBooks: invoices created in ServicePro (or read from QuickBooks by PO number) fill the invoice check with no retyping.
- Open: QuickBooks Online (modern connection) vs Desktop (older, harder) — set by the pilot contractor.

### 23. Facility management (FM) package — next after Time Verify (Mark, 2026-10-21) — planned
**Who:** facility management companies that sit between the property owner and the trades — small "CBRE-style" firms (e.g. J&J Worldwide type) running work for many clients or franchisees across the country, hiring subcontractors for MEP **and any other trade** (elevator, parking lot, roofing, general maintenance or construction). Today they schedule and confirm by email and phone. The engine already built for MEP carries over; trade does not matter.

**Three parties:** the **owner** (client / franchisee, decides and pays) ← the **FM** (dispatches, coordinates, bills the owner) → the **subcontractor** (does the work, invoices the FM).

**First release (key things, in Mark's order):**
1. **The call** — the FM sends the call (with PO number) to the sub through the portal; the sub accepts.
2. **Arrival proof** — the tech reports arrival; location captured at that moment (outside the building) + photos of what he found.
3. **Code to start** — the tech gets the check-in code from the FM (calls / requests it in the app); work starts only after check-in. (The FM issues the code remotely, since the FM is usually not at the site.)
4. **Ongoing communication on the call** — diagnosis, why it can't be finished, parts to order, return trips; photos and notes; one thread per call that the FM and sub both see.
5. **PO increase before more work** — the sub requests the next PO amount (the lettered not-to-exceed POs, §7/§17); the FM approves or sends it up to the owner.
6. **Quotes for big work** (e.g. replace a large compressor or condenser after a service call) — photos, findings and the estimate packaged so the FM can **share it with the owner in one link** and the owner can make a good decision (approve / decline).
7. **Bid requests** — for upgrades or projects the FM sends a request for bids to several contractors in the area through the platform; each contractor prepares a bid and sends it back through the portal **as a quotation on the contractor's own letterhead**; the FM compares them and forwards the chosen one(s) to the owner.

**Later (during the FM pilot):** require the contractors to run the whole program on the platform — job costing, estimating, billing through the platform (Base/Pro).

**Already built that this reuses:** customer teams + dollar-limit chains, owner approval by no-login link (§16), lettered NTE POs and quotes, check-in codes, photos, tech app, announced trips / who's in the building, PO log, push alerts.
**New to build:** FM as a customer type that manages many owners' sites nationwide (owner = client org under the FM); any trade in the trade list; FM-issued check-in codes on request; per-call message thread; owner decision package (photos + findings + estimate + options, one link); bid requests to several contractors with side-by-side comparison and award; quotation PDF on the contractor's letterhead (logo, address, terms); subcontractor directory by trade and area.
**Ownership and lanes (Mark, 2026-10-21) — decided:** the FM package is **proprietary and not sold**. It is given to an FM company Mark owns, which builds its own portfolio of owners and subcontractors with it (free for its owners and subs). A **separate arm** sells Service Call Proof (Time Verify → Base → Pro → Enterprise) to stores and contractors; the businesses are run separately. Synergy: subs working for Mark's FM may buy Service Call Proof to run their own shops and serve their own direct customers (e.g. local grocery stores). Build implication: FM features live behind a switch that only Mark's FM company has; they never appear in the Service Call Proof plans. Settle which company owns the software and how it is licensed to each arm.

**Cash flow model (Mark, 2026-10-21) — planned:** owners prepay a **quarterly bucket** that funds their PMs and expected service calls, and get **5% off** for prepaying. Subs are paid **immediately** in exchange for a **5% quick-pay discount**. Net margin is roughly break-even on the discounts (5% off the owner's price vs 5% off the sub's lower cost) but the FM never floats sub payments. Software needed: bucket ledger per owner (deposits, draws per invoice, balance), low-balance alert and top-up request, quarter-end statement and true-up (roll over or refund — to decide), quick-pay option per sub, payouts tracked. Funding by **payment method on file in Stripe** (Mark, 2026-10-21): bank debit (ACH) preferred for the quarterly bucket (low fee, capped); card accepted with the card fee priced in. Owners who won't prepay: card/bank on file charged automatically when each invoice is approved (still fast cash, no discount). Check with a CPA: prepaid funds are unearned revenue / held funds — accounting, refunds of unused balance, any state rules.

**"Nothing slips" board (Mark, 2026-10-21 — the core pain):** FMs today have open work orders "floating around" with nobody minding them. The FM needs one board of every open call across all owners and subs, with aging and automatic nudges: sub hasn't accepted, no arrival by the window, no update in X days, quote waiting on the owner, parts ETA passed, invoice not in. Each stalled call shows who it's waiting on.
**Market check (2026-10-21):** ServiceChannel (clients pay; subs pay 1.5% of each invoice, max $4), Corrigo (JLL) and Fexa (100+ location chains) are enterprise and built around the big chain as the customer. In-house CMMS tools (MaintainX, UpKeep, Limble) don't handle three parties with a hidden markup. Small/mid FM firms are largely on email and spreadsheets. Model: **the FM pays, subs use it free** — getting 100 subs onboard only works if it costs them nothing.
**Before building:** sit down with one of the FMs Mark knows and walk through a week of their real calls.

**Answers (Mark, 2026-10-21):**
- **Markup — yes, hidden from the owner.** The FM adds its markup when it bills or quotes the owner; the owner never sees the sub's price or the markup. Quotes to the owner usually go out **as the FM's quote** (re-issued on the FM's letterhead at the FM's price); sometimes the FM passes **the sub's own quote** through instead. Both options needed, per quote.
- **Owner sees the FM, not the sub (most of the time).** Bids, quotes and billing reach the owner from the FM. Rarely the owner sees a sub's bid directly — allow it as an exception the FM chooses.
- **Compliance tracking with expiry alerts — yes, required before dispatch.** The FM's contract with each sub covers this on paper; the dispatch system must track the dates and alert before things expire:
  - company level: insurance certificates (general liability, workers' comp, auto, etc.), trade licenses (by state);
  - person level: each tech's driver's license expiry, any site/base access credentials;
  - vehicle level: plate number and **registration expiry** for every vehicle that enters secured sites (military bases — Air Force, Army — turn away expired plates or licenses);
  - **base access requests**: some bases need advance notice that company X / tech Y / vehicle Z is coming in a set window — the system should prompt and track those.
  - Dispatch to a site flagged "secured" warns or blocks when the company, tech or vehicle has anything expired. **To discuss further with Mark: the exact list of items and what blocks vs. warns.**
- **Pricing for FMs:** leaning toward **per location** (not per call), possibly tied to an opening PO amount per location. Needs a short discussion.

### 24. Construction — residential and light commercial (Mark, 2026-10-21) — parked, long term
- Idea: the same verified-visit engine for builders/remodelers and small commercial (dental, clinics, franchise buildouts): each trade's arrival verified; when one trade misses or is late (excavator, insulation) the next trade is warned before he drives out; owner/homeowner sees the day; sub bid collection with plans in the portal; contractor's own estimate and proposal; permits, insurance, draws, sub payments in one project file; optional jobsite cameras (drones later — cost and FAA rules).
- Assessment: need 8/10; head-on vs Buildertrend/JobTread 4/10; as "verified trades + next-trade warning" 7/10. Same engine could also serve landscaping and other service trades later.

### 25. Website with a hands-on demo (Mark, 2026-10-22) — planned, with the marketing website
- The sales site (servicecallproof.com) has a **try-it-yourself demo** right on the page, since there is no free trial: the visitor plays the store.
- Flow: set up a pretend contractor → place a service call → the contractor "accepts" and replies → "Tony is on the way" → arrival alert → the visitor gives the check-in code → parts run → Leaving → invoice checked against the verified time (with one flag to see).
- How: each visitor gets a private throw-away demo store (no sign-up), the contractor side is played automatically on a short timer (seconds, not hours), alerts show on screen (and as a real phone alert if they allow it). Demo data is wiped after a day. Ends with "Buy for $295 per location per year."
- Same engine as the real product, so the demo stays accurate as features change.

### 26. Shakedown list — M&L Market test (Mark, 2026-10-22)
1. Logins: each $295 location includes 1 login, company-wide pool; extra logins $25/yr; admin picks which locations each person sees — **built** (Team tab); buying extra logins by card — placeholder until Stripe.
2. QR sticker page back button — **done**.
3. "Use where I'm standing" explained — **done** (renamed "Fine-tune map point (on site)", refuses rough computer locations; the address sets the map point).
4/6. Store adds its own equipment + warranties; note "Service Call Proof can tag and organize your equipment — contact us for a quote" — **built** (Equipment tab).
5. Backup code: shows who set it and when; explanation of when it's used — **done**.
7. Desktop shortcut: "Install on this computer" in the menu — **done**.
8. Company profile + edit location name/address — **built**.
9. Add store logins — **built** (Team); purchase by card later (Stripe).
10. Contractor "Upgrade" (Base / Pro / Enterprise) — placeholder in menu.
11. Installs / project quotes / bid jobs — placeholder on dashboard; real build with the bid-request feature (§23).
12. ⓘ info bubbles on each section — **done** (Settings tabs, contractor sections).
13. Per-person permissions (admin ticks: open calls, approve + limit, equipment, contractors & QR, locations, team; only admins make admins) — **built**.
14. Equipment who/when: added/changed/warranty/removed stamped with name and time, history per unit; remove needs a reason, restore anytime — **built**.
15. Backups: "Your data" downloads (calls, equipment, team) + restore request at $75 (done by us) — **built**. Needs Supabase Pro for automatic daily backups before promising them.
16. Dashboard: one button per area (Locations, Team, Equipment, Contractors & QR, Company & plan) by permission, beside Install / project quote and New service call — **built**.
17. Unexpected visitor: one-tap "Call their office" — **built**; vehicle plate and photo optional, each location can require them (Locations tab) — **built**.
18. QR stickers: print your own, or "Order stickers from us" (email order for now; in-app ordering later). Later: a small store for useful refrigeration items — **email ordering built**.
19. Getting started: "Hide for now" leaves a "Getting started: N steps left · Show" pill — **built**.
20. Location menu: shows the current location, all others, "+ Add location" (if permitted); filters the dashboard; remembers the choice — **built**.
21. Attention pin: red, blinking pin when any location needs attention (tech waiting for code, approval waiting, overdue bill, missed window, unscheduled visitor, flagged call); red dot + reasons per location; "Blink" can be turned off — **built** (per device).
22. New service call / install quote scroll to their form and back — **built**.
23. Service call form: Type of problem (trade) → problem list filtered; "Send to" lists that trade's contractors first, then others. Receipt confirmation = contractor taps Accept within the store's window (email read receipts are unreliable; Accept is the proof) — **built**.
24. Which unit → "+ It's not listed: add it now" saves the unit to Equipment with the call — **built**.
25. Invite a contractor: Office phone field (used by "Call office") plus the contact's mobile (for texting the link) — **built** (2026-10-23).
26. Money fields (not to exceed, approval limit, emergency limit) take any amount, e.g. $125 — no more "nearest valid value" popup — **built**.
28. Contractor side, many customers: customer/store picker top-left (filters the whole office screen; red dot + reasons; pin blinks), browser-tab count, and a Customers tab (each account's stores, terms, equipment, past calls, open/to-bill/this-year totals) — **built** (2026-10-23).
29. Reaching the contractor fast (next): store "Call them now" + "I talked to them" note; then the step-up ladder — push + email (+ text) → automated phone call ("press 1 to accept", counts as Accept) → backup number → tell the store. Contractor "Who gets the calls": business-hours office number + hours, after-hours number or whoever is on call, one-tap "On call now" and optional weekly rotation. Needs Twilio (voice doesn't wait on 10DLC); consent box at signup.
30. Store "📞 Call them now" + "I talked to them" note on each open call (red when an emergency isn't accepted yet); contractor "Who gets the calls" panel with office phone (after-hours / on call / automatic calls shown as coming soon) — **built** (2026-10-23). Same number as the visitor "Call office" button; both will dial the right number for the moment once on-call is built.
31. Remove a contractor (store) / remove a customer (contractor): leaves the dashboard, no new calls, trades go back to the main contractor, PM plans stop; blocked while calls are open; past records kept; restorable; the other side is told — **built**.
32. Price raised to **$395 per location per year** (Mark, 2026-10-23); no per-contractor fee; unlimited contractors; $95 of it available for sales commission (suggested: first year only, paid on customer payment). Fair-use notice added to the plan screen and Terms. Founding-customer $295 lock: suggested, not decided.
**Reminder for Mark:** open a Twilio account (voice) for the automatic phone-call ladder.
27. Search past calls: button on the dashboard opens "Past calls / PO log" with search, contractor, trade, location and date filters, and export — **built**.
**Before the paid launch (Mark, 2026-10-22):** move Supabase to Pro (daily backups, no pausing) and Vercel to Pro (commercial use); then the "Your data" text can promise daily backups.
Earlier from the remote test: arrival watched only after "I'm going"; owner-tech needs I'm going/I'm here on the office screen — open.

### 27. Contractor growth path and QR inventory (Mark, 2026-10-22) — idea, for Enterprise
- Contractors start free on Time Verify because their stores use it; once used to it, Base → Pro → Enterprise is a natural move. Goal: a good enough product to pull small/mid contractors off ServiceTitan.
- **QR inventory (Enterprise):** QR labels on bins, shelves and truck stock; techs scan to take a part (it lands on the job and the invoice), scan to restock; low-stock alerts, truck-by-truck counts, reorder lists. Ties into the existing parts list and the live cost meter.
- What it takes to win ServiceTitan users (honest list): one-time data import (customers, equipment, history), QuickBooks sync, simple pricebook, payroll/timecards export, reporting. Price below them per tech.

### Order of work (proposed)
Database v2 + portals v2 + technician app (done 2026-10-16) → Time Verify (done 2026-10-20) → Mark's Time Verify shakedown (acting as store and contractor, real tags) → **facility management package (§23)** → finish Base/Pro/Enterprise (email + texting, Stripe, QuickBooks, estimating, job costing) → construction (§24, later) (accounts needed) → AI nameplate reading → QuickBooks (version set by the pilot contractor) → pilot.
The generalization changes (trades, equipment type table, work order kinds, customer teams and permissions) are done first, before real data exists, because they are cheapest now.

### Open questions
- Agreement coverage types beyond PM only / PM + labor / full coverage?
- Does the 7-day billing clock start at final completion (current) or after each visit?
- (Settled: residential — the contractor pays, the homeowner pays nothing. PM pricing — flat per-visit price on the plan, or covered by an agreement.)

## Phases

- [x] **1a. Database foundation** — schema, rules, security, 42-check test. **Live on Supabase** (project `Servicepro`, us-east-1) since 2026-10-15; smoke-tested end to end on the live database
- [x] **1a-v2. Database v2** — 45 tables: jobs with multiple visits, lettered POs (PO1100, A, B, C…), issue price list with region / after-hours / agreement layers, customer teams with dollar-limit approval chains, check-in codes with offline backups, parts waiting, warranties, maintenance agreements, PM auto-scheduling, timecards, billing clock, platform fees and wholesaler commission. 86-check test passing. **Live 2026-10-16** with demo calls in every state
- [x] **1d. Property managers + owner approval + no-login homeowner links** — live 2026-10-16; 113-check test passing
- [x] **1b-v2. Portals v2** — store portal (issue dropdown showing the authorized amount, approvals with limits and escalation, PM panel that stays until done, late bills, check-in code) and office portal (board, PM, billing, review, history). Live 2026-10-16
- [x] **1b. Web portals v1** — live at https://servicecallproof.com (Vercel project `servicepro`, auto-deploys from GitHub `main`). Sign-in, store portal (new call, approvals, call detail), office dispatch board, review queue, mark invoiced. Demo logins share password `DemoService2026!` — remove the demo list on the sign-in page before real customers
- [x] **1c. Technician app (installable web app, works offline)** — live 2026-10-16 at /tech ("Add to Home Screen"). Job list, Start + ETA, GPS arrival (automatic while the app is open, or "I'm here"), check-in code / backup code / name-only, nameplate + equipment, before/after photos (kept on the phone until sent), repair from list with parts kit, parts with the limit check, PM checklist, live cost meter with the stop point, quotes from hours + parts, emergency pre-approved limit, finish (complete / parts needed / return needed / quote sent), timecard. Tested end to end at phone size including finishing a job with no signal. Limit: no background arrival detection with the screen off (needs a store app later if the pilot shows it matters)
- [x] **1e. Time Verify** — live 2026-10-20 (see 19), incl. announced trips and who's-in-the-building; 281-check test passing
- [x] **1e-2. Store self-setup** — live 2026-10-22: start link → owner sets up company, login and first location; Add a location (address lookup sets map point + time zone); invite a contractor per location; Forgot password by email; phone header menu. 306-check test passing
- [ ] **1f. Facility management package** — next after the Time Verify shakedown (see 23)
- [ ] **2. AI** — nameplate photo → manufacturer/model/serial suggestion
- [ ] **3. Notifications** — push done 2026-10-20; email done 2026-10-21 (Resend, alerts@servicecallproof.com) and text (needs carrier registration); text the owner / homeowner approval links directly
- [ ] **4. QuickBooks Online** — Intuit developer app, OAuth connect, invoice export
- [ ] **5. Pilot** — one contractor, two stores
- [ ] **6. Parts photo recognition, truck inventory, polish**

## Accounts Mark will need (when we get there)

GitHub, Supabase, Vercel, Apple Developer ($99/yr), Google Play ($25 one-time),
Intuit Developer (free), and an AI vision API key.
