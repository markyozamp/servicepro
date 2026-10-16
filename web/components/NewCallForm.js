'use client';

import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money, PRIORITY } from '@/lib/format';
import { ErrorBox } from './bits';

export default function NewCallForm({ side, profile, onCreated, onCancel }) {
  const [sites, setSites] = useState([]);
  const [issues, setIssues] = useState([]);
  const [equipment, setEquipment] = useState([]);
  const [warranty, setWarranty] = useState([]);
  const [amount, setAmount] = useState(null);
  const [f, setF] = useState({ site: '', issue: '', equipment: '', details: '', po: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });

  const site = sites.find((s) => s.id === f.site);
  const issue = issues.find((i) => i.id === f.issue);
  const residential = site?.customers?.kind === 'residential';

  useEffect(() => {
    Promise.all([
      q(supabase.from('sites').select('id, name, address, customer_id, customers(name, kind)').order('name')),
      q(supabase.from('issue_types').select('*').eq('active', true).order('sort')),
    ]).then(([s, i]) => {
      setSites(s);
      setIssues(i);
      if (s.length === 1) setF((x) => ({ ...x, site: s[0].id }));
    }).catch((e) => setErr(e.message));
  }, []);

  useEffect(() => {
    setEquipment([]); setWarranty([]);
    if (!f.site) return;
    q(supabase.from('equipment').select('id, manufacturer, model, location_description, equipment_types(code, name)').eq('site_id', f.site))
      .then(setEquipment).catch(() => {});
  }, [f.site]);

  // Show the authorized diagnosis amount as soon as the problem is picked
  useEffect(() => {
    setAmount(null);
    if (!f.site || !f.issue) return;
    (async () => {
      const contractor = profile?.contractor_id || (await q(supabase.from('customer_contractors').select('contractor_id, is_primary')
        .eq('customer_id', site.customer_id).order('is_primary', { ascending: false }).limit(1)))[0]?.contractor_id;
      if (!contractor) return;
      const a = await act('diagnosis_amount', { p_site: f.site, p_issue: f.issue, p_contractor: contractor, p_at: new Date().toISOString() });
      setAmount(a);
    })().catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [f.site, f.issue]);

  useEffect(() => {
    setWarranty([]);
    if (!f.equipment) return;
    q(supabase.from('warranties').select('kind, ends_on, description').eq('equipment_id', f.equipment)
      .gte('ends_on', new Date().toISOString().slice(0, 10))).then(setWarranty).catch(() => {});
  }, [f.equipment]);

  const shownIssues = issues.filter((i) => (residential ? i.for_residential : i.for_commercial));
  const suggested = issue ? equipment.filter((e) => e.equipment_types?.code === issue.equipment_type_code) : [];

  async function submit(e) {
    e.preventDefault();
    setBusy(true); setErr('');
    try {
      const wo = await act('create_work_order', {
        p_site: f.site, p_issue_type: f.issue || null, p_description: f.details.trim() || null,
        p_equipment: f.equipment || null, p_store_po_number: f.po.trim() || null,
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
        <select value={f.site} onChange={(e) => setF({ ...f, site: e.target.value, equipment: '', issue: '' })} required>
          <option value="">Choose a location…</option>
          {sites.map((s) => (
            <option key={s.id} value={s.id}>{side === 'office' && s.customers ? `${s.customers.name} — ` : ''}{s.name} · {s.address}</option>
          ))}
        </select>
      </label>
      <label>
        What's the problem?
        <select value={f.issue} onChange={set('issue')} required disabled={!f.site}>
          <option value="">Choose…</option>
          {shownIssues.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
        </select>
      </label>
      {issue && (
        <div className="row small" style={{ gap: 8 }}>
          <span className={`chip ${issue.priority === 1 ? 'tone-red' : 'tone-slate'}`}>{PRIORITY[issue.priority]}</span>
          {amount != null && <span>Diagnosis authorized up to <strong>{money(amount)}</strong></span>}
        </div>
      )}
      <label>
        Which unit? <span className="muted" style={{ fontWeight: 400 }}>(optional — the technician will photograph it)</span>
        <select value={f.equipment} onChange={set('equipment')} disabled={!f.site}>
          <option value="">Not sure / not listed</option>
          {[...suggested, ...equipment.filter((e) => !suggested.includes(e))].map((q2) => (
            <option key={q2.id} value={q2.id}>
              {q2.equipment_types?.name} — {q2.manufacturer} {q2.model}{q2.location_description ? ` (${q2.location_description})` : ''}
            </option>
          ))}
        </select>
      </label>
      {warranty.length > 0 && (
        <div className="notice"><strong>This unit is under warranty:</strong> {warranty.map((w) => `${w.kind} until ${w.ends_on}`).join(', ')}. The contractor will see this too.</div>
      )}
      <label>
        Details <span className="muted" style={{ fontWeight: 400 }}>(optional)</span>
        <textarea value={f.details} onChange={set('details')} placeholder="e.g. Reading 20°F, normally -5°F. Product moved to the cooler." />
      </label>
      {!residential && (
        <label>
          Your PO number <span className="muted" style={{ fontWeight: 400 }}>(optional — otherwise we number it for you)</span>
          <input value={f.po} onChange={set('po')} />
        </label>
      )}
      <div className="small muted">
        The technician cannot go past the authorized amount. If more is needed, you'll be asked to approve it (PO A, B…), with photos and a price.
      </div>
      <button className="primary big" disabled={busy}>{busy ? 'Sending…' : 'Send service call'}</button>
    </form>
  );
}
