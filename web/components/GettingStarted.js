'use client';

// New store accounts: a short checklist of the first things to set up. Disappears when done or dismissed.
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';

export default function GettingStarted({ me, onGo, onNewCall }) {
  const [st, setSt] = useState(null);
  const key = `scp_gs_hide_${me.customer_id}`;
  const [hidden, setHidden] = useState(true);

  useEffect(() => {
    let alive = true;
    try { setHidden(localStorage.getItem(key) === '1'); } catch { setHidden(false); }
    (async () => {
      const [sites, cc, eq, team, calls] = await Promise.all([
        q(supabase.from('sites').select('id, lat')),
        q(supabase.from('customer_contractors').select('contractor_id')),
        q(supabase.from('equipment').select('id').is('retired_at', null).limit(1)),
        q(supabase.from('profiles').select('id').eq('customer_id', me.customer_id).eq('active', true)),
        q(supabase.from('work_orders').select('id').limit(1)),
      ]);
      const pins = await Promise.all(sites.map((s) => act('site_has_report_pin', { p_site: s.id }).catch(() => false)));
      if (alive) setSt({ sites: sites.length, mapped: sites.every((s) => s.lat != null), cc: cc.length, pin: pins.some(Boolean), eq: eq.length, team: team.length, calls: calls.length });
    })().catch(() => {});
    return () => { alive = false; };
  }, [me.customer_id, key]);

  if (!st || hidden || !me.is_org_admin) return null;
  const steps = [
    ['Add your locations', 'Every store or building, with its address.', st.sites > 0 && st.mapped, () => onGo('locations')],
    ['Invite your contractors', 'One for each trade. It\'s free for them.', st.cc > 0, () => onGo('contractors')],
    ['Set your store PIN for QR stickers', 'So employees can report problems by scanning a unit.', st.pin, () => onGo('contractors')],
    ['List your equipment', 'Start with the units that break most. Contractors add the rest on visits.', st.eq > 0, () => onGo('equipment')],
    ['Add your team', 'Store managers, maintenance, a director. One login per location is included.', st.team > 1, () => onGo('team')],
    ['Open your first service call', 'See it go to your contractor and track it to the invoice.', st.calls > 0, onNewCall],
  ];
  const done = steps.filter((s) => s[2]).length;
  if (done === steps.length) return null;
  return (
    <div className="panel panel-pad stack gs">
      <div className="spread">
        <div><h3>Getting started</h3><div className="small muted">{done} of {steps.length} done. About 15 minutes for everything.</div></div>
        <button className="linkish" onClick={() => { try { localStorage.setItem(key, '1'); } catch { /* fine */ } setHidden(true); }}>Hide this</button>
      </div>
      <div className="gs-bar"><span style={{ width: `${(done / steps.length) * 100}%` }} /></div>
      <div className="gs-list">
        {steps.map(([t, d, ok, go]) => (
          <button key={t} className={`gs-step${ok ? ' ok' : ''}`} onClick={go}>
            <span className="gs-tick">{ok ? '✓' : ''}</span>
            <span><strong>{t}</strong><span className="small muted">{d}</span></span>
          </button>
        ))}
      </div>
    </div>
  );
}
