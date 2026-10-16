'use client';

import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { EQUIPMENT_LABEL } from '@/lib/format';
import { ErrorBox } from './bits';

export default function NewCallForm({ side, onCreated, onCancel }) {
  const [sites, setSites] = useState([]);
  const [equipment, setEquipment] = useState([]);
  const [f, setF] = useState({ site: '', equipment: '', issue: '', priority: 2, po_number: '', po_cap: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });

  useEffect(() => {
    q(supabase.from('sites').select('id, name, address, customers(name)').order('name'))
      .then((s) => {
        setSites(s);
        if (s.length === 1) setF((x) => ({ ...x, site: s[0].id }));
      })
      .catch((e) => setErr(e.message));
  }, []);

  useEffect(() => {
    if (!f.site) return setEquipment([]);
    q(supabase.from('equipment').select('id, type, manufacturer, model, location_description').eq('site_id', f.site))
      .then(setEquipment)
      .catch(() => setEquipment([]));
  }, [f.site]);

  async function submit(e) {
    e.preventDefault();
    setBusy(true);
    setErr('');
    try {
      const wo = await act('create_work_order', {
        p_site: f.site,
        p_issue: f.issue,
        p_equipment: f.equipment || null,
        p_priority: Number(f.priority),
        p_po_number: f.po_number.trim() || null,
        p_po_cap: f.po_cap ? Number(f.po_cap) : null,
      });
      onCreated && onCreated(wo);
    } catch (e2) {
      setErr(e2.message);
      setBusy(false);
    }
  }

  return (
    <form className="panel panel-pad stack" onSubmit={submit}>
      <div className="spread">
        <h2>New service call</h2>
        <button type="button" onClick={onCancel}>Close</button>
      </div>
      <ErrorBox error={err} />
      <label>
        Location
        <select value={f.site} onChange={set('site')} required>
          <option value="">Choose a store…</option>
          {sites.map((s) => (
            <option key={s.id} value={s.id}>
              {side === 'office' && s.customers ? `${s.customers.name} — ` : ''}{s.name} · {s.address}
            </option>
          ))}
        </select>
      </label>
      <label>
        Equipment <span className="muted" style={{ fontWeight: 400 }}>(optional — the technician will photograph it)</span>
        <select value={f.equipment} onChange={set('equipment')} disabled={!f.site}>
          <option value="">Not sure / not listed</option>
          {equipment.map((q2) => (
            <option key={q2.id} value={q2.id}>
              {EQUIPMENT_LABEL(q2.type)} — {q2.manufacturer} {q2.model}{q2.location_description ? ` (${q2.location_description})` : ''}
            </option>
          ))}
        </select>
      </label>
      <label>
        What's wrong?
        <textarea value={f.issue} onChange={set('issue')} required placeholder="e.g. Dairy case reading 48°F, normally 36°F. Fans running." />
      </label>
      <div className="row">
        <span className="small" style={{ fontWeight: 600, color: 'var(--ink-2)' }}>Priority</span>
        <div className="seg">
          {[[1, 'Emergency'], [2, 'Normal'], [3, 'Low']].map(([v, l]) => (
            <button type="button" key={v} className={Number(f.priority) === v ? 'on' : ''} onClick={() => setF({ ...f, priority: v })}>{l}</button>
          ))}
        </div>
      </div>
      <div className="row">
        <label className="grow">
          PO number
          <input value={f.po_number} onChange={set('po_number')} placeholder="optional" />
        </label>
        <label className="grow">
          Spending cap ($)
          <input type="number" min="1" step="1" value={f.po_cap} onChange={set('po_cap')} placeholder="optional" />
        </label>
      </div>
      <div className="small muted">
        With a cap, the technician cannot finish over this amount without your approval. You'll get a warning at 80%.
      </div>
      <button className="primary big" disabled={busy}>{busy ? 'Sending…' : 'Send service call'}</button>
    </form>
  );
}
