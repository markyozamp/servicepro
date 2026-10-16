export const money = (n) =>
  n == null ? '—' : Number(n).toLocaleString('en-US', { style: 'currency', currency: 'USD' });

export const time = (t) =>
  t ? new Date(t).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }) : '—';

export const dateTime = (t) =>
  t
    ? new Date(t).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
    : '—';

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

export const STATUS = {
  created: { label: 'New', tone: 'blue' },
  assigned: { label: 'Assigned', tone: 'violet' },
  en_route: { label: 'On the way', tone: 'amber' },
  on_site: { label: 'On site', tone: 'green' },
  awaiting_approval: { label: 'Needs approval', tone: 'red' },
  completed: { label: 'Completed', tone: 'slate' },
  invoiced: { label: 'Invoiced', tone: 'slate' },
  cancelled: { label: 'Cancelled', tone: 'slate' },
};

export const PRIORITY = { 1: 'Emergency', 2: 'Normal', 3: 'Low' };

export const FLAG_LABEL = {
  underbilling: 'Possible underbilling',
  overbilling: 'Possible overbilling',
  parts_missing: 'Usual parts not billed',
  parts_excessive: 'Parts beyond usual kit',
  labor_out_of_range: 'Labor time unusual',
  po_near_cap: 'Near PO cap',
  po_exceeded: 'Over PO cap',
  time_override: 'Time corrected',
  gps_mismatch: 'Arrival location mismatch',
};

export const EQUIPMENT_LABEL = (t) => (t ? t.replace(/_/g, ' ') : '');
