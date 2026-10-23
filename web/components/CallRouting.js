'use client';

// Contractor: "Who gets the calls". The office phone works now (stores' "Call them now" and "Call office" buttons dial it).
// After-hours number, on-call person and automatic phone calls are shown as coming soon.
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
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const can = profile?.is_org_admin || profile?.can_dispatch;
  useEffect(() => {
    q(supabase.from('contractors').select('phone').eq('id', profile.contractor_id).single()).then((r) => { setPhone(r?.phone || ''); setSaved(r?.phone || ''); }).catch((e) => setErr(e.message));
  }, [profile.contractor_id]);

  async function save() {
    setErr(''); setMsg('');
    try { await act('set_contractor_office_phone', { p_phone: phone }); setSaved(phone); setMsg('Office phone saved.'); } catch (e) { setErr(e.message); }
  }

  return (
    <div className="panel panel-pad stack" style={{ marginBottom: 16 }}>
      <h3>Who gets the calls <Info title="Who gets the calls">The number your stores reach when they tap "Call them now" on a service call, or "Call office" when one of your people shows up unexpected. Soon you'll add an after-hours number and who's on call, and Service Call Proof will phone you automatically when a call isn't accepted in time.</Info></h3>
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      <div className="row" style={{ alignItems: 'flex-end' }}>
        <label className="grow">Office phone (business hours)<input type="tel" value={phone} disabled={!can} onChange={(e) => setPhone(e.target.value)} placeholder="701-555-0100" /></label>
        {can && <button className="primary" disabled={phone === saved} onClick={save}>Save</button>}
      </div>
      <div className="row soon-row">
        <label className="grow">After-hours number<input disabled placeholder="Coming soon" /></label>
        <label className="grow">On call now<select disabled><option>Coming soon</option></select></label>
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
