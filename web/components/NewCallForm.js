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
  const [f, setF] = useState({ site: '', issue: '', equipment: '', details: '', po: '', unit: '', contact: '', phone: '', entry: '' });
  const [home, setHome] = useState(null); // office: adding a one-off homeowner
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });

  const site = sites.find((s) => s.id === f.site);
  const issue = issues.find((i) => i.id === f.issue);
  const residential = (site?.property_type || site?.customers?.kind) === 'residential';
  const oneOff = site?.customers?.kind === 'residential';
  const propertyMgr = site?.customers?.kind === 'property_manager';

  const loadSites = () => q(supabase.from('sites').select('id, name, address, customer_id, property_type, customers(name, kind, phone)').order('name'));
  useEffect(() => {
    Promise.all([loadSites(), q(supabase.from('issue_types').select('*').eq('active', true).order('sort'))])
      .then(([s, i]) => {
        setSites(s);
        setIssues(i);
        if (s.length === 1) setF((x) => ({ ...x, site: s[0].id }));
      }).catch((e) => setErr(e.message));
  }, []);

  async function addHome(e) {
    e.preventDefault();
    setBusy(true); setErr('');
    try {
      const s = await act('quick_customer', { p_name: home.name, p_address: home.address, p_zip: home.zip || null, p_phone: home.phone || null });
      setSites(await loadSites());
      setF((x) => ({ ...x, site: s.id, issue: '', equipment: '', contact: home.name, phone: home.phone || '' }));
      setHome(null);
    } catch (e2) {
      setErr(e2.message);
    } finally {
      setBusy(false);
    }
  }

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
      if (f.unit.trim() || f.contact.trim() || f.phone.trim() || f.entry.trim()) {
        await act('set_call_contact', { p_wo: wo.id, p_unit: f.unit, p_contact_name: f.contact, p_contact_phone: f.phone, p_entry_notes: f.entry });
      }
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
      {home ? (
        <div className="stack" style={{ background: 'var(--bg)', borderRadius: 8, padding: 12 }}>
          <strong>New homeowner</strong>
          <div className="small muted">They won't need an account. They'll get updates and approve any quote from a link.</div>
          <input placeholder="Name" value={home.name} onChange={(e) => setHome({ ...home, name: e.target.value })} />
          <input placeholder="Street address, city, state" value={home.address} onChange={(e) => setHome({ ...home, address: e.target.value })} />
          <div className="row">
            <input className="grow" placeholder="ZIP" value={home.zip} onChange={(e) => setHome({ ...home, zip: e.target.value })} />
            <input className="grow" placeholder="Mobile phone" value={home.phone} onChange={(e) => setHome({ ...home, phone: e.target.value })} />
          </div>
          <div className="row">
            <button type="button" className="primary" disabled={busy || !home.name.trim() || !home.address.trim()} onClick={addHome}>Add homeowner</button>
            <button type="button" onClick={() => setHome(null)}>Cancel</button>
          </div>
        </div>
      ) : (
        <label>
          Location
          <select value={f.site} onChange={(e) => {
            const s = sites.find((x) => x.id === e.target.value);
            const one = s?.customers?.kind === 'residential';
            setF({ ...f, site: e.target.value, equipment: '', issue: '', contact: one ? s.customers.name : f.contact, phone: one ? (s.customers.phone || '') : f.phone });
          }} required>
            <option value="">Choose a location…</option>
            {sites.map((s) => (
              <option key={s.id} value={s.id}>{side === 'office' && s.customers ? `${s.customers.name} — ` : ''}{s.name} · {s.address}</option>
            ))}
          </select>
          {side === 'office' && (
            <button type="button" style={{ marginTop: 6, alignSelf: 'flex-start' }} onClick={() => setHome({ name: '', address: '', zip: '', phone: '' })}>
              + New homeowner (one-time customer)
            </button>
          )}
        </label>
      )}
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
      {(propertyMgr || oneOff || side === 'office') && f.site && (
        <div className="stack" style={{ gap: 8 }}>
          <div className="row">
            {!oneOff && (
              <label className="grow">
                Unit / suite <span className="muted" style={{ fontWeight: 400 }}>(optional)</span>
                <input value={f.unit} onChange={set('unit')} placeholder="e.g. 3B" />
              </label>
            )}
            <label className="grow">
              {oneOff ? 'Homeowner' : 'Who to meet'} <span className="muted" style={{ fontWeight: 400 }}>{oneOff ? '' : '(tenant, super…)'}</span>
              <input value={f.contact} onChange={set('contact')} />
            </label>
            <label className="grow">
              Phone
              <input value={f.phone} onChange={set('phone')} />
            </label>
          </div>
          <label>
            Entry notes <span className="muted" style={{ fontWeight: 400 }}>(optional)</span>
            <input value={f.entry} onChange={set('entry')} placeholder="e.g. Tenant home after 3 pm; dog in unit" />
          </label>
        </div>
      )}
      {!oneOff && (
        <label>
          Your PO number <span className="muted" style={{ fontWeight: 400 }}>(optional — otherwise we number it for you)</span>
          <input value={f.po} onChange={set('po')} />
        </label>
      )}
      <div className="small muted">
        {oneOff
          ? 'The homeowner will approve anything above the diagnosis from a link (or tell you by phone, and you record it).'
          : "The technician cannot go past the authorized amount. If more is needed, you'll be asked to approve it (PO A, B…), with photos and a price."}
      </div>
      <button className="primary big" disabled={busy}>{busy ? 'Sending…' : 'Send service call'}</button>
    </form>
  );
}
