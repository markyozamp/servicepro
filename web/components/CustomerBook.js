'use client';

// Contractor side: the customers they serve. List of accounts (locations, open calls, bills, this year's work, what needs attention),
// and one customer's page: contacts, terms, stores, equipment and past calls.
import { useEffect, useState } from 'react';
import { act, supabase } from '@/lib/supabase';
import { money, date } from '@/lib/format';
import PoLog from './PoLog';
import RateCard from './RateCard';
import PmPlans from './PmPlans';
import { ErrorBox } from './bits';
import { AddMyCustomer, MyCustomerPanel } from './MyCustomer';

const mins = (m) => (m == null ? '—' : m < 60 ? `${m} min` : m % 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m / 60} h`);
const TRAVEL = { yes: 'Pays travel time', no: 'Does not pay travel time', after_hours: 'Pays travel after hours only' };
const UNVERIFIED = { review: 'Time not checked in is reviewed', no_pay: 'Time not checked in is not paid' };
const mapUrl = (a) => `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(a)}`;

function CustomerPage({ c, siteId, onBack, onOpenCall, admin, onChanged, contractorId, canRates }) {
  const [eq, setEq] = useState(null);
  const [err, setErr] = useState('');
  const [show, setShow] = useState('stores');
  const [billDays, setBillDays] = useState(null);
  useEffect(() => {
    if (!contractorId) return;
    supabase.from('customer_contractors').select('billing_days').eq('customer_id', c.customer_id).eq('contractor_id', contractorId).maybeSingle()
      .then(({ data }) => setBillDays(data?.billing_days ?? 7));
  }, [c.customer_id, contractorId]);
  useEffect(() => { act('contractor_customer_equipment', { p_customer: c.customer_id }).then(setEq).catch((e) => setErr(e.message)); }, [c.customer_id]);
  const t = c.terms || {};
  const sites = siteId ? c.sites.filter((s) => s.site_id === siteId) : c.sites;
  const eqShown = (eq || []).filter((e) => !siteId || e.site_id === siteId);

  return (
    <div className="stack">
      <div className="spread">
        <div>
          {onBack && <button className="linkbtn small" onClick={onBack}>← All customers</button>}
          <h2 style={{ margin: '4px 0 2px' }}>{c.name}</h2>
          <div className="small muted">
            {c.phone && <a href={`tel:${c.phone.replace(/[^\d+]/g, '')}`}>{c.phone}</a>}{c.phone && c.email ? ' · ' : ''}
            {c.email && <a href={`mailto:${c.email}`}>{c.email}</a>}
            {t.since && <> · customer since {date(t.since)}</>}
          </div>
        </div>
        <div className="row" style={{ gap: 6 }}>
          <span className="chip tone-slate">{c.sites.length} location{c.sites.length === 1 ? '' : 's'}</span>
          <span className="chip tone-blue">{c.open_calls} open</span>
          {c.to_bill > 0 && <span className="chip tone-amber">{c.to_bill} to bill</span>}
        </div>
      </div>

      {c.store_removed_at && (
        <div className="notice">{c.name} took you off their contractor list on {date(c.store_removed_at)}. They can't send you new calls. Your past calls with them are still here.</div>
      )}

      {c.managed ? <MyCustomerPanel c={c} onChanged={onChanged} /> : (
      <div className="panel" style={{ padding: 14 }}>
        <div className="small" style={{ fontWeight: 700, marginBottom: 6 }}>Their terms with you</div>
        <div className="row small" style={{ gap: 6 }}>
          <span className="chip tone-slate">Accept emergencies within {mins(t.accept_emergency_min)}</span>
          <span className="chip tone-slate">Other calls within {mins(t.accept_normal_min)}</span>
          {t.pays_travel && <span className="chip tone-slate">{TRAVEL[t.pays_travel] || t.pays_travel}</span>}
          {t.min_hours != null && <span className="chip tone-slate">{t.min_hours} h minimum</span>}
          {t.increment_min != null && <span className="chip tone-slate">Billed in {t.increment_min}-min steps</span>}
          {t.unverified_time && <span className="chip tone-slate">{UNVERIFIED[t.unverified_time] || t.unverified_time}</span>}
          {billDays != null && <span className="chip tone-slate">Invoice due within {billDays} days of finishing</span>}
          {(c.trades || []).map((x) => <span key={x} className="chip tone-blue">{x}</span>)}
        </div>
        {!t.terms_accepted_at && <div className="small" style={{ color: 'var(--red-fg)', marginTop: 6 }}>You haven't accepted their terms yet.</div>}
        <div className="small muted" style={{ marginTop: 6 }}>This year: {c.calls_ytd} call{c.calls_ytd === 1 ? '' : 's'} · {money(c.billed_ytd)} invoiced</div>
      </div>
      )}

      {contractorId && <div className="panel" style={{ padding: 14 }}>
        <RateCard customerId={c.customer_id} contractorId={contractorId} side="contractor" canEdit={canRates} />
      </div>}

      <div className="tabs" style={{ marginBottom: 0 }}>
        <button className={show === 'stores' ? 'on' : ''} onClick={() => setShow('stores')}>Locations ({sites.length})</button>
        <button className={show === 'equipment' ? 'on' : ''} onClick={() => setShow('equipment')}>Equipment{eq ? ` (${eqShown.length})` : ''}</button>
        <button className={show === 'calls' ? 'on' : ''} onClick={() => setShow('calls')}>Past calls</button>
        {contractorId && <button className={show === 'pm' ? 'on' : ''} onClick={() => setShow('pm')}>Maintenance plans</button>}
      </div>
      <ErrorBox error={err} />

      {show === 'stores' && (
        <div className="panel">
          <table>
            <thead><tr><th>Location</th><th className="hide-sm">Getting in</th><th>Now</th></tr></thead>
            <tbody>
              {sites.map((s) => (
                <tr key={s.site_id}>
                  <td><strong>{s.name}</strong>
                    {s.address && <div className="small"><a href={mapUrl(s.address)} target="_blank" rel="noreferrer">{s.address}</a></div>}</td>
                  <td className="hide-sm small">{s.access_notes || <span className="muted">No notes</span>}
                    <div className="muted">{s.require_checkin ? 'Check-in code required' : 'No check-in code'}{s.has_backup_code ? ' · backup code set' : ''}</div></td>
                  <td>{s.reasons.length ? s.reasons.map((r) => <div key={r}><span className="chip tone-red">{r}</span></div>)
                    : <span className="chip tone-green">All good</span>}
                    {s.open_calls > 0 && <div className="small muted">{s.open_calls} open call{s.open_calls === 1 ? '' : 's'}</div>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {show === 'equipment' && (
        <div className="panel">
          <table>
            <thead><tr><th>Unit</th><th>Make / model</th><th className="hide-sm">Serial</th></tr></thead>
            <tbody>
              {eq === null && <tr><td colSpan={3} className="muted">Loading…</td></tr>}
              {eq && eqShown.length === 0 && <tr><td colSpan={3} className="muted">The customer hasn't listed equipment yet.</td></tr>}
              {eqShown.map((e) => (
                <tr key={e.id}>
                  <td><strong>{e.type || 'Unit'}</strong>{e.where && <div className="small">{e.where}</div>}{sites.length > 1 && <div className="small muted">{e.site}</div>}</td>
                  <td>{[e.make, e.model].filter(Boolean).join(' ') || <span className="muted">—</span>}
                    {e.refrigerant && <div className="small muted">{e.refrigerant}</div>}</td>
                  <td className="hide-sm small">{e.serial || '—'}{e.installed && <div className="muted">installed {date(e.installed)}</div>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {show === 'pm' && <PmPlans side="contractor" customerId={c.customer_id} sites={c.sites.map((x) => ({ id: x.site_id, name: x.name }))} canEdit={canRates} onOpenCall={onOpenCall} />}
      {show === 'calls' && <PoLog customerId={c.customer_id} siteId={siteId} onOpen={onOpenCall} />}

      {admin && !siteId && (
        <button className="linkbtn small" style={{ alignSelf: 'flex-start', color: 'var(--red-fg)' }} onClick={async () => {
          if (!window.confirm(`Remove ${c.name} from your customers?\n\nYour past calls and invoices with them stay in your records. They can't send you new calls, and they'll see that you stopped serving them. You can restore them later.`)) return;
          setErr('');
          try { await act('remove_customer', { p_customer: c.customer_id }); onBack(); onChanged(); } catch (e) { setErr(e.message); }
        }}>Remove this customer</button>
      )}
    </div>
  );
}

function RemovedCustomers({ onChanged }) {
  const [list, setList] = useState(null);
  const [open, setOpen] = useState(false);
  const [err, setErr] = useState('');
  const load = () => act('contractor_removed_customers', {}).then(setList).catch((e) => setErr(e.message));
  useEffect(() => { load(); }, []);
  if (!list || !list.length) return null;
  return (
    <div className="small" style={{ marginTop: 10 }}>
      <ErrorBox error={err} />
      <button className="linkbtn" onClick={() => setOpen(!open)}>{open ? 'Hide' : 'Show'} removed customers ({list.length})</button>
      {open && list.map((c) => (
        <div key={c.customer_id} className="row spread" style={{ padding: '6px 0', borderBottom: '1px solid var(--line)' }}>
          <span><strong>{c.name}</strong> <span className="muted">removed {date(c.removed_at)}</span></span>
          <button onClick={async () => { try { await act('restore_customer', { p_customer: c.customer_id }); await load(); onChanged(); } catch (e) { setErr(e.message); } }}>Restore</button>
        </div>
      ))}
    </div>
  );
}

export default function CustomerBook({ book, pick, onPick, onOpenCall, admin = false, onChanged = () => {}, contractorId, canRates = false, base = false, canAdd = false }) {
  const [adding, setAdding] = useState(false);
  const custId = pick?.startsWith('c:') ? pick.slice(2) : pick?.startsWith('s:') ? book.find((c) => c.sites.some((s) => s.site_id === pick.slice(2)))?.customer_id : null;
  const siteId = pick?.startsWith('s:') ? pick.slice(2) : null;
  const one = custId && book.find((c) => c.customer_id === custId);
  if (one) return <CustomerPage c={one} siteId={siteId} onBack={() => onPick('')} onOpenCall={onOpenCall} admin={admin} onChanged={onChanged} contractorId={contractorId} canRates={canRates} />;

  const reasons = (c) => [...new Set(c.sites.flatMap((s) => s.reasons))];
  const sorted = [...book].sort((a, b) => reasons(b).length - reasons(a).length || a.name.localeCompare(b.name));
  return (
    <>
    {canAdd && (base ? (adding ? <AddMyCustomer onCancel={() => setAdding(false)} onAdded={(r) => { setAdding(false); onChanged(); setTimeout(() => onPick(`c:${r.customer_id}`), 400); }} />
      : <div className="row"><button onClick={() => setAdding(true)}>+ Add a customer</button><span className="small muted">Your own customers: businesses or homeowners, with their bills emailed to them.</span></div>)
      : <div className="small muted">Adding your own customers (not just the ones who invited you) comes with Base. See ⬆ Upgrade.</div>)}
    <div className="panel">
      <table>
        <thead><tr><th>Customer</th><th className="num">Open</th><th className="num hide-sm">To bill</th><th className="num hide-sm">This year</th></tr></thead>
        <tbody>
          {book.length === 0 && <tr><td colSpan={4} className="muted">No customers yet. When a customer invites you, they show up here.</td></tr>}
          {sorted.map((c) => {
            const r = reasons(c);
            return (
              <tr key={c.customer_id} className="click" onClick={() => onPick(`c:${c.customer_id}`)}>
                <td><strong>{c.name}</strong> <span className="small muted">{c.sites.length} location{c.sites.length === 1 ? '' : 's'}</span>{c.managed && <span className="chip tone-slate" style={{ marginLeft: 6 }}>your customer</span>}
                  {c.store_removed_at && <div><span className="chip tone-slate">They removed you {date(c.store_removed_at)}</span></div>}
                  {r.length > 0 && <div className="row" style={{ gap: 4, marginTop: 4 }}>{r.map((x) => <span key={x} className="chip tone-red">{x}</span>)}</div>}</td>
                <td className="num">{c.open_calls}</td>
                <td className="num hide-sm">{c.to_bill || '—'}</td>
                <td className="num hide-sm">{c.calls_ytd} call{c.calls_ytd === 1 ? '' : 's'}<div className="small muted">{money(c.billed_ytd)}</div></td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
    {admin && <RemovedCustomers onChanged={onChanged} />}
    </>
  );
}
