'use client';

// Base: your own customers (businesses or homeowners who don't use Service Call Proof themselves).
// Add one with its first location, keep their details, add more locations. Their bills are emailed to them.
import { useState } from 'react';
import { act } from '@/lib/supabase';
import AddressFinder from './AddressFinder';

export function AddMyCustomer({ onAdded, onCancel }) {
  const [f, setF] = useState({ name: '', business: true, contact: '', phone: '', email: '', site: '', addr: '', access: '' });
  const [found, setFound] = useState(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  return (
    <form className="panel panel-pad stack" style={{ gap: 8 }} onSubmit={async (e) => {
      e.preventDefault(); setBusy(true); setErr('');
      try {
        const r = await act('add_my_customer', { p_name: f.name, p_business: f.business, p_address: found?.address || f.addr, p_contact: f.contact || null,
          p_phone: f.phone || null, p_email: f.email || null, p_site_name: f.site || null, p_zip: found?.zip || null,
          p_access_notes: f.access || null, p_lat: found?.lat ?? null, p_lon: found?.lon ?? null });
        onAdded?.(r);
      } catch (x) { setErr(x.message); } finally { setBusy(false); }
    }}>
      <h3 style={{ margin: 0 }}>Add a customer</h3>
      <div className="small muted">Your own customer: a business or a homeowner. They don&apos;t need a login. Their bills are emailed to them with a link.</div>
      <div className="row" style={{ gap: 12 }}>
        <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="radio" style={{ width: 'auto' }} checked={f.business} onChange={() => setF({ ...f, business: true })} />Business</label>
        <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="radio" style={{ width: 'auto' }} checked={!f.business} onChange={() => setF({ ...f, business: false })} />Homeowner</label>
      </div>
      <div className="row">
        <label className="grow">{f.business ? 'Business name' : 'Name'}<input value={f.name} onChange={set('name')} required /></label>
        {f.business && <label className="grow">Contact person<input value={f.contact} onChange={set('contact')} placeholder="optional" /></label>}
      </div>
      <div className="row">
        <label className="grow">Phone<input value={f.phone} onChange={set('phone')} placeholder="optional" /></label>
        <label className="grow">Email for bills<input type="email" value={f.email} onChange={set('email')} placeholder="so their bills can be emailed" /></label>
      </div>
      {f.business && <label>Location name<input value={f.site} onChange={set('site')} placeholder="e.g. Main store (you can add more later)" /></label>}
      <AddressFinder id="my-cust-addr" value={f.addr} onChange={(v) => setF({ ...f, addr: v })} onFound={setFound} found={found} />
      <label>Access notes <span className="muted" style={{ fontWeight: 400 }}>(optional)</span><input value={f.access} onChange={set('access')} placeholder="e.g. Back door, ask for the manager" /></label>
      {err && <div className="error">{err}</div>}
      <div className="row"><button className="primary" disabled={busy || !f.name.trim() || !found}>Add customer</button><button type="button" onClick={onCancel}>Cancel</button></div>
    </form>
  );
}

export function MyCustomerPanel({ c, onChanged }) {
  const [edit, setEdit] = useState(null);
  const [loc, setLoc] = useState(null);
  const [found, setFound] = useState(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  async function run(fn, args, done) {
    setBusy(true); setErr(''); setMsg('');
    try { await act(fn, args); done?.(); onChanged?.(); } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  return (
    <div className="panel" style={{ padding: 14 }}>
      <div className="spread"><div className="small" style={{ fontWeight: 700 }}>Your customer</div>
        <div className="row" style={{ gap: 6 }}>
          {!edit && <button className="small" onClick={() => setEdit({ name: c.name, contact: c.contact_name || '', phone: c.phone || '', email: c.email || '' })}>Edit details</button>}
          {!loc && <button className="small" onClick={() => { setLoc({ name: '', addr: '', access: '' }); setFound(null); }}>+ Location</button>}
        </div>
      </div>
      <div className="small muted">They don&apos;t use Service Call Proof themselves. Bills go to {c.email ? <strong>{c.email}</strong> : 'their email (none on file yet: add one)'}.{c.contact_name ? ` Contact: ${c.contact_name}.` : ''}</div>
      {edit && (
        <form className="stack" style={{ gap: 6, marginTop: 8 }} onSubmit={(e) => { e.preventDefault(); run('update_my_customer', { p_customer: c.customer_id, p_name: edit.name, p_contact: edit.contact, p_phone: edit.phone, p_email: edit.email }, () => { setEdit(null); setMsg('Saved.'); }); }}>
          <div className="row">
            <label className="grow">Name<input value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} required /></label>
            <label className="grow">Contact<input value={edit.contact} onChange={(e) => setEdit({ ...edit, contact: e.target.value })} /></label>
          </div>
          <div className="row">
            <label className="grow">Phone<input value={edit.phone} onChange={(e) => setEdit({ ...edit, phone: e.target.value })} /></label>
            <label className="grow">Email for bills<input type="email" value={edit.email} onChange={(e) => setEdit({ ...edit, email: e.target.value })} /></label>
          </div>
          <div className="row"><button className="primary" disabled={busy}>Save</button><button type="button" onClick={() => setEdit(null)}>Cancel</button></div>
        </form>
      )}
      {loc && (
        <form className="stack" style={{ gap: 6, marginTop: 8 }} onSubmit={(e) => {
          e.preventDefault();
          run('add_my_customer_site', { p_customer: c.customer_id, p_name: loc.name, p_address: found?.address || loc.addr, p_zip: found?.zip || null,
            p_access_notes: loc.access || null, p_lat: found?.lat ?? null, p_lon: found?.lon ?? null }, () => { setLoc(null); setMsg('Location added.'); });
        }}>
          <label>Location name<input value={loc.name} onChange={(e) => setLoc({ ...loc, name: e.target.value })} required placeholder="e.g. West side store" /></label>
          <AddressFinder id={`loc-${c.customer_id}`} value={loc.addr} onChange={(v) => setLoc({ ...loc, addr: v })} onFound={setFound} found={found} />
          <label>Access notes<input value={loc.access} onChange={(e) => setLoc({ ...loc, access: e.target.value })} placeholder="optional" /></label>
          <div className="row"><button className="primary" disabled={busy || !found || !loc.name.trim()}>Add location</button><button type="button" onClick={() => setLoc(null)}>Cancel</button></div>
        </form>
      )}
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
    </div>
  );
}
