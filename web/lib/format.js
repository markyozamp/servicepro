export const money = (n) =>
  n == null ? '—' : Number(n).toLocaleString('en-US', { style: 'currency', currency: 'USD' });

export const time = (t) =>
  t ? new Date(t).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }) : '—';

export const date = (t) =>
  t ? new Date(t + (String(t).length === 10 ? 'T12:00:00' : '')).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) : '—';

export const dateTime = (t) =>
  t ? new Date(t).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '—';

export const ago = (t) => {
  if (!t) return '';
  const m = Math.round((Date.now() - new Date(t).getTime()) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} hr ago`;
  return `${Math.round(h / 24)} d ago`;
};

export const minutesUntil = (t) => (t ? Math.round((new Date(t).getTime() - Date.now()) / 60000) : null);
export const daysUntil = (t) => (t ? Math.ceil((new Date(t).getTime() - Date.now()) / 86400000) : null);

export const STATUS = {
  created: { label: 'New', tone: 'blue' },
  assigned: { label: 'Assigned', tone: 'violet' },
  en_route: { label: 'On the way', tone: 'amber' },
  on_site: { label: 'On site', tone: 'green' },
  awaiting_approval: { label: 'Needs approval', tone: 'red' },
  waiting_parts: { label: 'Waiting for parts', tone: 'amber' },
  return_needed: { label: 'Return visit needed', tone: 'violet' },
  completed: { label: 'Completed', tone: 'slate' },
  invoiced: { label: 'Invoiced', tone: 'slate' },
  cancelled: { label: 'Cancelled', tone: 'slate' },
};

export const KIND = { service: 'Service call', pm: 'Preventive maintenance', install: 'Install', estimate: 'Estimate' };
export const PRIORITY = { 1: 'Emergency', 2: 'Normal', 3: 'Low' };
export const PO_KIND = {
  diagnosis: 'Diagnosis', repair: 'Repair', additional: 'Additional repair', parts_price: 'Parts price change',
  after_hours: 'After hours', pm: 'PM visit', install: 'Install', other: 'Other',
};

export const FLAG_LABEL = {
  underbilling: 'Possible underbilling',
  overbilling: 'Possible overbilling',
  parts_missing: 'Usual parts not billed',
  parts_excessive: 'Parts beyond usual kit',
  labor_out_of_range: 'Labor time unusual',
  po_near_cap: 'Near approved amount',
  po_exceeded: 'Over approved amount',
  time_override: 'Time corrected',
  gps_mismatch: 'Arrival location mismatch',
  checkin_unverified: 'Check-in not verified',
  billing_late: 'Bill is late',
  closeout_override: 'Closed without full documentation',
};

export const poLabel = (wo, seq) => (wo.store_po_number || `PO${wo.number}`) + (seq > 0 ? String.fromCharCode(64 + seq) : '');
