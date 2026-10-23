// Busy hours on a location, in words and "is it busy right now" (the server enforces the rule; this is for display).
export const BUSY_DAYS = [['mon', 'Mon'], ['tue', 'Tue'], ['wed', 'Wed'], ['thu', 'Thu'], ['fri', 'Fri'], ['sat', 'Sat'], ['sun', 'Sun']];

const t12 = (hhmm) => {
  const [h, m] = hhmm.split(':').map(Number);
  const ap = h >= 12 ? 'PM' : 'AM'; const hh = h % 12 || 12;
  return `${hh}:${String(m).padStart(2, '0')} ${ap}`;
};
const ranges = (list) => (list || []).map((r) => `${t12(r[0])}–${t12(r[1])}`).join(', ');

export function busySummary(b) {
  if (!b) return '';
  const per = BUSY_DAYS.map(([d, l]) => [l, ranges(b[d])]);
  const set = per.filter(([, r]) => r);
  if (!set.length) return '';
  if (set.length === 7 && set.every(([, r]) => r === set[0][1])) return `Every day ${set[0][1]}`;
  return set.map(([l, r]) => `${l} ${r}`).join(' · ');
}

// Busy right now, in the location's time zone? Returns "11:00 AM–1:30 PM" or ''.
export function busyNow(b, tz) {
  if (!b) return '';
  try {
    const parts = new Intl.DateTimeFormat('en-US', { timeZone: tz || 'America/Chicago', weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date());
    const get = (k) => parts.find((p) => p.type === k)?.value;
    const day = get('weekday').toLowerCase().slice(0, 3);
    const now = `${get('hour').replace('24', '00')}:${get('minute')}`;
    const hit = (b[day] || []).find((r) => now >= r[0] && now < r[1]);
    return hit ? `${t12(hit[0])}–${t12(hit[1])}` : '';
  } catch { return ''; }
}
