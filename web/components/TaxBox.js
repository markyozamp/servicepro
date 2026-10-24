'use client';

// The tax for this location, on the bill and quote screens: which rate (found by its city or state, or picked),
// change it, and the customer's tax exemption (certificate on file).
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { pct } from '@/lib/tax';

const WHY = { picked: 'picked for this location', city: 'its city', state: 'the state rate' };

export default function TaxBox({ siteId, onChanged, onInfo }) {
  const [t, setT] = useState(null);
  const [err, setErr] = useState('');
  const [ex, setEx] = useState(null);     // editing the exemption
  const load = useCallback(async () => { if (!siteId) return; try { const r = await act('site_tax', { p_site: siteId }); setT(r); onInfo?.(r); } catch (x) { setErr(x.message); } }, [siteId]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, [load]);
  if (!siteId) return null;
  if (!t) return err && !/Base/.test(err) ? <div className="small muted">{err}</div> : null;
  if (!t.on) return <div className="small muted">No sales tax set up. To charge tax, add your rates under Team → Sales tax rates.</div>;
  const pick = async (id) => { setErr(''); try { const r = await act('set_site_tax_area', { p_site: siteId, p_area: id || null }); setT(r); onInfo?.(r); onChanged?.(); } catch (x) { setErr(x.message); } };
  return (
    <div className="taxbox small stack" style={{ gap: 6 }}>
      <div className="row" style={{ gap: 8, alignItems: 'center' }}>
        <strong>Tax:</strong>
        {t.area ? <span>{t.area.name} {pct(t.area.rate)} <span className="muted">({WHY[t.area.source]})</span></span>
          : <span style={{ color: 'var(--red-fg)' }}>no rate for this location. Pick one</span>}
        <select value={t.area?.source === 'picked' ? t.area.id : ''} onChange={(e) => pick(e.target.value)} style={{ width: 'auto', maxWidth: 240 }} aria-label="Tax rate for this location">
          <option value="">{t.area && t.area.source !== 'picked' ? 'Automatic' : 'Automatic (city or state)'}</option>
          {t.areas.map((a) => <option key={a.id} value={a.id}>{a.name} {pct(a.rate)}</option>)}
        </select>
      </div>
      {t.exempt ? <div><span className="chip tone-green">Tax exempt</span> {t.exempt_note}{t.exempt_until ? ` · until ${t.exempt_until}` : ''} <span className="muted">No sales tax on their bills; use tax on built-in parts is still yours.</span>
        {t.can_exempt && <button type="button" className="linkbtn small" onClick={async () => { if (!window.confirm('Remove the exemption for this customer?')) return; try { await act('set_customer_tax_exempt', { p_customer: t.customer_id, p_exempt: false }); load(); onChanged?.(); } catch (x) { setErr(x.message); } }}>Remove</button>}</div>
        : t.can_exempt && (ex ? (
          <form className="row" style={{ gap: 6, alignItems: 'flex-end' }} onSubmit={async (e) => {
            e.preventDefault(); setErr('');
            try { await act('set_customer_tax_exempt', { p_customer: t.customer_id, p_exempt: true, p_note: ex.note, p_until: ex.until || null }); setEx(null); load(); onChanged?.(); } catch (x) { setErr(x.message); }
          }}>
            <label className="grow">Exemption certificate<input value={ex.note} onChange={(e) => setEx({ ...ex, note: e.target.value })} placeholder="e.g. ND E-595E #12345" /></label>
            <label style={{ flex: '0 0 150px' }}>Good until<input type="date" value={ex.until} onChange={(e) => setEx({ ...ex, until: e.target.value })} /></label>
            <button>Save</button><button type="button" onClick={() => setEx(null)}>Cancel</button>
          </form>) : <button type="button" className="linkbtn small" style={{ alignSelf: 'flex-start' }} onClick={() => setEx({ note: '', until: '' })}>This customer is tax exempt…</button>)}
      {err && <div className="error small">{err}</div>}
    </div>
  );
}
