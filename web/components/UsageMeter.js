'use client';

// Fair use: texts and automatic phone calls used this plan year (pooled across the company), month by month,
// against the even pace line; projection; suggested top-up (packs of 100 credits).
import { useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { money, date } from '@/lib/format';
import Info from './Info';

export default function UsageMeter() {
  const [u, setU] = useState(null);
  const [err, setErr] = useState('');
  const [soon, setSoon] = useState(false);
  const [packs, setPacks] = useState(1);
  useEffect(() => { act('fair_use', {}).then((r) => { setU(r); setPacks(Math.max(1, r.suggested_packs || 1)); }).catch((e) => setErr(e.message)); }, []);
  if (err) return <div className="small muted">{err}</div>;
  if (!u) return <div className="small muted">Loading usage…</div>;

  const months = u.months.map((m) => ({ ...m, total: m.texts + m.calls }));
  const top = Math.max(u.pace_per_month * 1.25, ...months.map((m) => m.total), 1);
  const pacePct = (u.pace_per_month / top) * 100;
  const hot = u.projected > u.allowance;
  const warn = u.pct >= 75;

  return (
    <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
      <h3>Texts &amp; phone calls (fair use) <Info title="Fair use">{`Phone notifications and email are unlimited. Text messages (1 credit each) and automatic phone calls to your contractors (2 credits each) come with ${u.per_location} credits per location per year, shared across your company. That covers a small shop's normal year. Busier locations add credits as they need them: ${u.pack_credits} credits for ${money(u.pack_price)}, good to the end of the plan year. Alerts for emergency calls are never stopped.`}</Info></h3>

      <div className="usebar" role="img" aria-label={`${u.used} of ${u.allowance} credits used this year`}>
        <div className={`usebar-fill${u.pct >= 90 ? ' bad' : warn ? ' warn' : ''}`} style={{ width: `${Math.min(100, u.pct)}%` }} />
      </div>
      <div className="row spread small">
        <span><strong>{u.used.toLocaleString()}</strong> of {u.allowance.toLocaleString()} credits used ({u.pct}%){u.topped_up ? ` · includes ${u.topped_up.toLocaleString()} added` : ''}</span>
        <span className="muted">{u.remaining.toLocaleString()} left · resets {date(u.renews)}</span>
      </div>

      <div aria-hidden="true">
        <div className="usage-chart">
          <div className="usage-pace" style={{ bottom: `${pacePct}%` }}><span>even pace {u.pace_per_month}/mo</span></div>
          {months.map((m) => (
            <div key={m.start} className="usage-col" title={m.future ? `${m.month}: not yet` : `${m.month}: ${m.total} credits (${m.texts} from texts, ${m.calls} from phone calls)`}>
              <div className={`usage-bar${m.future ? ' future' : ''}`} style={{ height: `${(m.total / top) * 100}%` }} />
            </div>
          ))}
        </div>
        <div className="usage-lbls">{months.map((m) => <div key={m.start}>{m.month}</div>)}</div>
      </div>

      <div className={`small ${hot ? 'notice' : 'muted'}`}>
        {u.used === 0
          ? 'Nothing used yet this year. Texts and automatic phone calls are coming soon; this meter counts them once they start.'
          : hot
            ? <>At your current pace you'll use about <strong>{u.projected.toLocaleString()}</strong> credits this year, more than your {u.allowance.toLocaleString()}. Adding <strong>{u.suggested_packs} pack{u.suggested_packs === 1 ? '' : 's'}</strong> ({(u.suggested_packs * u.pack_credits).toLocaleString()} credits, {money(u.suggested_packs * u.pack_price)}) should carry you to {date(u.renews)}.</>
            : <>At your current pace you'll use about {u.projected.toLocaleString()} of {u.allowance.toLocaleString()} this year. You're fine.</>}
      </div>

      <div className="row" style={{ alignItems: 'flex-end' }}>
        <label>Packs<select value={packs} onChange={(e) => setPacks(Number(e.target.value))}>
          {[...new Set([1, 2, 3, 4, 5, 6, 8, 10, u.suggested_packs || 1])].sort((x, y) => x - y).map((n) => <option key={n} value={n}>{n} × {u.pack_credits.toLocaleString()} credits</option>)}
        </select></label>
        <button type="button" onClick={() => setSoon(true)}>Add {packs} pack{packs === 1 ? '' : 's'} · {money(packs * u.pack_price)} <span className="soon">Coming soon</span></button>
      </div>
      {soon && <div className="notice small">Coming soon: add credits here by card. A pack is {u.pack_credits.toLocaleString()} credits for {money(u.pack_price)}, good until {date(u.renews)}. For now, contact support@servicecallproof.com.</div>}

      <details className="small">
        <summary>Month by month</summary>
        <table><thead><tr><th>Month</th><th className="num">Texts</th><th className="num">Phone calls</th><th className="num">Credits</th></tr></thead>
          <tbody>{months.filter((m) => !m.future).map((m) => (
            <tr key={m.start}><td>{m.month}</td><td className="num">{m.texts}</td><td className="num">{m.calls / 2}</td><td className="num">{m.total}</td></tr>
          ))}</tbody></table>
      </details>
    </div>
  );
}
