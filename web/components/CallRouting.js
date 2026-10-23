'use client';

// Contractor: "Who gets the calls". The office phone works now (stores' "Call them now" and "Call office" buttons dial it).
// After-hours number, on-call person and automatic phone calls are shown as coming soon.
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { ErrorBox, Notice } from './bits';
import Info from './Info';

export default function CallRouting({ profile }) {
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
      <div className="row soon">
        <label className="grow">After-hours number<input disabled placeholder="Coming soon" /></label>
        <label className="grow">On call now<select disabled><option>Coming soon</option></select></label>
      </div>
      <label className="row small soon" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" disabled style={{ width: 'auto' }} />
        Phone me automatically when a new call isn't accepted in time (press 1 to accept) — coming soon</label>
    </div>
  );
}
