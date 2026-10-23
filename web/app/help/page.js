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
    'Enter their name and company (and plate or photo if your store requires it), then save.',
    'Their office is told right away, and you can tap Call office to phone them.',
  ]],
  ['Add a person to your team', [
    'Tap Team on your dashboard.',
    'Tap + Add a person. Enter their name, email or mobile, and job title.',
    'Tick what they can do (open calls, approve up to an amount, equipment, contractors, locations, team, settings & plan).',
    'Under Which locations do they see?, tick All locations or just their stores.',
    'Save, then send them the sign-in link by text or email. Logins are included in your plan; add as many people as you need.',
    'Give every person their own login, and never share one. Logins are free and unlimited. With a shared login, one person changing the password locks everyone out, and you can\'t tell who approved what.',
    'Set people up with an email they\'ll keep, ideally a company email. The owner especially should use a company email the owner controls, so password resets always reach the right person.',
  ]],
  ['Choose which stores a person sees', [
    'Team → Edit next to the person → Which locations do they see? → tick their stores → Save.',
    'Or by store: Settings & plan → Locations → Who sees this, tick the people → Save.',
    'People with All locations see every store automatically, including new ones.',
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
  ['Stop using a contractor', [
    'Contractors & QR → find the contractor → Remove this contractor.',
    'Their past calls stay in your records; no new calls can go to them. Finish or cancel any open calls first.',
    'Changed your mind? Show removed contractors → Restore.',
  ]],
  ['Add equipment, warranties and QR stickers', [
    'Equipment → add each unit (what it is, where it is, make, model, serial) and its warranty dates.',
    'Contractors & QR → order or print QR stickers and put one on each unit.',
    'Set a store PIN there too. Any employee can scan a sticker, enter the PIN and report a problem.',
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
    'Links work once and expire after 7 days. If it says used or expired, ask the store that invited you to send a new one.',
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
    'Accept before the store\'s deadline shown on the call. Can\'t take it? Decline with a reason so the store can send it elsewhere.',
  ]],
  ['Send a technician', [
    'Open the call, pick the technician and the time, and save the trip.',
    'The store sees them under Expected today, and the tech sees it in their app.',
  ]],
  ['Send your bill', [
    'Finished calls show under Bills to send (and the Billing tab).',
    'Open the call and enter your invoice number, hours and total. The store sees it checked against the verified time.',
    'Travel counts from where the trip really started (when your tech tapped I\'m going), not from your shop. The store sees the town it started near.',
    'Send it before the store\'s deadline, or it shows as late to them.',
  ]],
  ['Look at one customer', [
    'Tap the pin menu at the top left and pick a customer or one of their stores. Your whole screen shows just them.',
    'The Customers tab shows each account\'s stores, rules, equipment and past calls.',
  ]],
  ['Add a technician', [
    'Team (on a phone: More → Team) → add the person with their mobile number.',
    'Send them the sign-in link. They open it on their phone; no password needed.',
  ]],
  ['Set your office phone and logo', [
    'Team → Who gets the calls → Office phone → Save. This is the number stores reach when they tap Call them now.',
    'Your logo (company admin): Team → Your logo → Upload logo.',
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
  ['The store can\'t find the check-in code', [
    'Every call has its own code. It shows on the store\'s screen when you arrive.',
    'If nobody can find it, tap Use store backup code and ask for the store\'s backup code.',
    'Still nothing? Tap No code available and say why. The store sees the reason on the call.',
  ]],
  ['Ask the store to approve more money', [
    'On the job, tap Request approval for more, describe the work and the amount, and send.',
    'Wait for the answer on your phone. Don\'t do the extra work until it says approved.',
  ]],
  ['Going for parts', [
    'Tap 🚚 Parts run before you leave. Tap at the supplier when you get there, and again when you\'re back.',
    'The store sees it as a parts run, so the time away is explained on the bill.',
  ]],
  ['Go on a call', [
    'Tap the job, then I\'m going when you leave. The store sees you\'re on the way and the town you\'re starting from (never the exact spot).',
    'Tap it when you actually leave. Your drive time is counted from that tap.',
    'When you arrive, the app notices (or tap I\'m here). Ask someone at the store for the check-in code and enter it.',
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

const GROUPS = [['store', 'Stores', STORE], ['contractor', 'Contractors', CONTRACTOR], ['tech', 'Technicians', TECH], ['all', 'Everyone', EVERYONE]];

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
