'use client';

// Base: your sales tax rates. You set them; we never supply a rate. One rate per state you work in, plus the cities
// or special districts that add to it. Locations pick their rate up from their city (or the state). Check them each
// quarter; rates usually change on the first of a quarter.
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { date } from '@/lib/format';
import { pct } from '@/lib/tax';

const blank = { id: null, name: '', state: '', city: '', rate: '', labor: false, trip: false, url: '' };
const lookup = (st) => `https://www.google.com/search?q=${encodeURIComponent(`${st} department of revenue sales tax rate lookup`)}`;

export default function TaxSetup({ profile }) {
  const [d, setD] = useState(null);
  const [f, setF] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const load = useCallback(async () => { try { setD(await act('tax_settings', {})); } catch (x) { setErr(x.message); } }, []);
  useEffect(() => { load(); }, [load]);
  if (!(profile?.is_org_admin || profile?.can_bill)) return null;
  const run = async (fn, args, done) => { setErr(''); setMsg(''); try { await act(fn, args); await load(); done?.(); } catch (x) { setErr(x.message); } };
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const states = [...new Set((d?.areas || []).map((a) => a.state))];
  return (
    <div className="panel panel-pad stack" style={{ gap: 8 }}>
      <h3>Sales tax rates</h3>
      <div className="small muted">Your rates, for your service area: one for each state you work in, plus the cities or special districts with a different total rate. A location uses its city&apos;s rate if the city is on your list, otherwise its state&apos;s; you can pick a different one on any bill. You set and check the rates (the state&apos;s own lookup is the place to check); bills use exactly what&apos;s here.</div>
      {d?.stale && <div className="notice small">New quarter: check your rates are still right, then tap <strong>All checked</strong>. Rates usually change on the first of a quarter.</div>}
      {d && (
        <div className="tablewrap">
          <table className="small">
            <thead><tr><th>Name (as in QuickBooks)</th><th>Where</th><th className="num">Total rate</th><th>Labor</th><th>Trip</th><th>Checked</th><th /></tr></thead>
            <tbody>
              {!d.areas.length && <tr><td colSpan={7} className="muted">No rates yet. Bills go out with no sales tax until you add one.</td></tr>}
              {d.areas.map((a) => (
                <tr key={a.id}>
                  <td>{a.name}</td><td>{a.city ? `${a.city}, ${a.state}` : `${a.state} (rest of the state)`}</td><td className="num">{pct(a.rate)}</td>
                  <td>{a.labor_taxed ? 'Taxed' : 'No'}</td><td>{a.trip_taxed ? 'Taxed' : 'No'}</td>
                  <td>{a.checked_on ? date(a.checked_on) : <span style={{ color: 'var(--red-fg)' }}>never</span>}{' '}
                    <a href={a.lookup_url || lookup(a.state)} target="_blank" rel="noreferrer">check</a></td>
                  <td className="row" style={{ gap: 4 }}>
                    <button className="linkbtn small" onClick={() => setF({ id: a.id, name: a.name, state: a.state, city: a.city || '', rate: a.rate, labor: a.labor_taxed, trip: a.trip_taxed, url: a.lookup_url || '' })}>Change</button>
                    <button className="linkbtn small" onClick={() => window.confirm(`Remove ${a.name}?`) && run('remove_tax_area', { p_id: a.id })}>Remove</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {f ? (
        <form className="stack" style={{ gap: 6, border: '1px solid var(--line)', borderRadius: 10, padding: 10 }} onSubmit={(e) => {
          e.preventDefault();
          run('save_tax_area', { p_id: f.id, p_name: f.name, p_state: f.state, p_city: f.city || null, p_rate: f.rate === '' ? null : Number(f.rate),
            p_labor: f.labor, p_trip: f.trip, p_lookup_url: f.url || null, p_checked: true }, () => { setF(null); setMsg('Saved, marked checked today.'); });
        }}>
          <div className="row">
            <label style={{ flex: '0 0 90px' }}>State<input value={f.state} onChange={set('state')} maxLength={2} placeholder="ND" required /></label>
            <label className="grow">City <span className="muted" style={{ fontWeight: 400 }}>(blank = the rest of the state)</span><input value={f.city} onChange={set('city')} placeholder="e.g. Grand Forks" /></label>
            <label style={{ flex: '0 0 130px' }}>Total rate %<input type="number" step="0.001" min="0" max="29.999" value={f.rate} onChange={set('rate')} placeholder="7.25" required /></label>
          </div>
          <div className="row">
            <label className="grow">Name <span className="muted" style={{ fontWeight: 400 }}>(match your QuickBooks tax item)</span><input value={f.name} onChange={set('name')} placeholder={f.city ? `${f.city} ${f.state}` : f.state || 'e.g. Grand Forks ND'} /></label>
            <label className="grow">Where you check it <span className="muted" style={{ fontWeight: 400 }}>(link, optional)</span><input value={f.url} onChange={set('url')} placeholder="https://" /></label>
          </div>
          <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.labor} onChange={set('labor')} />Labor is taxed here (on service work that isn&apos;t built into the building; you can change any line)</label>
          <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.trip} onChange={set('trip')} />The trip charge is taxed here</label>
          <div className="row"><button className="primary">Save</button><button type="button" onClick={() => setF(null)}>Cancel</button>
            {f.state.length === 2 && <a className="small" href={lookup(f.state)} target="_blank" rel="noreferrer">Find {f.state.toUpperCase()}&apos;s rate lookup</a>}</div>
        </form>
      ) : (
        <div className="row" style={{ gap: 6 }}>
          <button onClick={() => setF({ ...blank, state: states[0] || '' })}>+ Add a rate</button>
          {d?.areas.length > 0 && <button onClick={() => run('mark_tax_rates_checked', {}, () => setMsg('All rates marked checked today.'))}>All checked</button>}
        </div>
      )}
      {d && (
        <label className="row small" style={{ gap: 6, fontWeight: 400 }}>
          <input type="checkbox" style={{ width: 'auto' }} checked={!!d.paid_at_purchase} onChange={(e) => run('set_use_tax_paid_at_purchase', { p_on: e.target.checked })} />
          I pay sales tax when I buy my parts and equipment (then there&apos;s usually no use tax to pay on top; the report still lists built-in parts)
        </label>
      )}
      <div className="small muted">On bills and quotes each line is <strong>Taxed</strong>, <strong>Built-in</strong> (becomes part of the building: no tax on the bill, you owe use tax on your cost) or <strong>No tax</strong>. Parts remember built-in. Rules differ by state; have your accountant confirm your settings.</div>
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
    </div>
  );
}
