'use client';

// Printable QR stickers: one per unit. Scanning opens the report page for that unit.
import { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { supabase, q } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';
import { useRouter } from 'next/navigation';
import OrderStickers from '@/components/OrderStickers';

export default function Stickers() {
  const { profile } = useProfile('/store');
  const router = useRouter();
  const [rows, setRows] = useState([]);
  const [site, setSite] = useState('');
  const [err, setErr] = useState('');
  const [siteList, setSiteList] = useState([]);

  useEffect(() => {
    if (!profile) return;
    (async () => {
      const eq = await q(supabase.from('equipment').select('id, qr_token, location_description, manufacturer, model, site_id, sites(name), equipment_types(name)').is('retired_at', null).order('site_id'));
      const withQr = await Promise.all(eq.map(async (e) => ({ ...e, img: await QRCode.toDataURL(`${window.location.origin}/r/${e.qr_token}`, { margin: 1, width: 240 }) })));
      setRows(withQr);
      setSiteList(await q(supabase.from('sites').select('id, name, address').order('name')));
    })().catch((e) => setErr(e.message));
  }, [profile]);

  if (!profile) return <div className="page muted">Loading…</div>;
  const sites = [...new Set(rows.map((r) => r.sites?.name))];
  const shown = rows.filter((r) => !site || r.sites?.name === site);
  return (
    <main className="page">
      <style>{`@media print { .noprint { display: none !important } body { background: #fff } } .sticker { break-inside: avoid; border: 1px dashed #999; border-radius: 8px; padding: 10px; text-align: center; width: 220px }`}</style>
      <div className="noprint spread" style={{ marginBottom: 12 }}>
        <div className="row"><button onClick={() => router.push('/store')}>‹ Back to dashboard</button><h1>QR stickers</h1></div>
        <div className="row">
          <select value={site} onChange={(e) => setSite(e.target.value)}><option value="">All locations</option>{sites.map((s) => <option key={s}>{s}</option>)}</select>
          <button className="primary" disabled={!shown.length} onClick={() => window.print()}>Print</button>
        </div>
      </div>
      {err && <div className="error">{err}</div>}
      <div className="noprint panel panel-pad" style={{ marginBottom: 12 }}>
        <OrderStickers sites={siteList} unitsBySite={rows.reduce((a, r) => ({ ...a, [r.site_id]: (a[r.site_id] || 0) + 1 }), {})} />
      </div>
      <div className="noprint small muted" style={{ marginBottom: 12 }}>Stick one on each unit. Employees scan it with their phone camera, enter the store PIN and pick the problem. Units not listed? Add them under Settings → Equipment, or your contractor adds them on their next visit.</div>
      {rows.length === 0 && !err && <div className="panel panel-pad stack noprint" style={{ maxWidth: 560 }}><strong>No equipment yet, so no stickers to print.</strong><span className="muted">Add your units under Settings → Equipment (each unit gets its own sticker), then come back here.</span><div><button onClick={() => router.push('/store?settings=equipment')}>Go to Equipment</button></div></div>}
      <div className="row" style={{ gap: 12, alignItems: 'flex-start' }}>
        {shown.map((r) => (
          <div key={r.id} className="sticker">
            <div style={{ fontWeight: 700 }}>Problem with this unit?</div>
            <img src={r.img} alt="QR code" width={180} height={180} />
            <div style={{ fontSize: 12 }}>{r.equipment_types?.name}{r.location_description ? ` — ${r.location_description}` : ''}</div>
            <div style={{ fontSize: 11, color: '#666' }}>{r.sites?.name} · scan, enter store PIN</div>
          </div>
        ))}
      </div>
    </main>
  );
}
