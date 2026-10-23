'use client';

// Contractor owner: your people (add a tech by phone → they get a sign-in link), and your terms with each Time Verify store.
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { ErrorBox, Notice } from './bits';

export default function TeamPanel({ profile }) {
  const [people, setPeople] = useState([]);
  const [links, setLinks] = useState([]);
  const [terms, setTerms] = useState([]);
  const [add, setAdd] = useState(null);
  const [sent, setSent] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const [alerts, setAlerts] = useState(null);
  const admin = profile?.is_org_admin;

  async function load() {
    try {
      const [p, l, t] = await Promise.all([
        q(supabase.from('profiles').select('id, full_name, phone, email, is_technician, can_dispatch, is_org_admin, active').eq('contractor_id', profile.contractor_id).order('full_name')),
        admin ? q(supabase.from('join_links').select('token, full_name, phone, email, used_at, expires_at, kind').neq('kind', 'contractor_owner').is('used_at', null).order('created_at', { ascending: false })) : Promise.resolve([]),
        q(supabase.from('customer_contractors').select('customer_id, mode, min_hours, increment_min, pays_travel, customers(name)').eq('contractor_id', profile.contractor_id).is('contractor_removed_at', null)),
      ]);
      setPeople(p); setLinks(l.filter((x) => new Date(x.expires_at) > new Date())); setTerms(t);
      const c = await q(supabase.from('contractors').select('tech_call_alerts').eq('id', profile.contractor_id));
      setAlerts(c[0]?.tech_call_alerts ?? null);
    } catch (x) { setErr(x.message); }
  }
  useEffect(() => { load(); // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function run(fn, args, done) {
    setBusy(true); setErr(''); setMsg('');
    try { const r = await act(fn, args); if (done) done(r); await load(); } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  const url = (tok) => `${window.location.origin}/join/${tok}`;

  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="panel panel-pad stack">
        <h2>Your team</h2>
        <ErrorBox error={err} /><Notice>{msg}</Notice>
        <table><tbody>
          {people.map((p) => (
            <tr key={p.id}>
              <td><strong>{p.full_name}</strong><div className="small muted">{[p.is_org_admin && 'owner', p.can_dispatch && 'office', p.is_technician && 'technician'].filter(Boolean).join(' · ')}</div></td>
              <td className="small">{p.phone || ''}{p.email && !p.email.endsWith('servicepro.app') ? <div className="muted">{p.email}</div> : null}</td>
              <td className="num">{admin && p.id !== profile.id && (
                <button disabled={busy} onClick={() => run('new_signin_link', { p_profile: p.id }, (tok) => setSent({ token: tok, name: p.full_name, phone: p.phone, email: p.email }))}>New sign-in link</button>)}</td>
            </tr>
          ))}
        </tbody></table>
        {sent && (
          <div className="notice stack" style={{ gap: 6 }}>
            <div>Send this sign-in link to <strong>{sent.name}</strong>. It works once, on the phone they open it on, for 7 days. No password.</div>
            <input readOnly value={url(sent.token)} onFocus={(e) => e.target.select()} />
            <div className="row">
              <button onClick={() => navigator.clipboard?.writeText(url(sent.token)).then(() => setMsg('Link copied.'))}>Copy link</button>
              {sent.phone && <a href={`sms:${sent.phone}?&body=${encodeURIComponent(`Your Service Call Proof sign-in link: ${url(sent.token)}`)}`}><button type="button">Text it from this phone</button></a>}
              {sent.email && !sent.email.endsWith('servicepro.app') && <a href={`mailto:${sent.email}?subject=Service Call Proof sign-in&body=${encodeURIComponent(url(sent.token))}`}><button type="button">Email it</button></a>}
              <button onClick={() => setSent(null)}>Done</button>
            </div>
          </div>
        )}
        {admin && (add ? (
          <form className="stack" style={{ gap: 6 }} onSubmit={(e) => {
            e.preventDefault();
            run('add_team_member', { p_name: add.name, p_phone: add.phone || null, p_email: add.email || null, p_technician: add.tech, p_office: add.office },
              (tok) => { setSent({ token: tok, name: add.name, phone: add.phone, email: add.email }); setAdd(null); });
          }}>
            <div className="row">
              <label className="grow">Name<input value={add.name} onChange={(e) => setAdd({ ...add, name: e.target.value })} required /></label>
              <label className="grow">Mobile number<input value={add.phone} onChange={(e) => setAdd({ ...add, phone: e.target.value })} /></label>
              <label className="grow">Email (optional)<input type="email" value={add.email} onChange={(e) => setAdd({ ...add, email: e.target.value })} /></label>
            </div>
            <div className="row" style={{ gap: 12 }}>
              <label className="row small" style={{ gap: 4, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={add.tech} onChange={(e) => setAdd({ ...add, tech: e.target.checked })} /> Technician</label>
              <label className="row small" style={{ gap: 4, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={add.office} onChange={(e) => setAdd({ ...add, office: e.target.checked })} /> Office (dispatch)</label>
            </div>
            <div className="row"><button className="primary" disabled={busy}>Create sign-in link</button><button type="button" onClick={() => setAdd(null)}>Cancel</button></div>
          </form>
        ) : <button onClick={() => setAdd({ name: '', phone: '', email: '', tech: true, office: false })}>+ Add a technician</button>)}
        {links.length > 0 && <div className="small muted">Links not used yet: {links.map((l) => l.full_name).join(', ')}</div>}
        {admin && alerts !== null && (
          <label className="row small" style={{ gap: 6, fontWeight: 400 }}>
            <input type="checkbox" style={{ width: 'auto' }} checked={alerts} disabled={busy}
              onChange={(e) => run('set_tech_call_alerts', { p_on: e.target.checked })} />
            Alert my technicians about new Time Verify calls (so they can take them with "I'm going")
          </label>
        )}
      </div>

      {terms.some((t) => t.mode === 'verify') && (
        <div className="panel panel-pad stack">
          <h2>Your terms with Time Verify stores</h2>
          <div className="small muted">Used to work out the billable time the store expects from the verified time (your minimum per visit and billing steps).</div>
          {terms.filter((t) => t.mode === 'verify').map((t) => (
            <div key={t.customer_id} className="row">
              <strong className="grow">{t.customers?.name}<div className="small muted" style={{ fontWeight: 400 }}>{t.pays_travel === 'no' ? 'They do not pay travel' : t.pays_travel === 'after_hours' ? 'They pay travel after hours only' : 'They pay travel'}</div></strong>
              <label style={{ width: 130 }}>Minimum (h)<input type="number" step="0.25" min="0" max="8" defaultValue={t.min_hours} id={`mh-${t.customer_id}`} disabled={!admin && !profile.can_bill} /></label>
              <label style={{ width: 130 }}>Steps (min)
                <select defaultValue={t.increment_min} id={`inc-${t.customer_id}`} disabled={!admin && !profile.can_bill}>
                  {[1, 5, 6, 10, 15, 30, 60].map((n) => <option key={n} value={n}>{n}</option>)}
                </select></label>
              {(admin || profile.can_bill) && <button disabled={busy} onClick={() => run('set_my_terms', { p_customer: t.customer_id,
                p_min_hours: Number(document.getElementById(`mh-${t.customer_id}`).value), p_increment_min: Number(document.getElementById(`inc-${t.customer_id}`).value) },
                () => setMsg(`Saved your terms with ${t.customers?.name}.`))}>Save</button>}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
