'use client';

// Contractor's first days: a one-time welcome (how a call works, in three pictures) and a getting-started checklist
// that ticks itself off. Shown to the contractor's owner/office; hide-able; disappears when everything's done.
import { useEffect, useState } from 'react';
import { supabase, q, act } from '@/lib/supabase';

const ls = {
  get: (k) => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch { /* fine */ } },
  del: (k) => { try { localStorage.removeItem(k); } catch { /* fine */ } },
};

export default function ContractorStart({ me, org, book, onGo }) {
  const cid = me.contractor_id;
  const [st, setSt] = useState(null);
  const [hidden, setHidden] = useState(true);
  const [welcome, setWelcome] = useState(false);
  const [, bump] = useState(0);
  const office = me.is_org_admin || me.can_dispatch;

  useEffect(() => {
    if (!office) return undefined;
    setHidden(ls.get(`scp_cgs_hide_${cid}`) === '1');
    setWelcome(ls.get(`scp_welcome_${cid}`) !== '1');
    let alive = true;
    (async () => {
      const custIds = (book || []).map((c) => c.customer_id);
      const cards = await Promise.all(custIds.map((id) => act('rate_card', { p_customer: id, p_contractor: cid }).catch(() => null)));
      const [cc, team, links] = await Promise.all([
        q(supabase.from('customer_contractors').select('terms_accepted_at').eq('contractor_id', cid).is('contractor_removed_at', null)),
        q(supabase.from('profiles').select('id, is_technician, active').eq('contractor_id', cid).eq('active', true)),
        q(supabase.from('join_links').select('kind, used_at, expires_at').eq('contractor_id', cid).neq('kind', 'contractor_owner').is('used_at', null)),
      ]);
      if (alive) setSt({
        terms: cc.length > 0 && cc.every((r) => r.terms_accepted_at),
        techs: team.filter((p) => p.is_technician && p.id !== me.id).length,
        pending: links.filter((l) => new Date(l.expires_at) > new Date()).length,
        rates: cards.length > 0 && cards.every((k) => k && (k.current || k.pending)),
        firstNoRates: custIds[cards.findIndex((k) => !(k && (k.current || k.pending)))] || null,
      });
    })().catch(() => {});
    return () => { alive = false; };
  }, [cid, me.id, office, (book || []).length]);

  if (!office || !st) return null;
  const justMe = ls.get(`scp_justme_${cid}`) === '1';
  const installed = ls.get('scp_installed') === '1' || (typeof window !== 'undefined' && window.matchMedia?.('(display-mode: standalone)').matches);
  const sawDemo = ls.get(`scp_sawhow_${cid}`) === '1';
  const stores = (book || []).map((c) => c.name);
  const storeText = stores.length === 0 ? 'Your customers' : stores.length === 1 ? stores[0] : `${stores.slice(0, -1).join(', ')} and ${stores[stores.length - 1]}`;

  const steps = [
    ['Accept your customer\'s terms', 'Done when you signed in with their link.', st.terms, () => onGo('customers')],
    ['Add your office phone', 'The number customers reach when they tap "Call them now".', !!org?.phone, () => onGo('team')],
    ['Enter your rates', 'What you charge each customer: labor, after hours, trip charge. They see it and accept it.', st.rates, () => onGo('customers', st.firstNoRates)],
    ['Add your technicians', 'Each tech gets their own sign-in link by text. Just you? Tick "It\'s just me".', st.techs > 0 || justMe, () => onGo('team')],
    ['Your techs sign in on their phones', st.pending ? `${st.pending} sign-in link${st.pending === 1 ? '' : 's'} not opened yet.` : 'Each tech opens their link once and taps Install.', justMe || (st.techs > 0 && st.pending === 0), () => onGo('team')],
    ['Put the app on your phone', 'Menu → Install on this phone (iPhone: Share → Add to Home Screen).', installed, null],
    ['See how a call works', 'Two minutes, hands-on: a tech checking in on site.', sawDemo, () => { ls.set(`scp_sawhow_${cid}`, '1'); window.open('/demo', '_blank'); bump((n) => n + 1); }],
  ];
  const done = steps.filter((s) => s[2]).length;

  const welcomeCard = welcome && (
    <div className="panel panel-pad stack cwel">
      <div className="spread"><h2 style={{ margin: 0 }}>Welcome{me.full_name ? `, ${me.full_name.split(' ')[0]}` : ''}</h2>
        <button className="linkish" onClick={() => { ls.set(`scp_welcome_${cid}`, '1'); setWelcome(false); }}>Got it</button></div>
      <div>{storeText} {stores.length === 1 ? 'sends' : 'send'} you service calls here. <strong>It's free for you.</strong> Here's how every call goes:</div>
      <div className="cwel-steps">
        <div><span className="cwel-ic">📥</span><strong>1. A call comes in</strong><span className="small muted">You get an alert. Tap Accept before the customer's deadline shown on the call.</span></div>
        <div><span className="cwel-ic">🔧</span><strong>2. Send a tech</strong><span className="small muted">They tap I'm going, then check in on site with the location's code.</span></div>
        <div><span className="cwel-ic">🧾</span><strong>3. Send your bill</strong><span className="small muted">Agree to the verified hours, then add your invoice # and total. Bills that match get approved fastest.</span></div>
      </div>
      <div className="small"><a href="/quickstart" target="_blank" rel="noreferrer">Print the one-page quick start</a> for your techs · <a href="/help?for=contractor" target="_blank" rel="noreferrer">How-to guide</a></div>
    </div>
  );

  if (done === steps.length) return welcomeCard || null;
  if (hidden) {
    return (
      <>
        {welcomeCard}
        <div style={{ marginBottom: 12 }}><button className="gs-pill" onClick={() => { ls.del(`scp_cgs_hide_${cid}`); setHidden(false); }}>
          ✓ Getting started: {steps.length - done} step{steps.length - done === 1 ? '' : 's'} left · Show
        </button></div>
      </>
    );
  }
  return (
    <>
      {welcomeCard}
      <div className="panel panel-pad stack gs" style={{ marginBottom: 14 }}>
        <div className="spread">
          <div><h3>Getting started</h3><div className="small muted">{done} of {steps.length} done. About 10 minutes.</div></div>
          <button className="linkish" onClick={() => { ls.set(`scp_cgs_hide_${cid}`, '1'); setHidden(true); }}>Hide for now</button>
        </div>
        <div className="gs-bar"><span style={{ width: `${(done / steps.length) * 100}%` }} /></div>
        <div className="gs-list">
          {steps.map(([t, d, ok, go]) => (
            <button key={t} className={`gs-step${ok ? ' ok' : ''}`} onClick={go || undefined} style={go ? undefined : { cursor: 'default' }}>
              <span className="gs-tick">{ok ? '✓' : ''}</span>
              <span><strong>{t}</strong><span className="small muted">{d}</span></span>
            </button>
          ))}
        </div>
        {!(st.techs > 0) && !justMe && (
          <label className="row small" style={{ gap: 6, fontWeight: 400 }}>
            <input type="checkbox" style={{ width: 'auto' }} onChange={(e) => { if (e.target.checked) ls.set(`scp_justme_${cid}`, '1'); else ls.del(`scp_justme_${cid}`); bump((n) => n + 1); }} />
            It's just me: I go on the calls myself
          </label>
        )}
        {!installed && <label className="row small" style={{ gap: 6, fontWeight: 400 }}>
          <input type="checkbox" style={{ width: 'auto' }} onChange={(e) => { if (e.target.checked) ls.set('scp_installed', '1'); else ls.del('scp_installed'); bump((n) => n + 1); }} />
          I put the app on my phone already
        </label>}
      </div>
    </>
  );
}
