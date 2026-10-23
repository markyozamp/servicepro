'use client';

// The demo, for people deciding whether to buy: a hands-on side-by-side (store + technician's phone), then one-tap
// sign-ins to every role in the demo companies. Demo accounts reset every night and can't make permanent changes.
import { useState } from 'react';
import { supabase } from '@/lib/supabase';
import { portalFor, signOutLocal } from '@/lib/useProfile';
import PilotOffer from '@/components/PilotOffer';
import StorePilot from '@/components/StorePilot';
import DemoSim from '@/components/DemoSim';
import { LegalFooter } from '@/components/Legal';

const DEMO_PASSWORD = 'DemoService2026!';
const STORES = [
  { email: 'store@northside.demo', who: 'Store manager', org: 'Northside Grocers · Store #114', see: 'Order a service call, give a tech the check-in code, approve extra work up to $500.' },
  { email: 'maint@northside.demo', who: 'Maintenance manager', org: 'Northside Grocers · every store', see: 'All stores on one screen, equipment and warranties, maintenance, approvals up to $2,500.' },
  { email: 'director@northside.demo', who: 'Director of operations', org: 'Northside Grocers', see: 'The big picture: every store, every contractor, no spending limit.' },
  { email: 'pm@redriverpm.demo', who: 'Property manager', org: 'Red River Property Management', see: 'Apartments and duplexes: owners approve repairs above your limit.' },
];
const CONTRACTORS = [
  { email: 'pete@prairieplumbing.demo', who: 'Contractor owner', org: 'Prairie Plumbing · Pete', see: 'Run the business from one screen: accept calls, send a tech, send the bill. Try it on a phone too.' },
  { email: 'tony@prairieplumbing.demo', who: 'Technician (phone app)', org: 'Prairie Plumbing · Tony', see: '"I\'m going", "I\'m here", check in with the store\'s code, "Leaving". Best on a phone.' },
  { email: 'office@arcticair.demo', who: 'Contractor office', org: 'Arctic Air Mechanical · Dana', see: 'Several customers, a dispatch board, billing, the customer book.' },
  { email: 'tech@arcticair.demo', who: 'Technician', org: 'Arctic Air Mechanical · Mike', see: 'A refrigeration tech\'s day: jobs, parts runs, photos, approvals.' },
];

export default function Demo() {
  const [busy, setBusy] = useState('');
  const [err, setErr] = useState('');

  async function enter(email) {
    setBusy(email); setErr('');
    await signOutLocal();
    const { error } = await supabase.auth.signInWithPassword({ email, password: DEMO_PASSWORD });
    if (error) { setErr('The demo is resetting. Try again in a minute.'); setBusy(''); return; }
    const { data: p } = await supabase.rpc('me');
    window.location.assign(p?.is_technician && !(p.is_org_admin || p.can_dispatch || p.can_bill) ? '/tech' : portalFor(p));
  }

  const Card = ({ d }) => (
    <button type="button" className="demo-card" disabled={!!busy} onClick={() => enter(d.email)}>
      <span className="demo-card-who">{d.who}</span>
      <span className="demo-card-org">{d.org}</span>
      <span className="demo-card-see">{d.see}</span>
      <span className="demo-card-go">{busy === d.email ? 'Opening…' : 'Open →'}</span>
    </button>
  );

  return (
    <main className="demo-page">
      <header className="demo-top">
        <div className="brand" style={{ fontSize: 20 }}>Service Call <span>Proof</span></div>
        <a href="/" className="demo-signin">Customer sign in</a>
      </header>

      <section className="demo-hero">
        <h1>Know who's in your building, for how long, and what it should cost.</h1>
        <p>Service Call Proof sits between your locations (stores, restaurants, clinics, offices, properties) and your service contractors: every visit checked in with your code, every bill checked against the time actually spent.</p>
        <p className="small"><a href="#pilot-stores"><strong>Pilot locations wanted:</strong> stores, restaurants, clinics, offices and properties. 4 companies, free for the first year →</a></p>
      </section>

      <section className="demo-sec">
        <h2>Watch one call, start to finish</h2>
        <div className="sim-disclaimer"><strong>This is an animation, not the actual program.</strong> It's a small, simplified window into one service call: the store's screen on the left, the technician's phone on the right. Follow the steps; nothing here is real or saved.</div>
        <DemoSim />
        <p className="small muted" style={{ marginTop: 10 }}>The real system does much more: approvals, equipment history, maintenance plans, contractor records and rates, bill checks, team permissions and reports. <strong>To see it all, sign in to any role below and click around.</strong></p>
      </section>

      <section className="demo-sec">
        <h2>Explore the whole system</h2>
        <p className="muted">One tap opens a working account in our demo companies. Click anything. The demo goes back to its starting point every 10 minutes, with a countdown at the top so you know when. Use "← Back to demo menu" at the top to come back here and try another role.</p>
        {err && <div className="error">{err}</div>}
        <h3>Businesses and property managers</h3>
        <div className="demo-cards">{STORES.map((d) => <Card key={d.email} d={d} />)}</div>
        <h3>Contractors and technicians</h3>
        <div className="demo-cards">{CONTRACTORS.map((d) => <Card key={d.email} d={d} />)}</div>
      </section>

      <section className="demo-sec demo-cta">
        <h2>Ready to start?</h2>
        <p>$395 per location per year. All trades, unlimited service calls, unlimited people. Your contractors use it free.</p>
        <StorePilot />
        <p className="small"><strong>Enhanced Time Verify, at no extra charge:</strong> when your contractor runs Service Call Proof Base or Pro, their bills come straight into your portal, already matched to the call and your PO. Download them, export them, or forward them to your accounting department. No mailed or emailed bills to chase.</p>
        <div className="demo-cta-row">
          <button type="button" className="primary big" disabled title="Coming soon">Get started now <span className="soon">Coming soon</span></button>
          <a className="button-like" href="mailto:sales@servicecallproof.com?subject=Service%20Call%20Proof%20questions">Questions? Talk to us</a>
        </div>
        <p className="small muted"><strong>Are you a contractor?</strong> Contractors join free when a customer invites them. Ask the customers you work for, or <a href="mailto:sales@servicecallproof.com?subject=Contractor%20interested">tell us which customers</a> and we'll reach out. Want to run your whole shop on it? <a href="#contractors">See the contractor plans and the pilot offer</a>.</p>
      </section>

      <section className="demo-sec" id="contractors">
        <h2>For contractors: plans</h2>
        <p className="muted">Time Verify is free when a customer invites you. Base, Pro and Enterprise run your whole shop, and they're in pilot now.</p>
        <PilotOffer source="demo" current={null} />
      </section>
      <div style={{ padding: '0 16px 24px' }}><LegalFooter /></div>
    </main>
  );
}
