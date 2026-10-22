'use client';

import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money, PRIORITY } from '@/lib/format';
import { ErrorBox } from './bits';

export default function NewCallForm({ side, profile, onCreated, onCancel, defaultSite }) {
  const [sites, setSites] = useState([]);
  const [issues, setIssues] = useState([]);
  const [equipment, setEquipment] = useState([]);
  const [warranty, setWarranty] = useState([]);
  const [amount, setAmount] = useState(null);
  const [trades, setTrades] = useState([]);
  const [types, setTypes] = useState([]);
  const [nu, setNu] = useState({ type: '', where: '', make: '', model: '' });   // a unit added from this form
  const [f, setF] = useState({ trade: '', contractor: '', site: '', issue: '', equipment: '', details: '', po: '', nte: '', unit: '', contact: '', phone: '', entry: '' });
  const [rel, setRel] = useState({ cc: [], tc: [] });   // who serves this customer, and who gets which trade
  const [home, setHome] = useState(null); // office: adding a one-off homeowner
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });

  const site = sites.find((s) => s.id === f.site);
  const issue = issues.find((i) => i.id === f.issue);
  const residential = (site?.property_type || site?.customers?.kind) === 'residential';
  const oneOff = site?.customers?.kind === 'residential';
  const propertyMgr = site?.customers?.kind === 'property_manager';

  // Which contractor this call goes to: the one the store picked, otherwise the store's rule for this trade, otherwise the main contractor.
  const ccHere = site ? rel.cc.filter((c) => c.customer_id === site.customer_id) : [];
  const tradeId = Number(f.trade) || issue?.trade_id || null;
  const ruled = (t) => t && site && (rel.tc.find((x) => x.site_id === site.id && x.trade_id === t && x.contractor_id)
    || rel.tc.find((x) => !x.site_id && x.customer_id === site.customer_id && x.trade_id === t && x.contractor_id));
  const forTrade = tradeId ? ccHere.filter((c) => rel.tc.some((x) => x.trade_id === tradeId && x.contractor_id === c.contractor_id
    && x.customer_id === c.customer_id && (!x.site_id || x.site_id === site?.id))) : [];
  const route = (() => {
    if (!site) return null;
    if (side === 'office') return ccHere.find((c) => c.contractor_id === profile?.contractor_id) || null;
    if (f.contractor) return ccHere.find((c) => c.contractor_id === f.contractor) || null;
    const id = ruled(tradeId)?.contractor_id || [...ccHere].sort((a, b) => (b.is_primary - a.is_primary) || (a.created_at > b.created_at ? 1 : -1))[0]?.contractor_id;
    return ccHere.find((c) => c.contractor_id === id) || null;
  })();
  const verify = route?.mode === 'verify';

  const loadSites = () => q(supabase.from('sites').select('id, name, address, customer_id, property_type, customers(name, kind, phone)').order('name'));
  useEffect(() => {
    Promise.all([loadSites(), q(supabase.from('issue_types').select('*').eq('active', true).order('sort')),
      q(supabase.from('customer_contractors').select('customer_id, contractor_id, is_primary, mode, created_at, accept_emergency_min, accept_normal_min, contractors(name, phone, email)')),
      q(supabase.from('trade_contractors').select('customer_id, site_id, trade_id, contractor_id')),
      q(supabase.from('trades').select('id, name').order('id')),
      q(supabase.from('equipment_types').select('code, name, trade_id').is('contractor_id', null).order('name'))])
      .then(([s, i, cc, tc, tr, ty]) => {
        setSites(s);
        setIssues(i);
        setRel({ cc, tc });
        setTrades(tr); setTypes(ty);
        if (s.length === 1 || (defaultSite && s.some((x) => x.id === defaultSite))) setF((x) => ({ ...x, site: s.length === 1 ? s[0].id : defaultSite }));
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
    q(supabase.from('equipment').select('id, manufacturer, model, location_description, equipment_types(code, name)').eq('site_id', f.site).is('retired_at', null))
      .then(setEquipment).catch(() => {});
  }, [f.site]);

  // Show the authorized diagnosis amount as soon as the problem is picked
  useEffect(() => {
    setAmount(null);
    if (!f.site || !f.issue || verify) return;
    (async () => {
      const contractor = route?.contractor_id || profile?.contractor_id || (await q(supabase.from('customer_contractors').select('contractor_id, is_primary')
        .eq('customer_id', site.customer_id).order('is_primary', { ascending: false }).limit(1)))[0]?.contractor_id;
      if (!contractor) return;
      const a = await act('diagnosis_amount', { p_site: f.site, p_issue: f.issue, p_contractor: contractor, p_at: new Date().toISOString() });
      setAmount(a);
    })().catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [f.site, f.issue, verify]);

  useEffect(() => {
    setWarranty([]);
    if (!f.equipment) return;
    q(supabase.from('warranties').select('kind, ends_on, description').eq('equipment_id', f.equipment)
      .gte('ends_on', new Date().toISOString().slice(0, 10))).then(setWarranty).catch(() => {});
  }, [f.equipment]);

  const shownIssues = issues.filter((i) => (residential ? i.for_residential : i.for_commercial) && (!f.trade || i.trade_id === Number(f.trade)));
  const suggested = issue ? equipment.filter((e) => e.equipment_types?.code === issue.equipment_type_code) : [];

  async function submit(e) {
    e.preventDefault();
    setBusy(true); setErr('');
    try {
      let equipmentId = f.equipment === '__new' ? null : (f.equipment || null);
      if (f.equipment === '__new') {
        const r = await act('add_equipment_from_call', { p_site: f.site, p_type_code: nu.type || null, p_where: nu.where, p_make: nu.make, p_model: nu.model });
        equipmentId = r.id;
      }
      const g = { ...f, equipment: equipmentId };
      let wo;
      if (verify && side === 'office') {
        wo = await act('enter_phone_call', { p_site: f.site, p_issue_type: f.issue || null, p_details: f.details.trim() || null,
          p_caller_name: f.contact.trim(), p_caller_phone: f.phone.trim() || null, p_po_number: f.po.trim() || null, p_equipment: g.equipment });
      } else if (verify) {
        wo = await act('open_po_call', { p_site: f.site, p_issue_type: f.issue || null, p_details: f.details.trim() || null,
          p_po_number: f.po.trim() || null, p_nte: f.nte === '' ? null : Number(f.nte), p_equipment: g.equipment, p_contractor: route.contractor_id });
      } else {
        wo = await act('create_work_order', {
          p_site: f.site, p_issue_type: f.issue || null, p_description: f.details.trim() || null,
          p_equipment: g.equipment, p_store_po_number: f.po.trim() || null,
        });
      }
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
      {side === 'store' && (
        <div className="row">
          <label className="grow">Type of problem
            <select value={f.trade} onChange={(e) => setF({ ...f, trade: e.target.value, issue: '', contractor: '' })} disabled={!f.site}>
              <option value="">Choose…</option>
              {trades.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
          </label>
          <label className="grow">Send to
            <select value={f.contractor || route?.contractor_id || ''} onChange={(e) => setF({ ...f, contractor: e.target.value })} disabled={!f.site || !ccHere.length}>
              {!ccHere.length && <option value="">No contractors yet: invite one under Contractors &amp; QR</option>}
              {forTrade.length > 0 && <optgroup label={`Your ${trades.find((t) => t.id === tradeId)?.name || ''} contractors`}>
                {forTrade.map((c) => <option key={c.contractor_id} value={c.contractor_id}>{c.contractors?.name}</option>)}</optgroup>}
              <optgroup label={forTrade.length ? 'Other contractors' : 'Your contractors'}>
                {ccHere.filter((c) => !forTrade.includes(c)).map((c) => <option key={c.contractor_id} value={c.contractor_id}>{c.contractors?.name}</option>)}
              </optgroup>
            </select>
          </label>
        </div>
      )}
      <label>
        What's the problem?
        <select value={f.issue} onChange={(e) => { const i = issues.find((x) => x.id === e.target.value); setF({ ...f, issue: e.target.value, trade: f.trade || (i?.trade_id ? String(i.trade_id) : '') }); }} required disabled={!f.site}>
          <option value="">Choose…</option>
          {shownIssues.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
        </select>
      </label>
      {issue && (
        <div className="row small" style={{ gap: 8 }}>
          <span className={`chip ${issue.priority === 1 ? 'tone-red' : 'tone-slate'}`}>{PRIORITY[issue.priority]}</span>
          {!verify && amount != null && <span>Diagnosis authorized up to <strong>{money(amount)}</strong></span>}
          {route && side === 'store' && <span>Goes to <strong>{route.contractors?.name}</strong>{verify ? ' · Time Verify' : ''}</span>}
        </div>
      )}
      <label>
        Which unit? <span className="muted" style={{ fontWeight: 400 }}>(optional — the technician will photograph it)</span>
        <select value={f.equipment} onChange={set('equipment')} disabled={!f.site}>
          <option value="">Not sure</option>
          <option value="__new">+ It's not listed: add it now</option>
          {[...suggested, ...equipment.filter((e) => !suggested.includes(e))].map((q2) => (
            <option key={q2.id} value={q2.id}>
              {q2.equipment_types?.name} — {q2.manufacturer} {q2.model}{q2.location_description ? ` (${q2.location_description})` : ''}
            </option>
          ))}
        </select>
      </label>
      {f.equipment === '__new' && (
        <div className="stack" style={{ gap: 6, background: 'var(--bg)', borderRadius: 8, padding: 10 }}>
          <strong className="small">Add this unit to your equipment list</strong>
          <div className="row">
            <label className="grow">What is it?<select value={nu.type} onChange={(e) => setNu({ ...nu, type: e.target.value })}>
              <option value="">Choose…</option>
              {types.filter((t) => !tradeId || !t.trade_id || t.trade_id === tradeId).map((t) => <option key={t.code} value={t.code}>{t.name}</option>)}</select></label>
            <label className="grow">Where is it?<input value={nu.where} onChange={(e) => setNu({ ...nu, where: e.target.value })} placeholder="e.g. Back wall of dairy" /></label>
          </div>
          <div className="row">
            <label className="grow">Make <span className="muted" style={{ fontWeight: 400 }}>(if you know)</span><input value={nu.make} onChange={(e) => setNu({ ...nu, make: e.target.value })} /></label>
            <label className="grow">Model <span className="muted" style={{ fontWeight: 400 }}>(if you know)</span><input value={nu.model} onChange={(e) => setNu({ ...nu, model: e.target.value })} /></label>
          </div>
          <div className="small muted">It's saved to your Equipment list with this call. The technician fills in the nameplate details on the visit.</div>
        </div>
      )}
      {warranty.length > 0 && (
        <div className="notice"><strong>This unit is under warranty:</strong> {warranty.map((w) => `${w.kind} until ${w.ends_on}`).join(', ')}. The contractor will see this too.</div>
      )}
      <label>
        Details <span className="muted" style={{ fontWeight: 400 }}>(optional)</span>
        <textarea value={f.details} onChange={set('details')} placeholder="e.g. Reading 20°F, normally -5°F. Product moved to the cooler." />
      </label>
      {verify && side === 'office' && f.site && (
        <div className="row">
          <label className="grow">Who called? <span className="muted" style={{ fontWeight: 400 }}>(the store is asked to confirm)</span>
            <input value={f.contact} onChange={set('contact')} required placeholder="e.g. Sam, store manager" /></label>
          <label className="grow">Their phone<input value={f.phone} onChange={set('phone')} /></label>
        </div>
      )}
      {!(verify && side === 'office') && (propertyMgr || oneOff || side === 'office') && f.site && (
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
      {verify && side === 'store' && (
        <label>
          Not to exceed ($) <span className="muted" style={{ fontWeight: 400 }}>(optional — the contractor sees it; the invoice is checked against it)</span>
          <input type="number" min="0" step="50" value={f.nte} onChange={set('nte')} placeholder="e.g. 500" />
        </label>
      )}
      {!oneOff && (
        <label>
          {side === 'office' ? "Store's PO number" : 'Your PO number'} <span className="muted" style={{ fontWeight: 400 }}>(optional — otherwise we number it for you)</span>
          <input value={f.po} onChange={set('po')} />
        </label>
      )}
      <div className="small muted">
        {verify
          ? (side === 'office' ? 'The store is asked to confirm this call. Any of your techs can take it from their phone.'
            : `${route?.contractors?.name || 'The contractor'} is alerted right away by phone alert and email, and must confirm they received it by tapping Accept${route ? ` within ${issue?.priority === 1 ? `${route.accept_emergency_min || 15} minutes` : `${Math.round((route.accept_normal_min || 120) / 60)} hours`}` : ''}. You'll see when they accepted and who, and you're alerted if they don't. Their techs check in with your code; you see the real time on site and check it against their invoice.`)
          : oneOff
          ? 'The homeowner will approve anything above the diagnosis from a link (or tell you by phone, and you record it).'
          : "The technician cannot go past the authorized amount. If more is needed, you'll be asked to approve it (PO A, B…), with photos and a price."}
      </div>
      <button className="primary big" disabled={busy}>{busy ? 'Sending…' : 'Send service call'}</button>
    </form>
  );
}
