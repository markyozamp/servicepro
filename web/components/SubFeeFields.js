'use client';

// The extra fields on a subcontractor or fee / permit line: what kind, who (subs), his cost, and his markup
// (blank = passed through at cost). The price on the line follows. Cost, markup and the sub's name stay private.
import { SUB_TYPES, FEE_TYPES, subFeePrice } from '@/lib/tax';

export default function SubFeeFields({ l, onChange }) {
  const sub = l.kind === 'sub';
  const upd = (patch) => {
    const n = { ...l, ...patch };
    if ('cost' in patch || 'markup' in patch) n.rate = subFeePrice(n.cost, n.markup);
    onChange(n);
  };
  return (
    <div className="row small" style={{ gap: 6, marginTop: 4, alignItems: 'center', flexWrap: 'wrap' }}>
      <select value={(sub ? l.sub_type : l.fee_type) || ''} onChange={(e) => upd(sub ? { sub_type: e.target.value } : { fee_type: e.target.value })} style={{ width: 'auto' }} aria-label={sub ? 'Kind of subcontractor' : 'Kind of fee'}>
        <option value="">{sub ? 'Trade…' : 'Kind of fee…'}</option>
        {(sub ? SUB_TYPES : FEE_TYPES).map((t) => <option key={t} value={t}>{t}</option>)}
      </select>
      {sub && <input value={l.vendor || ''} onChange={(e) => upd({ vendor: e.target.value })} placeholder="Sub's name (private)" style={{ width: 170 }} />}
      <label className="row" style={{ gap: 4, fontWeight: 400 }}>your cost $<input type="number" step="0.01" min="0" value={l.cost ?? ''} onChange={(e) => upd({ cost: e.target.value })} style={{ width: 90 }} /></label>
      <label className="row" style={{ gap: 4, fontWeight: 400 }}>+<input type="number" step="0.1" min="0" value={l.markup ?? ''} onChange={(e) => upd({ markup: e.target.value })} style={{ width: 70 }} placeholder="0" />%</label>
      <span className="muted">{l.markup === '' || l.markup == null || Number(l.markup) === 0 ? 'passed through at cost' : 'markup'} · private</span>
    </div>
  );
}
