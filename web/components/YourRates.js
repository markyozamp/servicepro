'use client';

// Base: Your rates. Sell rates by role (lead tech, helper, apprentice; regular and overtime / after hours), the trip
// charge, parts markup (one percent or tiers by the part's cost), and, private to the owner, what labor costs him
// (each person's pay and his burden %). A calculator works out his break-even and the rate for his target margin from
// his own numbers. Nothing is filled in for him: he sets every rate and confirms it, and that's recorded.
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { money, dateTime } from '@/lib/format';

const ROLES = [['lead', 'lead_ot', 'Lead tech'], ['helper', 'helper_ot', 'Helper'], ['apprentice', 'apprentice_ot', 'Apprentice']];
const marginOf = (markup) => (markup === '' || markup == null || Number(markup) <= -100 ? null : Math.round((Number(markup) / (100 + Number(markup))) * 1000) / 10);
const r2 = (n) => Math.round(n * 100) / 100;

export function rateCalc(c) {
  const pay = Number(c.pay), bill = Number(c.billable_hours);
  if (!c.pay || !c.billable_hours || bill <= 0) return null;
  const burden = Number(c.burden_pct || 0), over = Number(c.overhead_month || 0), techs = Math.max(1, Number(c.techs || 1)), paid = Math.max(1, Number(c.paid_hours || 40));
  const cost = (pay * (1 + burden / 100) * paid + (over * 12) / 52 / techs) / bill;
  const m = Number(c.margin_pct || 0);
  return { breakEven: r2(cost), target: m < 100 ? r2(cost / (1 - m / 100)) : null };
}

function Margin({ markup }) {
  const m = marginOf(markup);
  return m == null ? null : <span className="small muted"> = {m}% margin</span>;
}

export default function YourRates({ profile }) {
  const [d, setD] = useState(null);
  const [r, setR] = useState(null);
  const [tiered, setTiered] = useState(false);
  const [tiers, setTiers] = useState([]);
  const [calc, setCalc] = useState({ pay: '', burden_pct: '', overhead_month: '', techs: '', paid_hours: '40', billable_hours: '', margin_pct: '' });
  const [showCalc, setShowCalc] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const [override, setOverride] = useState(false);
  const [needOverride, setNeedOverride] = useState(false);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const load = useCallback(async () => {
    try {
      const x = await act('my_rates', {}); setD(x);
      const rr = x.rates || {};
      setR(Object.fromEntries(['lead', 'lead_ot', 'helper', 'helper_ot', 'apprentice', 'apprentice_ot', 'trip', 'markup_pct'].map((k) => [k, rr[k] ?? ''])));
      const t = Array.isArray(rr.parts_tiers) ? rr.parts_tiers : [];
      setTiered(t.length > 0); setTiers(t.length ? t.map((z) => ({ up_to: z.up_to ?? '', pct: z.pct ?? '' })) : [{ up_to: '', pct: '' }, { up_to: '', pct: '' }, { up_to: '', pct: '' }]);
      if (x.calc || x.burden_pct != null) setCalc((c) => ({ ...c, ...(x.calc || {}), burden_pct: x.burden_pct ?? x.calc?.burden_pct ?? '' }));
    } catch (e) { setErr(e.message); }
  }, []);
  useEffect(() => { load(); }, [load]);
  if (!d || !r) return err ? <div className="error">{err}</div> : null;
  const edit = d.can_edit;
  const res = rateCalc(calc);
  const lead = Number(r.lead || 0);
  const warnings = [];
  ROLES.forEach(([k, ot, n]) => { [[k, n], [ot, `${n} overtime`]].forEach(([key, name]) => { const v = Number(r[key]); if (r[key] !== '' && v > 0 && (v < 40 || v > 400)) warnings.push(`${name} at ${money(v)}/hr`); }); });
  if (res && lead > 0 && lead < res.breakEven) warnings.push(`your lead rate is below your break-even of ${money(res.breakEven)}/hr: about ${money(res.breakEven - lead)} lost on every hour`);
  const set = (k) => (e) => setR({ ...r, [k]: e.target.value });
  const setC = (k) => (e) => setCalc({ ...calc, [k]: e.target.value });
  async function save() {
    setErr(''); setMsg('');
    try {
      const rates = { ...r, parts_tiers: tiered ? tiers.filter((t) => t.pct !== '').map((t) => ({ up_to: t.up_to === '' ? null : Number(t.up_to), pct: Number(t.pct) })) : [] };
      const x = await act('save_rates', { p_rates: rates, p_confirm: confirm, p_override: override, p_burden_pct: calc.burden_pct === '' ? null : Number(calc.burden_pct), p_calc: calc });
      setMsg(x.overridden ? 'Saved, as you set them (you kept a rate the check flagged).' : 'Saved. Every bill uses these rates unless a customer has its own rate card.');
      setNeedOverride(false); setOverride(false); setConfirm(false); load();
    } catch (e) { setErr(e.message); if (/Double-check/.test(e.message)) setNeedOverride(true); }
  }
  return (
    <div className="panel panel-pad stack" style={{ gap: 10 }}>
      <div className="spread"><h3 style={{ margin: 0 }}>Your rates</h3>
        {d.confirmed_at ? <span className="small muted">Set by {d.confirmed_by} · {dateTime(d.confirmed_at)}</span> : <span className="chip tone-red">Not set yet: bills can&apos;t go out</span>}</div>
      <div className="small muted">What you charge, on every bill, unless a customer has its own rate card (Customers → rate card). You set every rate; Service Call Proof doesn&apos;t set or recommend your prices.</div>
      <div className="tablewrap">
        <table className="small">
          <thead><tr><th>Labor (per hour)</th><th className="num">Regular</th><th className="num">Overtime / after hours</th></tr></thead>
          <tbody>
            {ROLES.map(([k, ot, n]) => (
              <tr key={k}><td>{n}{k === 'lead' ? <span className="muted"> (required)</span> : null}</td>
                <td className="num"><input type="number" step="0.01" min="0" value={r[k]} onChange={set(k)} disabled={!edit} style={{ width: 110 }} /></td>
                <td className="num"><input type="number" step="0.01" min="0" value={r[ot]} onChange={set(ot)} disabled={!edit} style={{ width: 110 }} /></td></tr>
            ))}
            <tr><td>Trip charge (per trip)</td><td className="num"><input type="number" step="0.01" min="0" value={r.trip} onChange={set('trip')} disabled={!edit} style={{ width: 110 }} /></td><td /></tr>
          </tbody>
        </table>
      </div>
      <div className="stack small" style={{ gap: 6 }}>
        <strong>Parts markup</strong>
        <div className="row" style={{ gap: 12 }}>
          <label className="row" style={{ gap: 4, fontWeight: 400 }}><input type="radio" style={{ width: 'auto' }} checked={!tiered} onChange={() => setTiered(false)} disabled={!edit} />One markup on all parts</label>
          <label className="row" style={{ gap: 4, fontWeight: 400 }}><input type="radio" style={{ width: 'auto' }} checked={tiered} onChange={() => setTiered(true)} disabled={!edit} />By what the part costs you</label>
        </div>
        {!tiered ? (
          <label className="row" style={{ gap: 6, fontWeight: 400 }}>Markup<input type="number" step="0.1" min="0" value={r.markup_pct} onChange={set('markup_pct')} disabled={!edit} style={{ width: 90 }} />%<Margin markup={r.markup_pct} /></label>
        ) : (
          <table className="small"><tbody>
            {tiers.map((t, i) => (
              <tr key={i}>
                <td>{i === 0 ? 'Parts costing up to' : i === tiers.length - 1 && t.up_to === '' ? 'Above that' : 'then up to'}</td>
                <td>{(i < tiers.length - 1 || t.up_to !== '') && <span>$<input type="number" step="1" min="0" value={t.up_to} onChange={(e) => setTiers(tiers.map((z, j) => (j === i ? { ...z, up_to: e.target.value } : z)))} disabled={!edit} style={{ width: 90 }} placeholder="500" /></span>}</td>
                <td><input type="number" step="0.1" min="0" value={t.pct} onChange={(e) => setTiers(tiers.map((z, j) => (j === i ? { ...z, pct: e.target.value } : z)))} disabled={!edit} style={{ width: 80 }} />% markup<Margin markup={t.pct} /></td>
                <td>{edit && tiers.length > 1 && <button type="button" className="linkbtn small" onClick={() => setTiers(tiers.filter((_, j) => j !== i))}>✕</button>}</td>
              </tr>
            ))}
            {edit && <tr><td colSpan={4}><button type="button" className="linkbtn small" onClick={() => setTiers([...tiers, { up_to: '', pct: '' }])}>+ Add a tier</button>
              <span className="muted"> · leave the last &ldquo;up to&rdquo; blank for &ldquo;and above&rdquo;. A big unit is usually a quoted job, priced on the quote.</span></td></tr>}
          </tbody></table>
        )}
        <div className="muted">Markup isn&apos;t margin: a 65% markup is a 39% margin; a 50% margin takes a 100% markup.</div>
      </div>

      {edit && (
        <div className="stack small" style={{ gap: 6, borderTop: '1px solid var(--line)', paddingTop: 8 }}>
          <button type="button" className="linkbtn small" style={{ alignSelf: 'flex-start' }} onClick={() => setShowCalc(!showCalc)}>{showCalc ? 'Hide' : 'Help me figure my rate'} (from your own numbers)</button>
          {showCalc && (
            <div className="stack" style={{ gap: 6 }}>
              <div className="row" style={{ alignItems: 'flex-end', flexWrap: 'wrap' }}>
                <label style={{ flex: '0 0 130px' }}>Tech pay /hr<input type="number" step="0.01" value={calc.pay} onChange={setC('pay')} placeholder="your average" /></label>
                <label style={{ flex: '0 0 150px' }}>Burden %<input type="number" step="0.1" value={calc.burden_pct} onChange={setC('burden_pct')} placeholder="e.g. 30" /></label>
                <label style={{ flex: '0 0 170px' }}>Overhead per month<input type="number" step="1" value={calc.overhead_month} onChange={setC('overhead_month')} placeholder="trucks, rent, insurance…" /></label>
                <label style={{ flex: '0 0 110px' }}>Billing techs<input type="number" step="1" min="1" value={calc.techs} onChange={setC('techs')} /></label>
                <label style={{ flex: '0 0 140px' }}>Paid hours / week<input type="number" step="1" value={calc.paid_hours} onChange={setC('paid_hours')} /></label>
                <label style={{ flex: '0 0 160px' }}>Billable hours / week<input type="number" step="1" value={calc.billable_hours} onChange={setC('billable_hours')} placeholder="often 25–30" /></label>
                <label style={{ flex: '0 0 140px' }}>Target margin %<input type="number" step="1" value={calc.margin_pct} onChange={setC('margin_pct')} /></label>
              </div>
              <div className="muted">Burden is what each paid hour costs you on top of the wage: payroll taxes, workers&apos; comp, insurance, benefits. Most shops land between 25% and 40%; yours depends on your state and your plan. Billable hours: of a 40-hour week, the hours you can actually bill (drive time, shop time and callbacks aren&apos;t billable). Most owners guess this too high.</div>
              {res ? <div className="notice">Break-even: <strong>{money(res.breakEven)}/hr</strong> (below this you lose money on every hour you bill){res.target ? <> · for a {calc.margin_pct || 0}% margin: <strong>{money(res.target)}/hr</strong></> : null}. Your numbers, your call.</div>
                : <div className="muted">Fill in pay and billable hours to see your break-even.</div>}
            </div>
          )}
        </div>
      )}

      {edit && (d.team || []).length > 0 && (
        <details className="small"><summary style={{ cursor: 'pointer' }}>What each person costs you (private, for job costing)</summary>
          <table className="small" style={{ marginTop: 6 }}><tbody>
            {d.team.map((p) => (
              <tr key={p.profile_id}><td>{p.name}{p.title ? <span className="muted"> · {p.title}</span> : null}</td>
                <td>$<input type="number" step="0.01" min="0" defaultValue={p.pay_rate ?? ''} style={{ width: 90 }}
                  onBlur={async (e) => { if (String(p.pay_rate ?? '') === e.target.value) return; try { await act('set_tech_pay', { p_profile: p.profile_id, p_pay: e.target.value === '' ? null : Number(e.target.value) }); setMsg(`Saved ${p.name}'s pay.`); } catch (x) { setErr(x.message); } }} /> /hr pay</td>
                <td><select defaultValue={p.crew_role || ''} style={{ width: 'auto' }} aria-label={`${p.name} works as`} onChange={async (e) => { try { await act('set_crew_role', { p_profile: p.profile_id, p_role: e.target.value || null }); setMsg(`${p.name}: saved.`); } catch (x) { setErr(x.message); } }}>
                  <option value="">Tech (leads calls)</option><option value="helper">Helper</option><option value="apprentice">Apprentice</option></select></td></tr>
            ))}
          </tbody></table>
          <div className="muted">Only the owner and billing see this. Job costing (Pro) uses pay plus your burden %.</div>
        </details>
      )}

      {edit && warnings.length > 0 && <div className="notice small" style={{ borderColor: '#e6c98a' }}>Check: {warnings.join('; ')}.</div>}
      {edit && (
        <div className="stack small" style={{ gap: 6 }}>
          <label className="row" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={confirm} onChange={(e) => setConfirm(e.target.checked)} />
            <strong>I set these rates myself.</strong> Service Call Proof doesn&apos;t set or recommend my prices.</label>
          {needOverride && <label className="row" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={override} onChange={(e) => setOverride(e.target.checked)} />Keep it anyway: these are the rates I want.</label>}
          <div><button className="primary" disabled={!confirm || !r.lead} onClick={save}>Save my rates</button></div>
        </div>
      )}
      {!edit && <div className="small muted">Your owner or billing sets these.</div>}
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
    </div>
  );
}
