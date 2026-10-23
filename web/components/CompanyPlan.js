'use client';

// Settings → Company & plan: the company's details and what they pay (billing itself is coming with card payments).
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money } from '@/lib/format';
import { ErrorBox, Notice } from './bits';
import UsageMeter from './UsageMeter';
import Info from './Info';
import { usePlace, setPlaceWord, PLACE_CHOICES } from '@/lib/terms';

export const PRICE_PER_LOCATION = 395;
export const PRICE_PER_LOGIN = 25;
export const RESTORE_FEE = 75;

function downloadCsv(name, cols, rows) {
  const esc = (v) => { const t = String(v ?? ''); return /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
  const csv = [cols.map(([h]) => h).join(','), ...rows.map((r) => cols.map(([, f]) => esc(f(r))).join(','))].join('\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
  a.download = `${name}-${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
}

export default function CompanyPlan({ org, onSaved }) {
  const place = usePlace();
  const [f, setF] = useState({ name: org?.name || '', phone: org?.phone || '', email: org?.email || '' });
  const [n, setN] = useState({ sites: 0, seats: null });
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const [soon, setSoon] = useState('');
  const [logo, setLogo] = useState(org?.logo_data || null);
  const [area, setArea] = useState(org?.travel_area_miles ?? 10);
  const [areaSaved, setAreaSaved] = useState(org?.travel_area_miles ?? 10);
  const [auto, setAuto] = useState(!!org?.auto_approve_bills);
  const [word, setWord] = useState(place.word);

  async function pickLogo(file) {
    setErr(''); setMsg('');
    if (!file) return;
    try {
      let data;
      if (file.type === 'image/svg+xml') {
        if (file.size > 250000) throw new Error('That SVG is too large. Use one under 250 KB.');
        data = await new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = rej; r.readAsDataURL(file); });
        data = data.replace(/^data:image\/svg\+xml(;[^,]*)?,/, 'data:image/svg+xml;base64,');
        if (!data.startsWith('data:image/svg+xml;base64,')) throw new Error('Could not read that SVG.');
      } else {
        const img = await createImageBitmap(file);
        const k = Math.min(1, 600 / img.width, 160 / img.height);
        const c = document.createElement('canvas');
        c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
        c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        data = c.toDataURL('image/png');
        if (data.length > 380000) data = c.toDataURL('image/jpeg', 0.85);
      }
      await act('set_company_logo', { p_data: data });
      setLogo(data); setMsg('Logo saved. It shows at the top of your dashboard.'); onSaved?.(data);
    } catch (x) { setErr(x.message); }
  }
  async function removeLogo() {
    setErr(''); setMsg('');
    try { await act('set_company_logo', { p_data: null }); setLogo(null); setMsg('Logo removed. Your company name shows instead.'); onSaved?.(null); }
    catch (x) { setErr(x.message); }
  }

  useEffect(() => {
    Promise.all([q(supabase.from('sites').select('id')), act('seat_info', {})])
      .then(([s, seats]) => setN({ sites: s.length, seats })).catch((e) => setErr(e.message));
  }, []);

  async function save(e) {
    e.preventDefault();
    setBusy(true); setErr(''); setMsg('');
    try { await act('update_company', { p_name: f.name, p_phone: f.phone, p_email: f.email }); setMsg('Company profile saved.'); onSaved?.(); }
    catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  async function exportData(kind) {
    setErr(''); setMsg('');
    try {
      if (kind === 'equipment') {
        const r = await q(supabase.from('equipment').select('manufacturer, model, serial, refrigerant, location_description, install_date, retired_at, retired_reason, sites(name), equipment_types(name)').order('site_id'));
        downloadCsv('equipment', [['Location', (x) => x.sites?.name], ['Type', (x) => x.equipment_types?.name], ['Where', (x) => x.location_description], ['Make', (x) => x.manufacturer],
          ['Model', (x) => x.model], ['Serial', (x) => x.serial], ['Refrigerant', (x) => x.refrigerant], ['Installed', (x) => x.install_date], ['Removed', (x) => x.retired_at ? `${x.retired_at.slice(0, 10)} ${x.retired_reason || ''}` : '']], r);
      } else if (kind === 'team') {
        const r = await q(supabase.from('profiles').select('full_name, title, email, phone, is_org_admin, can_approve, approval_limit, all_sites, active').eq('customer_id', org.id).order('full_name'));
        downloadCsv('team', [['Name', (x) => x.full_name], ['Title', (x) => x.title], ['Email', (x) => x.email], ['Phone', (x) => x.phone], ['Admin', (x) => (x.is_org_admin ? 'yes' : '')],
          ['Approves up to', (x) => (x.can_approve ? (x.approval_limit ?? 'any') : '')], ['All locations', (x) => (x.all_sites ? 'yes' : '')], ['Active', (x) => (x.active ? 'yes' : 'no')]], r);
      } else {
        const r = await q(supabase.from('work_orders').select('number, store_po_number, kind, status, issue_description, created_at, completed_at, total_cost, sites(name), contractors(name)').order('created_at', { ascending: false }).limit(5000));
        downloadCsv('service-calls', [['Call #', (x) => x.number], ['PO', (x) => x.store_po_number], ['Location', (x) => x.sites?.name], ['Contractor', (x) => x.contractors?.name], ['Type', (x) => x.kind],
          ['Status', (x) => x.status], ['Problem', (x) => x.issue_description], ['Opened', (x) => x.created_at], ['Completed', (x) => x.completed_at], ['Cost', (x) => x.total_cost]], r);
      }
      setMsg('Downloaded. Open it in Excel or Google Sheets.');
    } catch (x) { setErr(x.message); }
  }

  const total = n.sites * PRICE_PER_LOCATION;
  return (
    <div className="stack">
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      <form className="stack" style={{ gap: 8 }} onSubmit={save}>
        <h3>Company profile <Info title="Company profile">Your company's name, main phone and email. They show to your contractors on every call and on invoices sent to you. Each location's own name and address are under Locations.</Info></h3>
        <label>Company name<input id="co-name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required /></label>
        <div className="row">
          <label className="grow">Main phone<input id="co-phone" type="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></label>
          <label className="grow">Main email<input id="co-email" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></label>
        </div>
        <div><button className="primary" disabled={busy}>Save company profile</button></div>
      </form>

      <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
        <h3>Logo <Info title="Your logo">Optional. Your logo shows at the top left of your dashboard instead of your company name. A wide logo works best (about 4 times wider than tall). PNG, JPG or SVG.</Info></h3>
        <div className="row" style={{ gap: 12, alignItems: 'center' }}>
          <div className="logo-preview">{logo ? <img src={logo} alt={`${f.name} logo`} /> : <span className="muted small">No logo: your company name shows instead.</span>}</div>
          <label className="button-like">{logo ? 'Change logo' : 'Upload logo'}<input type="file" accept="image/png,image/jpeg,image/webp,image/svg+xml" style={{ display: 'none' }} onChange={(e) => pickLogo(e.target.files?.[0])} /></label>
          {logo && <button type="button" onClick={removeLogo}>Remove</button>}
        </div>
      </div>

      <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
        <h3>What you call your places <Info title="What you call your places">Pick the word your company uses: stores, restaurants, facilities, properties or homes. The app uses it on every screen for your people (&ldquo;Add a store&rdquo;, &ldquo;Store PIN&rdquo;, &ldquo;All stores&rdquo;). Your contractors and their technicians see neutral wording.</Info></h3>
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <label style={{ maxWidth: 260 }}>We call them
            <select id="place-word" value={word} onChange={(e) => setWord(e.target.value)}>{PLACE_CHOICES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
          <button type="button" className="primary" disabled={word === place.word} onClick={async () => {
            setErr(''); setMsg('');
            try { await act('set_place_word', { p_word: word }); setPlaceWord(word); setMsg('Saved. The app now uses your word.'); }
            catch (x) { setErr(x.message); }
          }}>Save</button>
        </div>
      </div>

      <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
        <h3>Travel check <Info title="Travel check">When a technician taps "I'm going", the phone notes where the trip started. On the call you see only the nearest town and about how far it is, never the exact spot or a map, and nothing between calls. If the trip started within this distance of your {place.one}, the tech was already in the area: when a bill has more hours than were verified, the call says so, so you can ask whether travel was billed from the shop.</Info></h3>
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <label style={{ maxWidth: 260 }}>Already in the area within (miles)
            <input type="number" min="1" max="100" step="1" value={area} onChange={(e) => setArea(e.target.value)} /></label>
          <button type="button" className="primary" disabled={Number(area) === Number(areaSaved)} onClick={async () => {
            setErr(''); setMsg('');
            try { await act('set_travel_area', { p_miles: Math.round(Number(area)) }); setAreaSaved(Math.round(Number(area))); setMsg(`Saved. Trips starting within ${Math.round(Number(area))} miles count as already in the area.`); }
            catch (x) { setErr(x.message); }
          }}>Save</button>
        </div>
        <div className="small muted">Shown on each call: "Trip started near Fisher, MN, about 14 mi away." Starts at 10 miles.</div>
      </div>

      <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
        <h3>Approving bills <Info title="Approving bills">Every contractor bill comes in tied to its call and PO, with the contractor's own invoice number. By default you approve each one. Turn on auto-approve and a bill is approved for you only when it matches exactly: the contractor agreed to the verified hours, the total is within the PO (plus anything you approved on top), and nothing is flagged. Anything else still waits for you.</Info></h3>
        <label className="row" style={{ gap: 8, fontWeight: 400 }}>
          <input type="checkbox" style={{ width: 'auto' }} checked={auto} onChange={async (e) => {
            const on = e.target.checked; setErr(''); setMsg('');
            try { await act('set_auto_approve_bills', { p_on: on }); setAuto(on); setMsg(on ? 'Auto-approve is on: bills that match exactly are approved for you.' : 'Auto-approve is off: you approve every bill.'); }
            catch (x) { setErr(x.message); }
          }} />
          Approve bills automatically when they match exactly
        </label>
        <div className="small muted">Off: you approve every bill (the default). On: only bills that don&apos;t match wait for you.</div>
      </div>

      <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
        <h3>Your plan <Info title="Your plan">{`$${PRICE_PER_LOCATION} per location per year, paid once a year. Covers all trades (plumbing, electrical, heating, refrigeration), unlimited service calls and unlimited contractors. Phone alerts and email are included; texts and automatic phone calls are included up to a generous fair-use amount per location each year. Add as many people from your company as you need; there's no charge per login. Your contractors use it free. When a contractor runs Service Call Proof Base or Pro, you get Enhanced Time Verify at no charge: their bills arrive in your portal, matched to the call and PO, ready to download, export or forward to your accounting department. No refunds; cancel anytime to stop the next renewal.`}</Info></h3>
        <table><tbody>
          <tr><td>Locations</td><td className="num">{n.sites} × {money(PRICE_PER_LOCATION)}</td><td className="num">{money(n.sites * PRICE_PER_LOCATION)}</td></tr>
          <tr><td>Team logins</td><td className="num">{n.seats ? n.seats.used : '…'} people</td><td className="num">Included</td></tr>
          <tr><td><strong>Per year</strong></td><td /><td className="num"><strong>{money(total)}</strong></td></tr>
        </tbody></table>
        <div className="row">
          <button type="button" onClick={() => setSoon('billing')}>Payment method &amp; invoices <span className="soon">Coming soon</span></button>
        </div>
        {soon === 'restore' && <div className="notice small">{`Restoring from a backup is done by our team, $${RESTORE_FEE} per request, quoted and confirmed with you first. Tell us what went wrong and the date and time to go back to: support@servicecallproof.com. Usually you won't need it: removed equipment and people can be brought back yourself, and calls are never erased.`}</div>}
        {soon && soon !== 'restore' && <div className="notice small">{'Coming soon: your card or bank account on file, your yearly invoice and renewal date. For now, contact support@servicecallproof.com.'}</div>}
      </div>

      <UsageMeter />

      <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
        <h3>Your data <Info title="Your data and backups">{`Your records are kept on our servers. Download a copy anytime for your own files (it opens in Excel). If something gets changed or removed by mistake, most things can be brought back right here: removed equipment and people have a Restore button, and calls are never erased. For anything else, our team can restore your account to an earlier point in time: $${RESTORE_FEE} per request.`}</Info></h3>
        <div className="row">
          <button type="button" onClick={() => exportData('calls')}>Download service calls</button>
          <button type="button" onClick={() => exportData('equipment')}>Download equipment</button>
          <button type="button" onClick={() => exportData('team')}>Download team</button>
          <button type="button" onClick={() => setSoon('restore')}>Restore from a backup</button>
        </div>
      </div>
      <div className="stack" style={{ gap: 6, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
        <h3>How-to guide</h3>
        <div className="small muted">Step-by-step help for everything: making a service call, your PO number, adding people, choosing who sees which {place.one}, changing the admin, adding a {place.one} or contractor, and more.</div>
        <div><a className="button-like" href="/help?for=store">Open the how-to guide</a></div>
      </div>
    </div>
  );
}
