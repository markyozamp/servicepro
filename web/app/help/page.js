'use client';

// How-to guide: short, numbered steps for everything people do, for stores, contractors and technicians. Searchable.
import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';

const STORE = [
  ['Make a service call', [
    'On your dashboard, under Order work, tap + New service call.',
    'Pick the Location (if you have more than one).',
    'Pick the Type of problem (refrigeration, plumbing, electrical…). The right contractor is filled in for you under Send to; change it if you need to.',
    'Pick What\'s the problem from the list, and the unit if you know it. Not listed? Tap "+ It\'s not listed: add it now".',
    'Add any details, your PO number and a not-to-exceed amount if you use them (next guide).',
    'Tap Send service call. The contractor must accept within your time limit; you\'ll see "Accepted" with the time once they do.',
  ]],
  ['Put your PO number and a dollar limit on a call', [
    'On the new service call form, type your number in Your PO number, exactly as your company writes it (for example PO 725 or AXYZ-1043).',
    'Leave it blank and Service Call Proof numbers it for you (for example PO1136).',
    'In Not to exceed ($), type the most you want spent without asking you, any amount (for example 125). The contractor sees it and the invoice is checked against it.',
  ]],
  ['Know the contractor got the call', [
    'Open the call. The Time Verify box shows "Waiting to be accepted by…" with the deadline, then "Accepted" with the time.',
    'Not accepted in time? It turns red, and you can send it to another contractor from the same box.',
    'Emergency? Tap 📞 Call [contractor] now on the call, then tap I talked to them and note who and when (for example "Dana, 2:10 pm").',
  ]],
  ['A technician is at the door: give the check-in code', [
    'When the tech arrives, a box shows at the top of your dashboard with the call\'s check-in code.',
    'Read the code to the technician. They enter it on their phone and the visit is verified.',
    'Code not handy? Each location can have a backup code (Settings & plan → Locations). Using it is marked on the call.',
  ]],
  ['Approve extra work', [
    'When a contractor asks for more money, the call shows under Approval needed and your pin turns red.',
    'Open it, read what they found, and tap Approve or Decline.',
    'You can only approve up to your own limit; bigger amounts go to the person above you automatically.',
  ]],
  ['Someone shows up you weren\'t expecting', [
    'In In the building now, tap Someone\'s here we weren\'t expecting.',
    'Enter their name and company (and plate or photo if your location requires it), then save.',
    'Their office is told right away, and you can tap Call office to phone them.',
  ]],
  ['Add a person to your team', [
    'Tap Team on your dashboard.',
    'Tap + Add a person. Enter their name, email or mobile, and job title.',
    'Tick what they can do (open calls, approve up to an amount, equipment, contractors, locations, team, settings & plan).',
    'Under Which locations do they see?, tick All locations or just theirs.',
    'Save, then send them the sign-in link by text or email. Logins are included in your plan; add as many people as you need.',
    'Give every person their own login, and never share one. Logins are free and unlimited. With a shared login, one person changing the password locks everyone out, and you can\'t tell who approved what.',
    'Set people up with an email they\'ll keep, ideally a company email. The owner especially should use a company email the owner controls, so password resets always reach the right person.',
  ]],
  ['See what was missed (Follow-through report)', [
    'On your dashboard, tap Follow-through report. It counts what your people were asked to do (give the check-in code, answer requests for more money, approve bills, look at flags and more) and lists anything that missed its deadline, by location, with the dollars involved.',
    'Owner: Settings & plan → Follow-through report → tick Alert me when follow-through slips, set the limit (standard: more than 5% and at least 3 misses in 30 days), choose who gets it → Save.',
    'The alert comes Monday mornings when you are over the limit. An emergency call where the technician waits 15 minutes or more for the code alerts you right away.',
  ]],
  ['Choose which locations a person sees', [
    'Team → Edit next to the person → Which locations do they see? → tick their locations → Save.',
    'Or by location: Settings & plan → Locations → Who sees this, tick the people → Save.',
    'People with All locations see every one automatically, including new ones.',
  ]],
  ['Change who the admin is', [
    'Only an admin can do this. Tap Team, then Edit next to the person who should be admin.',
    'Tick Admin (it can do everything, sees every location and manages your plan) and Save.',
    'To take admin away from someone else, Edit them and untick Admin. You can\'t remove your own admin access, so the new admin removes yours if needed.',
  ]],
  ['When someone leaves the company', [
    'Each person has their own login and password. Nobody can change anyone else\'s password.',
    'Team → Remove next to the person who left. They can no longer sign in; their past work stays on the calls.',
    'The company owner (marked Owner on Team) can\'t be removed or have admin taken away by anyone else, and is told by email and phone alert whenever someone\'s admin access or sign-in changes.',
    'Owner forgot their password? Use Forgot password? on the sign-in page with the owner\'s own email.',
    'Owner locked out and that email is gone? Email support@servicecallproof.com from your company\'s email; we confirm who you are before restoring access.',
    'Owner handing over the business? Make the new person an admin, then tap Make owner next to them.',
  ]],
  ['Add a location', [
    'Settings & plan → Locations → + Add a location (or the location menu at the top → + Add location).',
    'Type the name and address, tap Find, then Add location.',
    'Choose who on your team should see it, and Save.',
    'Then set a backup check-in code and Wi-Fi for technicians if you like.',
  ]],
  ['Invite a contractor', [
    'Contractors & QR → + Invite a contractor.',
    'Enter the company, a contact name, their email and/or mobile, and their office phone.',
    'Tick the trades they do for you and which locations they serve.',
    'Tap send, then text or email them the sign-in link. It\'s free for them.',
  ]],
  ['Pick which contractor gets each kind of problem', [
    'Contractors & QR → Who gets which kind of call.',
    'For each trade (refrigeration, plumbing…), pick the contractor. New calls go to them automatically.',
  ]],
  ['Maintenance plans (PMs)', [
    'On your dashboard, tap 📋 Maintenance plans. Each plan shows how often, the next due date, the price, about how many hours it should take, and how many days it must be finished in once it starts.',
    'The PM call opens by itself before each due date, and your contractor schedules the trip. You see it under Preventive maintenance until it\'s done.',
    'Each PM shows how it\'s going: trips, which technicians, hours on site, checklist done. If it drags past its window, or the technician changes partway, it\'s flagged to you.',
    'Tap + New maintenance plan to add one, or your contractor proposes one and you tap Accept. "Show the last PMs" tells you which were on time and which were split up.',
  ]],
  ['Edit a contractor', [
    'Settings → Contractors. Under the contractor, open "Edit details & your contact there".',
    'Your contact there (name, phone, email) and a note are yours to keep up to date anytime. Only your company sees them.',
    'Haven\'t they signed in yet? You can fix the company name, office phone, and who the sign-in link goes to, then make a fresh link (the old one stops working).',
    'Once they\'ve signed in, their company name and office phone are theirs to keep up to date. Your rules for them (travel, accept times, how many days they have to send the invoice, time not checked in) are right above: change them and tap Save.',
  ]],
  ['Contractor rates, and comparing contractors', [
    'Settings → Contractors → "Rates they charge you" under each contractor: regular labor, after hours, helper, trip charge, parts markup and up to 4 others.',
    'Enter them yourself, or your contractor enters them and you tap Accept. A raise they propose waits for you, with the old rate shown next to it.',
    'Every change is kept with its start date: "Show rate history" tells you when a rate went up and by how much. On each call, "Their rates" shows the rates as of that call.',
    'Tap ⚖ Compare contractors\' rates to see everyone side by side (pick a trade). Got a quote from a company that wants your account? Add it and it shows next to your contractors.',
    'Rates are for reference; they don\'t change how bills are checked.',
  ]],
  ['Set a contractor\'s regular hours (when after hours starts)', [
    'Contractors & QR → the contractor → Regular hours. Pick a preset (Mon–Fri 8 to 5, a day-and-night crew, around the clock) or set each day.',
    'Days left unticked are after hours all day. Tick "Maintenance (PM) calls are never after hours" if your maintenance program has no overtime.',
    'New calls, the verified time on the call (regular vs after hours) and the bill check all follow these hours.',
  ]],
  ['After hours: send now, or wait until morning', [
    'Open a call outside the contractor\'s regular hours and the app asks: emergency, or can it wait until morning? It shows both rates when they\'re on file.',
    'Wait until morning saves the call and sends it to the contractor at their next regular hour, with no after-hours charge.',
    'Emergencies always go right away. On after-hours calls, "Call them now" dials the contractor\'s after-hours number.',
  ]],
  ['Stop using a contractor', [
    'Contractors & QR → find the contractor → Remove this contractor.',
    'Their past calls stay in your records; no new calls can go to them. Finish or cancel any open calls first.',
    'Changed your mind? Show removed contractors → Restore.',
  ]],
  ['Add equipment, warranties and QR stickers', [
    'Equipment → add each unit (what it is, where it is, make, model, serial) and its warranty dates.',
    'Contractors & QR → order or print QR stickers and put one on each unit.',
    'Set a location PIN there too. Any employee can scan a sticker, enter the PIN and report a problem.',
  ]],
  ['Busy hours: keep contractors out of your rush', [
    'Settings → Locations → the location → Busy hours → Set busy hours. Add up to 2 windows a day (for example 11:00–1:30 and 5:00–7:30), or tick Same every day → Save.',
    'Contractors can\'t schedule, offer, accept "on the way now" or start a non-emergency visit during them. Emergencies still come right away.',
    'Want someone during busy hours on one call? Open the call and tap "Let them come now". A technician already working when busy hours start isn\'t stopped; you get a heads-up.',
    'If a contractor taps "Ask to come now", you get an alert: tap "Let them come now" or "Not yet".',
  ]],
  ['Answer from the email, no login', [
    'When something waits on you (a tech\'s crew, a return-trip time, an approval, an invoice, a call to confirm, a contractor asking to come during busy hours), the alert email has one button that answers it. No password.',
    'The button answers as you, works once and expires after 3 days, so don\'t forward the email.',
    'Everything waiting is also listed at the top of your dashboard under "Waiting on you". Tap one to go to it.',
    'Nobody answers? A reminder goes out (after 15 minutes if urgent, 4 hours if not, daytime only). Still nothing: it goes to the location\'s backup person (after 30 minutes, or the next morning). Nothing is decided for you.',
    'Set the backup: Settings → Locations → the location → "If nobody here answers, send it to". Not set: your admins get it.',
  ]],
  ['Say when they can come', [
    'On a new non-emergency call, "When can they come?": Anytime, or pick a time (from–to), with a note like "before we open".',
    'The contractor accepts for your time, or offers you other times to pick from.',
    'Settings & plan → When contractors come → tick to ask this on every non-emergency call.',
  ]],
  ['A contractor wants to come back: pick a time', [
    'When a contractor needs to come back (the part came in, a second visit), they send you up to 3 times. You get an alert, and a blue box on your dashboard and on the call.',
    'Tap the time that fits your day. Only then is the trip scheduled, with a check-in code for it.',
    'None work? Tap "None of these work" and say what would (for example "after 2 pm" or "Tuesday morning"). They send new times.',
  ]],
  ['Leased equipment (full coverage)', [
    'Settings → Equipment → "+ Leased" on the unit → tick Leased / rental with 100% coverage → the lease company, contact, phone or email → Save.',
    'Opening a call on that unit shows the lease company first, with a Call button. You can still open a call with your contractor; it\'s flagged so the bill gets a second look and is never approved automatically.',
    'Employees scanning the unit\'s QR sticker see who leases it too.',
  ]],
  ['Confirm the crew size', [
    'When a technician arrives, he says how many helpers are with him. A yellow box asks you: "Tony says he has 1 helper with him. Is that right?" Tap Yes or No.',
    'No flags the call and tells their office. Helper hours on the bill are checked against the confirmed crew and the time on site.',
  ]],
  ['Find a past call or export your calls', [
    'Tap 🔎 Search past calls on your dashboard.',
    'Search by words, or pick a contractor, trade, location or dates.',
    'Tap Export to spreadsheet to download what\'s showing. It opens in Excel.',
  ]],
  ['Your logo and company details', [
    'Settings & plan → Company profile: name, phone, email.',
    'Logo → Upload logo. A wide logo works best. It shows at the top of your dashboard.',
  ]],
  ['Approve a contractor\'s bill', [
    'Every bill arrives tied to its call and PO, with the contractor\'s own invoice number, so it matches their paperwork in one step.',
    'Open the call. You see the hours billed next to the verified hours, the total next to what the call allows (PO plus anything you approved on top), and whether the contractor agreed to the verified hours.',
    'Tap Approve invoice, or Question it and say what\'s wrong (the contractor sees your note).',
  ]],
  ['Approve matching bills automatically', [
    'Settings & plan → Approving bills → tick "Approve bills automatically when they match exactly". It\'s off until you turn it on.',
    'A bill is approved for you only when the contractor agreed to the verified hours, the total is within the PO, and nothing is flagged.',
    'Anything else still waits for you. Auto-approved bills are marked "Approved automatically" on the call.',
  ]],
  ['Check travel time on a bill', [
    'Open the call. Under Verified time, each trip shows the town it started near and about how far away it was: "Trip started near Fisher, MN, about 14 mi away."',
    'Only the actual drive is counted, from I\'m going to arrival. If the tech was already in the area and the bill has more hours than verified, the call says so.',
    'Set what counts as "already in the area" under Settings & plan → Travel check. It starts at 10 miles.',
    'You see the town only, never the exact spot or a map, and nothing between calls.',
  ]],
  ['Message credits (fair use)', [
    'Phone alerts and email are unlimited. Texts and automatic phone calls use credits: 150 per location per year, shared across your company.',
    'See what you\'ve used under Settings & plan → Texts & phone calls. The chart shows each month.',
    'Running low? Add a pack of 100 credits for $10. Emergency alerts are never stopped.',
  ]],
];

const CONTRACTOR = [
  ['First-day setup (about 5 minutes)', [
    'Open the sign-in link your customer sent you (text or email). No password needed. Read their terms and tap I agree — sign in.',
    'A Getting started list appears on your Today screen. It ticks itself off as you go.',
    'Add your office phone: Team → Who gets the calls → Office phone → Save.',
    'Add each technician: Team → add the person with their mobile number → Text it from this phone. Just you? Tick "It\'s just me".',
    'Put the app on your phone: menu → Install on this phone (iPhone: Share → Add to Home Screen).',
    'Print the one-page quick start for your techs: servicecallproof.com/quickstart.',
  ]],
  ['Your customer\'s rules (terms)', [
    'Each customer sets how fast you must accept calls, whether travel time is paid, and what happens to time not checked in.',
    'See them anytime: Customers → open the customer → Their terms with you.',
    'Time is verified by the check-in code and the phone\'s arrival, so bill the hours on the call to get paid fastest.',
  ]],
  ['My sign-in link doesn\'t work', [
    'Links work once and expire after 7 days. If it says used or expired, ask the customer who invited you to send a new one.',
    'For a technician\'s link, the office sends a new one: Team → New sign-in link next to the person.',
    'Already have a password? Sign in at servicecallproof.com, or tap Forgot password?.',
  ]],
  ['See what needs you today', [
    'On a phone, open Service Call Proof: Today is your home screen. On a computer, click the Today tab.',
    'It lists, most urgent first: calls to accept, trips to schedule, missed windows, bills to send, and more. Tap anything to open it.',
  ]],
  ['Accept a new call', [
    'Open the call from Today (or the New column on the board).',
    'Tap Accept — on the way now, or pick a time and tap the schedule button.',
    'Accept before the customer\'s deadline shown on the call. Can\'t take it? Decline with a reason so the customer can send it elsewhere.',
  ]],
  ['Send a technician', [
    'Open the call, pick the technician and the time, and save the trip.',
    'The customer sees them under Expected today, and the tech sees it in their app.',
  ]],
  ['Propose a maintenance plan', [
    'Customers → pick the customer → Maintenance plans → + Propose a maintenance plan.',
    'Set the location, how often, next due date, price, about how many hours, how many days to finish once started, and the checklist. Send it; the customer accepts it.',
    'Once accepted, the PM call opens by itself before each due date. Schedule the trip and finish it within the days on the plan, with the same technician if the plan says so.',
  ]],
  ['Enter your rates for a customer', [
    'Customers → pick the customer → "Your rates for …": regular labor, after hours, helper, trip charge, parts markup and up to 4 others (parts runner, holiday rate…).',
    'Tap Enter your rates (or Propose new rates), pick the start date and Send to them. They accept, and you\'re told.',
    'Raising rates? Propose them with the date they start. Until the customer accepts, they see the old rates with your proposal next to it.',
  ]],
  ['Send your bill', [
    'Finished calls show under Bills to send (and the Billing tab).',
    'Open the call. Tick that you agree to the labor hours shown (verified on site + travel, over the number of trips), and that your bill doesn\'t go over the PO plus anything the customer approved on top. Parts are included under the PO.',
    'Type your own invoice number and total, then Agree and send. About 15 seconds.',
    'Hours different? Tap "My hours are different" and say what the extra time was for. Over the PO? Ask first with Request approval for more, or send it marked over the PO.',
    'Travel counts from where the trip really started (when your tech tapped I\'m going), not from your shop. The customer sees the town it started near.',
    'Send it before the customer\'s deadline, or it shows as late to them.',
  ]],
  ['Base: the bill is written for you', [
    'On Base, open a finished call: the bill is already built from the record. Verified labor at your rates for that customer (regular, after hours, helper), a trip charge per trip, parts used, a PM\'s flat price.',
    'Change any line, + Part or + Other line to add, ↻ Rebuild from the record to start over (lines you added stay).',
    'Check the invoice #, then Send the bill. It gets the same check as always: labor vs verified, the PO limit, auto-approve.',
    'Preview / print opens the bill to print or save as a PDF. The customer can open the same copy from the call.',
    'Set how bills are numbered: Team → Invoice numbers (e.g. "PP-" and the next number).',
    'Missing a rate? Put your rates for that customer on the rate card so they fill in next time.',
  ]],
  ['Send bills to QuickBooks (Base)', [
    'Office → Billing → Send bills to QuickBooks (owner or billing). Pick dates if you like, then Find bills. Only bills not sent yet, unless you untick it.',
    'QuickBooks Online: download QuickBooks Online (CSV), then in QuickBooks: Settings → Import data → Invoices. Up to 100 invoices per file. It doesn\'t work if sales tax is turned on in your QuickBooks. Sales tax on a bill comes in as a "Sales tax" line; point that product at your sales tax payable account.',
    'QuickBooks Desktop: open "QuickBooks Desktop instead", enter your receivables and income account names, download the .iif, then File → Utilities → Import → IIF Files.',
    'Each bill is marked once downloaded, so it doesn\'t go in twice. Customer list (CSV) helps you add new customers to QuickBooks first.',
  ]],
  ['Temperatures and doors (sensors)', [
    'Store: 🌡 Temperatures (under your name). Contractor: the Temperatures tab. Every sensor live: temperature or door, battery, when it was last heard, and the last 48 hours.',
    'Setup (store admin or your contractor\'s office): + Add a gateway for the building and put its private address into the gateway (Milesight: Network Server → Applications → HTTP data destination, payload codec on). Then + Add a sensor: pick it from the sensors the gateway hears, name it, set the low / high °F and how many minutes out of range before an alarm. Door sensors: how many minutes open before an alarm.',
    'Alarms go to the store\'s list (Who gets alarms) and the contractor\'s office and whoever is on call. Too warm or too cold also opens a service call to the contractor with the readings, unless you turn that off for the unit, or a call is already open for it. A reminder goes out if nobody taps "I\'m on it" in 30 minutes, and a notice when it\'s back to normal.',
    'Also flagged: a sensor that stops reporting, a gateway that goes offline, and a low battery (use lithium batteries in freezers).',
    'No sensors? Add a Typed log for the unit and type the temperature when you check it: same limits, same alarms.',
    'Temperature log (for a claim, your insurer or the health inspector): Temperatures → Temperature log → pick the dates and unit → Open the log. Hour by hour with each hour\'s high and low, a graph with the limits, the alarms and who answered them, door openings per day. Print, save as PDF or download.',
  ]],
  ['Sales tax and use tax (Base)', [
    'Team → Sales tax rates (owner or billing): add one rate for each state you work in, plus the cities or special districts with a different total rate. Say whether labor and the trip charge are taxed there. You set and check the rates; the app never supplies one.',
    'A location uses its city\'s rate if the city is on your list, otherwise its state\'s. On any bill or quote you can pick a different rate for that location (for addresses just outside city limits).',
    'Each line is Taxed (sales tax on the price, shown on the bill), Built-in (it becomes part of the building: no tax on the bill, you owe use tax on your cost), or No tax. Parts remember Built-in for next time.',
    'Tax-exempt customer: on the bill, "This customer is tax exempt…", note the certificate. No sales tax on their bills; use tax on built-in parts is still yours.',
    'Office → Billing → Sales and use tax report: by rate, what you charged and the use tax you owe, with a CSV for your accountant. Each new quarter you\'re reminded to check your rates. Rules differ by state; have your accountant confirm your settings.',
  ]],
  ['Quotes for installs and projects', [
    'Store: + New service call area → Install / project quote → + Ask for quotes. Pick the location, say what you want quoted, tick the contractors, set a date.',
    'Their quotes come in side by side with every line. Approve: make it the job opens a call to that contractor with the quote total as the limit; the others are told they weren\'t chosen. No thanks asks why, so they can adjust.',
    'Contractor: Quotes tab. Asked to quote shows the requests: Write a quote (lines, + From price book, notes, good until), then Send the quote. Can\'t quote it tells the customer.',
    'Base: + New quote for any of your customers. Customers without a login get an email link: they approve or decline there and type their name to sign.',
  ]],
  ['Schedule your techs (Base)', [
    'Office → Schedule: the week, one row per technician, every trip on it (scheduled, on the way, on site, done). ‹ › to change weeks.',
    'Needs a trip lists the calls with no trip yet. Tap Schedule, pick the tech, the day and the from–to time.',
    'Tap a trip to open the call: move it, change the tech or cancel it from there.',
  ]],
  ['Timesheets (Base)', [
    'Techs clock in, take breaks and clock out on the phone (top of the job list).',
    'Office → Timesheets: each tech\'s week, paid hours (clocked minus breaks), overtime past 40, time on site and driving from the trips, jobs.',
    'Tap a tech for their days and punches. Fix a punch with a reason (it\'s kept on the record). Then Approve the week (not your own).',
    'Owner or billing: Download for payroll (CSV) sends the approved weeks to payroll; after that a punch can\'t be changed.',
  ]],
  ['Your own customers (Base)', [
    'Customers → + Add a customer: a business or a homeowner, with their first location and the email for bills. They don\'t need a login.',
    'On their page: Edit details, + Location for more locations.',
    'Make calls for them the usual way (+ New call). When the work is done, open the call: the bill is written for you. Send the bill emails them a link to it (print or save as a PDF).',
    'Then Mark paid when the money comes in, or Email it again (to them or someone else, like their bookkeeper).',
  ]],
  ['Flat rate: your price book', [
    'Team → Price book. Add tasks (+ Task) with one price that covers labor and parts, or Import from a spreadsheet (save it as CSV with columns code, name, price, category).',
    'Pick a customer to set Bill them: Hourly or Flat rate, and to give them their own prices (leave blank for the book price).',
    'On a flat-rate call your tech taps + Add a task on the phone and picks what was done. The office can add more on the bill (+ From price book).',
    'The bill is the tasks. Hours aren\'t billed or checked, but the customer still sees the verified time on site for reference. The PO limit still applies.',
  ]],
  ['Look at one customer', [
    'Tap the pin menu at the top left and pick a customer or one of their locations. Your whole screen shows just them.',
    'The Customers tab shows each account\'s locations, rules, equipment and past calls.',
  ]],
  ['Add a technician', [
    'Team (on a phone: More → Team) → add the person with their mobile number.',
    'Send them the sign-in link. They open it on their phone; no password needed.',
  ]],
  ['Set your office phone and logo', [
    'Team → Who gets the calls → Office phone → Save. This is the number customers reach when they tap Call them now.',
    'Your logo (company admin): Team → Your logo → Upload logo.',
  ]],
  ['Busy hours and the customer\'s requested time', [
    'The call shows "The customer asks you to come …" and the location\'s busy hours. Your techs see both on their phones.',
    'Accept with "I\'ll come in your time", or "Can\'t make that time — offer others" to send up to 3 times for them to pick.',
    'During busy hours the app won\'t let you schedule, offer or start a non-emergency trip, unless the customer taps "Let them come now". Emergencies can go any time; a visit during busy hours is noted on the call.',
    'Need to come now anyway? Tap "Ask to come now" on the call (office) or on the job (tech\'s phone). The customer gets the request and you get their answer.',
  ]],
  ['Schedule a return trip', [
    'Open the call → Schedule the next trip → pick the technician → offer up to 3 times (+ Add another time) → Send times to the customer.',
    'The customer taps the one that works, and the trip is scheduled: your tech gets it on his phone. If none work, you see their note ("after 2 pm") and offer new times.',
    'Need to go right away? Tick "Going now" instead: the customer is told he\'s coming now.',
  ]],
  ['After hours and who\'s on call', [
    'Team → Who gets the calls → After-hours number (your answering service or on-call cell) → Save. Customers dial it on after-hours calls.',
    'On call: pick a tech and the days → Add. He gets new after-hours calls first, on his phone, along with your office.',
    'Each customer sets your regular hours with them; outside those hours a call is after hours. A customer can choose to hold a non-emergency call until your regular hours; it shows as "Held until …".',
  ]],
  ['Stop serving a customer', [
    'Customers → open the customer → Remove this customer (company admin only).',
    'Finish, invoice or cancel open calls first. Your past records stay; you can restore them later.',
  ]],
];

const TECH = [
  ['Sign in on your phone the first time', [
    'Open the sign-in link your office texted you, on your own phone. It works once; no password.',
    'Tap the menu (☰) → Install on this phone, so the app is on your home screen (iPhone: Share → Add to Home Screen).',
    'Allow location when asked. It is only saved when you tap a button or arrive at a job.',
  ]],
  ['No one on site can find the check-in code', [
    'Every call has its own code. It shows on the customer\'s screen when you arrive.',
    'If nobody can find it, tap Use backup code and ask for the location\'s backup code.',
    'Still nothing? Tap No code available and say why. The customer sees the reason on the call.',
  ]],
  ['Ask the customer to approve more money', [
    'On the job, tap Request approval for more, describe the work and the amount, and send.',
    'Wait for the answer on your phone. Don\'t do the extra work until it says approved.',
  ]],
  ['Helpers on the job', [
    'After "I\'m here", the app asks: Who\'s with you? Tap Just me, +1, +2, +3 or More. Add names if you like.',
    'The person who gives you the code confirms the count. Helper time is counted from when you arrived.',
    'A helper leaves early, or another shows up? Tap "Crew changed" and pick the new number. The time is recorded.',
  ]],
  ['Going for parts', [
    'Tap 🚚 Parts run before you leave. Tap at the supplier when you get there, and again when you\'re back.',
    'The customer sees it as a parts run, so the time away is explained on the bill.',
  ]],
  ['Go on a call', [
    'Tap the job, then I\'m going when you leave. The customer sees you\'re on the way and the town you\'re starting from (never the exact spot).',
    'Tap it when you actually leave. Your drive time is counted from that tap.',
    'When you arrive, the app notices (or tap I\'m here). Ask someone on site for the check-in code and enter it.',
    'Going for parts? Use the parts run button so the time away is explained.',
    'Done? Tap Leaving and say whether it\'s finished or needs another trip.',
  ]],
  ['No signal', [
    'Keep working. Your taps are saved on the phone and sent when you\'re back online, with the right times.',
  ]],
];

const EVERYONE = [
  ['Put the app on your phone or computer', [
    'Android or computer (Chrome or Edge): tap Install on this phone/computer in the top bar (on a phone, in the ☰ menu). Done.',
    'iPhone: tap Install, then follow the 3 steps: Share → Add to Home Screen → Add. Open it from the new icon and sign in once.',
  ]],
  ['Our emails went to Spam or Junk', [
    'Look in your Spam or Junk folder for mail from alerts@servicecallproof.com.',
    'Open it and tap Not spam (Gmail) or Move to Inbox / Not junk (Outlook, iPhone Mail).',
    'Add alerts@servicecallproof.com to your contacts so future emails go straight to your inbox.',
  ]],
  ['Forgot your password, or want to change it', [
    'On the sign-in page, tap Forgot password? and enter your email. Use the link within 1 hour.',
    'Signed in? Open the top menu → Password to set a new one.',
  ]],
  ['Still stuck?', [
    'Email support@servicecallproof.com and tell us what you were trying to do. A screenshot helps.',
  ]],
];

const GROUPS = [['store', 'Customers', STORE], ['contractor', 'Contractors', CONTRACTOR], ['tech', 'Technicians', TECH], ['all', 'Everyone', EVERYONE]];

export default function Help() {
  const [who, setWho] = useState('store');
  const [find, setFind] = useState('');
  useEffect(() => { const w = new URLSearchParams(window.location.search).get('for'); if (w && GROUPS.some(([k]) => k === w)) setWho(w); }, []);
  const list = useMemo(() => {
    const f = find.trim().toLowerCase();
    const src = f ? GROUPS.flatMap(([k, , items]) => items.map((it) => [...it, k])) : (GROUPS.find(([k]) => k === who)[2]).map((it) => [...it, who]);
    return f ? src.filter(([t, steps]) => (t + ' ' + steps.join(' ')).toLowerCase().includes(f)) : src;
  }, [who, find]);
  const label = Object.fromEntries(GROUPS.map(([k, l]) => [k, l]));

  return (
    <main className="page" style={{ maxWidth: 820 }}>
      <div className="spread" style={{ marginBottom: 8 }}>
        <h1>How-to guide</h1>
        <Link href="/" className="small">← Back to Service Call Proof</Link>
      </div>
      <p className="muted">Short steps for everything you do in Service Call Proof. Tap a topic to open it. Contractors and technicians: <a href="/quickstart">print the one-page quick start</a>.</p>
      <input value={find} onChange={(e) => setFind(e.target.value)} placeholder="Search: PO, admin, add a person, logo…" aria-label="Search the guide" style={{ marginBottom: 10 }} />
      {!find && (
        <div className="colchips" style={{ flexWrap: 'wrap' }}>
          {GROUPS.map(([k, l]) => <button key={k} type="button" className={who === k ? 'on' : ''} onClick={() => setWho(k)}>{l}</button>)}
        </div>
      )}
      <div className="stack" style={{ gap: 8, marginTop: 6 }}>
        {list.length === 0 && <div className="muted">Nothing found. Try another word, or email support@servicecallproof.com.</div>}
        {list.map(([title, steps, k]) => (
          <details key={k + title} className="help-item">
            <summary><strong>{title}</strong>{find && <span className="small muted"> · {label[k]}</span>}</summary>
            <ol>{steps.map((s) => <li key={s}>{s}</li>)}</ol>
          </details>
        ))}
      </div>
    </main>
  );
}
