'use client';

// Contractor: "Who gets the calls". The office phone works now (stores' "Call them now" and "Call office" buttons dial it).
// After hours: an after-hours number (customers dial it on after-hours calls) and who's on call (alerted first on
// after-hours calls). Automatic phone calls (press 1 to accept) are coming with the phone service.
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { ErrorBox, Notice } from './bits';
import Info from './Info';

async function toDataUrl(file) {
  if (file.type === 'image/svg+xml') {
    if (file.size > 250000) throw new Error('That SVG is too large. Use one under 250 KB.');
    const d = await new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = rej; r.readAsDataURL(file); });
    return d.replace(/^data:image\/svg\+xml(;[^,]*)?,/, 'data:image/svg+xml;base64,');
  }
  const img = await createImageBitmap(file);
  const k = Math.min(1, 600 / img.width, 160 / img.height);
  const c = document.createElement('canvas');
  c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
  c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
  let d = c.toDataURL('image/png');
  if (d.length > 380000) d = c.toDataURL('image/jpeg', 0.85);
  return d;
}

export default function CallRouting({ profile, logo, onLogo }) {
  const [phone, setPhone] = useState('');
  const [saved, setSaved] = useState('');
  const [ah, setAh] = useState('');
  const [ahSaved, setAhSaved] = useState('');
  const [team, setTeam] = useState([]);
  const [rota, setRota] = useState([]);
  const today = new Date().toISOString().slice(0, 10);
  const [oc, setOc] = useState({ who: '', from: today, to: new Date(Date.now() + 6 * 86400000).toISOString().slice(0, 10) });
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const can = profile?.is_org_admin || profile?.can_dispatch;
  useEffect(() => {
    q(supabase.from('contractors').select('phone, after_hours_phone').eq('id', profile.contractor_id).single()).then((r) => {
      setPhone(r?.phone || ''); setSaved(r?.phone || ''); setAh(r?.after_hours_phone || ''); setAhSaved(r?.after_hours_phone || '');
    }).catch((e) => setErr(e.message));
    q(supabase.from('profiles').select('id, full_name').eq('contractor_id', profile.contractor_id).eq('active', true).order('full_name')).then(setTeam).catch(() => {});
    loadRota();
  }, [profile.contractor_id]); // eslint-disable-line react-hooks/exhaustive-deps

  function loadRota() {
    q(supabase.from('oncall').select('id, starts_on, ends_on, profiles!oncall_profile_id_fkey(full_name)').eq('contractor_id', profile.contractor_id).eq('cancelled', false)
      .gte('ends_on', new Date().toISOString().slice(0, 10)).order('starts_on')).then(setRota).catch(() => {});
  }
  const nowOn = rota.find((r) => r.starts_on <= today && r.ends_on >= today);
  const day = (d) => new Date(`${d}T12:00`).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });

  async function save() {
    setErr(''); setMsg('');
    try { await act('set_contractor_office_phone', { p_phone: phone }); setSaved(phone); setMsg('Office phone saved.'); } catch (e) { setErr(e.message); }
  }

  return (
    <div className="panel panel-pad stack" style={{ marginBottom: 16 }}>
      <h3>Who gets the calls <Info title="Who gets the calls">The number your customers reach when they tap "Call them now" on a service call, or "Call office" when one of your people shows up unexpected. On after-hours calls, customers see your after-hours number instead, and whoever is on call is alerted first. Each customer sets your regular hours with them; outside those hours a call is after hours. Coming: Service Call Proof phones you automatically when a call isn't accepted in time.</Info></h3>
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      <div className="row" style={{ alignItems: 'flex-end' }}>
        <label className="grow">Office phone (business hours)<input type="tel" value={phone} disabled={!can} onChange={(e) => setPhone(e.target.value)} placeholder="701-555-0100" /></label>
        {can && <button className="primary" disabled={phone === saved} onClick={save}>Save</button>}
      </div>
      <div className="row" style={{ alignItems: 'flex-end' }}>
        <label className="grow">After-hours number <span className="muted" style={{ fontWeight: 400 }}>(your answering service or on-call cell)</span>
          <input type="tel" value={ah} disabled={!can} onChange={(e) => setAh(e.target.value)} placeholder="701-555-0199" /></label>
        {can && <button className="primary" disabled={ah === ahSaved} onClick={async () => {
          setErr(''); setMsg('');
          try { await act('set_after_hours_phone', { p_phone: ah }); setAhSaved(ah); setMsg('After-hours number saved. Customers see it on after-hours calls.'); } catch (e) { setErr(e.message); }
        }}>Save</button>}
      </div>
      <div className="stack" style={{ gap: 6 }}>
        <div className="small"><strong>On call</strong> <span className="muted">— gets new after-hours calls first, on his phone, along with your office.</span>
          {' '}{nowOn ? <span className="chip tone-green">Now: {nowOn.profiles?.full_name}</span> : <span className="chip tone-amber">Nobody on call today</span>}</div>
        {rota.map((r) => (
          <div key={r.id} className="row small" style={{ gap: 8 }}>
            <span className="grow">{r.profiles?.full_name}: {day(r.starts_on)} – {day(r.ends_on)}</span>
            {can && <button className="linkbtn small" onClick={async () => { try { await act('cancel_oncall', { p_id: r.id }); loadRota(); } catch (e) { setErr(e.message); } }}>Remove</button>}
          </div>
        ))}
        {can && (
          <div className="row" style={{ alignItems: 'flex-end' }}>
            <label className="grow">Who<select value={oc.who} onChange={(e) => setOc({ ...oc, who: e.target.value })}><option value="">Pick…</option>{team.map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}</select></label>
            <label>From<input type="date" value={oc.from} onChange={(e) => setOc({ ...oc, from: e.target.value })} /></label>
            <label>Through<input type="date" value={oc.to} onChange={(e) => setOc({ ...oc, to: e.target.value })} /></label>
            <button disabled={!oc.who} onClick={async () => {
              setErr(''); setMsg('');
              try { await act('save_oncall', { p_profile: oc.who, p_starts: oc.from, p_ends: oc.to }); setMsg('On-call schedule saved.'); setOc({ ...oc, who: '' }); loadRota(); } catch (e) { setErr(e.message); }
            }}>Add</button>
          </div>
        )}
      </div>
      <label className="row small soon-row" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" disabled style={{ width: 'auto' }} />
        Phone me automatically when a new call isn't accepted in time (press 1 to accept) — coming soon</label>

      {profile?.is_org_admin && (
        <div className="stack" style={{ gap: 6, borderTop: '1px solid var(--line)', paddingTop: 10 }}>
          <h3>Your logo <Info title="Your logo">Optional. Shows at the top of your office screen instead of your company name. A wide logo works best (about 4 times wider than tall). PNG, JPG or SVG.</Info></h3>
          {logo && <img className="org-logo" src={logo} alt="Your logo" />}
          <div className="row">
            <label className="button-like">{logo ? 'Replace logo' : 'Upload logo'}<input type="file" accept="image/png,image/jpeg,image/svg+xml,image/webp" style={{ display: 'none' }}
              onChange={async (e) => { setErr(''); setMsg(''); try { const d = await toDataUrl(e.target.files[0]); await act('set_contractor_logo', { p_data: d }); onLogo?.(d); setMsg('Logo saved.'); } catch (x) { setErr(x.message); } e.target.value = ''; }} /></label>
            {logo && <button onClick={async () => { try { await act('set_contractor_logo', { p_data: null }); onLogo?.(null); setMsg('Logo removed.'); } catch (x) { setErr(x.message); } }}>Remove</button>}
          </div>
        </div>
      )}
    </div>
  );
}
