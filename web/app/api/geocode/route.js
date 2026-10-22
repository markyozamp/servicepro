// Address → map point, ZIP and time zone (US Census geocoder, free, no key).
import { tzForState } from '@/lib/tz';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET(req) {
  const address = (new URL(req.url).searchParams.get('address') || '').trim();
  if (address.length < 5 || address.length > 200) return Response.json({ found: false });
  const u = `https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?benchmark=Public_AR_Current&format=json&address=${encodeURIComponent(address)}`;
  try {
    const r = await fetch(u, { headers: { 'User-Agent': 'ServiceCallProof/1.0' }, signal: AbortSignal.timeout(10000) });
    const d = await r.json();
    const m = d?.result?.addressMatches?.[0];
    if (!m) return Response.json({ found: false });
    const st = m.addressComponents?.state;
    return Response.json({ found: true, address: m.matchedAddress, lat: m.coordinates.y, lon: m.coordinates.x,
      zip: m.addressComponents?.zip || '', state: st, timezone: tzForState(st) });
  } catch {
    return Response.json({ found: false, error: 'The address lookup did not answer. Try again in a moment.' });
  }
}
