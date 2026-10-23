'use client';

// The demo, for people deciding whether to buy: a hands-on side-by-side (store + technician's phone), then one-tap
// sign-ins to every role in the demo companies (they go back to the start every 10 minutes), then Plans & pricing
// in two tabs: for businesses and for contractors. The two buttons at the top open the right tab.
import { useEffect, useState } from 'react';
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

const BUSINESS_INCLUDES = [
  'Every visit checked in with your code, and the time on site verified',
  'Every bill checked against the verified time, your PO and the contractor\'s rates',
  'Approvals with dollar limits, owner approval above them',
  'Equipment, warranties and repair history; QR stickers so staff can report a problem',
  'Maintenance plans your contractors propose and you accept',
  'Follow-through report: what your locations missed, and what it cost',
  'Unlimited service calls, all trades, unlimited people on your team',
];

export default function Demo() {
  const [busy, setBusy] = useState('');
  const [err, setErr] = useState('');
  const [plans, setPlans] = useState('business');
  const showPlans = (k) => {
    setPlans(k);
    setTimeout(() => document.getElementById('plans')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40);
  };
  // Links like /demo#contractors or #plans-business open the right tab
  useEffect(() => {
    const h = window.location.hash;
    if (h === '#contractors' || h === '#plans-contractors') showPlans('contractors');
    else if (h === '#plans-business' || h === '#pilot-stores') showPlans('business');
  }, []);

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
        <div className="demo-hero-text">
          <h1>Know who's in your building, for how long, and what it should cost.</h1>
          <p>Service Call Proof sits between your locations (stores, restaurants, clinics, dental offices, banks, offices) and your service contractors: every visit checked in with your code, every bill checked against the time actually spent.</p>
          <p className="small" style={{ marginTop: 10 }}><a href="#pilot-stores" onClick={(e) => { e.preventDefault(); setPlans('business'); setTimeout(() => document.getElementById('pilot-stores')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 40); }}><strong>Pilot locations wanted:</strong> 4 companies, free for the first year →</a></p>
        </div>
        <div className="demo-hero-plans">
          <div className="demo-hero-plans-h">Plans &amp; pricing</div>
          <button type="button" className="demo-plan-btn" onClick={() => showPlans('business')}>
            <strong>For businesses</strong><span>Stores, restaurants, clinics, dental offices, banks, offices</span></button>
          <button type="button" className="demo-plan-btn" onClick={() => showPlans('contractors')}>
            <strong>For contractors</strong><span>HVAC, refrigeration, plumbing, electrical</span></button>
        </div>
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
        <h3>Businesses</h3>
        <div className="demo-cards">{STORES.map((d) => <Card key={d.email} d={d} />)}</div>
        <h3>Contractors and technicians</h3>
        <div className="demo-cards">{CONTRACTORS.map((d) => <Card key={d.email} d={d} />)}</div>
      </section>

      <section className="demo-sec demo-plans" id="plans">
        <h2>Plans &amp; pricing</h2>
        <div className="demo-tabs" role="tablist">
          <button type="button" role="tab" aria-selected={plans === 'business'} className={plans === 'business' ? 'on' : ''} onClick={() => setPlans('business')}>For businesses</button>
          <button type="button" role="tab" aria-selected={plans === 'contractors'} className={plans === 'contractors' ? 'on' : ''} onClick={() => setPlans('contractors')}>For contractors</button>
        </div>

        {plans === 'business' && (
          <div className="demo-tab-body" id="plans-business">
            <div className="demo-biz-row">
            <div className="panel panel-pad stack demo-biz-plan">
              <div className="spread"><strong style={{ fontSize: 20 }}>Service Call Proof</strong><span className="demo-price">$395 <small>per location per year</small></span></div>
              <div className="muted">For any business with places to keep running: stores, restaurants, clinics, dental offices, banks and offices.</div>
              <ul className="plan-list">{BUSINESS_INCLUDES.map((i) => <li key={i}>{i}</li>)}</ul>
              <div><strong>Your contractors join free.</strong> <span className="muted">(For them it&apos;s our free Time Verify plan.)</span></div>
              <div className="demo-cta-row">
                <button type="button" className="primary big" disabled title="Coming soon">Get started now <span className="soon">Coming soon</span></button>
                <a className="button-like" href="mailto:sales@servicecallproof.com?subject=Service%20Call%20Proof%20questions">Questions? Talk to us</a>
              </div>
            </div>

            <div className="demo-extras">
              <div className="panel panel-pad stack" style={{ gap: 6 }}>
                <strong>Temperature monitoring <span className="soon">Coming soon</span></strong>
                <span className="small">Sensors in coolers, freezers or the whole building alert you and your contractor when it gets too hot or too cold. A furnace that quits over the weekend shouldn&apos;t mean a 45° office and cancelled appointments Monday morning. Available through contractors on Base or above.</span>
              </div>
              <div className="panel panel-pad stack" style={{ gap: 6 }}>
                <strong>Enhanced Time Verify <span className="chip tone-green">No extra charge</span></strong>
                <span className="small">When your contractor runs Service Call Proof Base or Pro, their bills come straight into your portal, already matched to the call and your PO, ready to download, export or forward to accounting.</span>
              </div>
            </div>
            </div>

            <StorePilot />
          </div>
        )}

        {plans === 'contractors' && (
          <div className="demo-tab-body" id="plans-contractors">
            <div className="demo-free-line"><strong>Free when your customer uses Service Call Proof.</strong> That&apos;s Time Verify: calls, check-ins and bills for that customer, at no cost to you, always. Base, Pro and Enterprise run your whole shop, and they&apos;re in pilot now.</div>
            <PilotOffer source="demo" current={null} />
            <div className="small muted">Want Time Verify with a customer who isn&apos;t on it yet? <a href="mailto:sales@servicecallproof.com?subject=Contractor%20interested">Tell us which customers</a> and we&apos;ll reach out.</div>
          </div>
        )}
      </section>
      <div style={{ padding: '0 16px 24px' }}><LegalFooter /></div>
    </main>
  );
}
