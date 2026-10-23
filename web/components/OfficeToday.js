'use client';

// Contractor "Today": everything that needs the office right now, most urgent first, as one list. Made for running the
// business from a phone; tap anything to open the call.
import { dateTime, date, daysUntil, ago, FLAG_LABEL } from '@/lib/format';

const latest = (w) => (w.visits || []).filter((v) => v.status !== 'cancelled').sort((a, b) => b.visit_no - a.visit_no)[0];
const where = (w) => [w.customers?.name, w.sites?.name].filter(Boolean).join(' · ');

function Item({ w, right, urgent, sub, onOpen }) {
  return (
    <button type="button" className={`today-item${urgent ? ' urgent' : ''}`} onClick={() => onOpen(w.id)}>
      <span className="stack" style={{ gap: 2, minWidth: 0 }}>
        <span className="small muted">#{w.number}{w.priority === 1 ? ' · ⚠ Emergency' : ''} · {where(w)}</span>
        <strong style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{w.issue_description}</strong>
        {sub && <span className="small">{sub}</span>}
      </span>
      <span className="row" style={{ gap: 6, flex: '0 0 auto' }}>{right}<span className="go" aria-hidden="true">›</span></span>
    </button>
  );
}

function Section({ title, count, hot, children }) {
  if (!count) return null;
  return (
    <section className="today-sec">
      <h3>{title} <span className={`count${hot ? '' : ' muted-count'}`} style={hot ? undefined : { background: 'var(--ink-3)' }}>{count}</span></h3>
      {children}
    </section>
  );
}

export default function OfficeToday({ calls, flags, onOpen }) {
  const now = Date.now();
  const open = (w) => !['completed', 'invoiced', 'cancelled'].includes(w.status) && !w.declined_at;
  const toAccept = calls.filter((w) => w.status === 'created' && w.mode === 'verify' && !w.accepted_at && !w.declined_at)
    .sort((a, b) => new Date(a.accept_due_at || 0) - new Date(b.accept_due_at || 0));
  const toAssign = calls.filter((w) => w.status === 'created' && w.mode !== 'verify' && !latest(w) && w.kind !== 'pm');
  const toSchedule = calls.filter((w) => w.status === 'created' && w.mode === 'verify' && w.accepted_at && !w.declined_at && !latest(w));
  const missed = calls.filter((w) => open(w) && (w.visits || []).some((v) => v.status === 'assigned' && v.missed_alert_at));
  const onSite = calls.filter((w) => ['on_site', 'awaiting_approval'].includes(w.status));
  const parts = calls.filter((w) => ['waiting_parts', 'return_needed'].includes(w.status));
  const toBill = calls.filter((w) => w.status === 'completed').sort((a, b) => new Date(a.invoice_due_at) - new Date(b.invoice_due_at));
  const pm = calls.filter((w) => w.kind === 'pm' && open(w) && w.due_on && daysUntil(w.due_on) <= 7).sort((a, b) => (a.due_on > b.due_on ? 1 : -1));
  const review = flags.filter((f) => f.blocking);
  const total = toAccept.length + toAssign.length + toSchedule.length + missed.length + onSite.length + parts.length + toBill.length + pm.length + review.length;

  if (!total) return <div className="panel panel-pad"><strong>You're all caught up.</strong><div className="small muted">New calls, trips to schedule and bills to send show up here.</div></div>;

  return (
    <div className="stack" style={{ gap: 18 }}>
      <Section title="Accept now" count={toAccept.length + toAssign.length} hot>
        {toAccept.map((w) => {
          const due = w.accept_due_at ? new Date(w.accept_due_at).getTime() : null;
          const mins = due ? Math.round((due - now) / 60000) : null;
          const held = w.hold_until && !w.hold_released_at && new Date(w.hold_until).getTime() > now;
          return <Item key={w.id} w={w} onOpen={onOpen} urgent={!held && (mins == null || mins < 15)}
            sub={held ? `Customer chose to wait for regular hours: comes due ${dateTime(w.hold_until)}` : mins == null ? `opened ${ago(w.created_at)}` : mins < 0 ? `Accept deadline passed ${dateTime(w.accept_due_at)}` : `Accept within ${mins < 120 ? `${mins} min` : `by ${dateTime(w.accept_due_at)}`}`}
            right={<span className="chip tone-red">Accept</span>} />;
        })}
        {toAssign.map((w) => <Item key={w.id} w={w} onOpen={onOpen} urgent={w.priority === 1} sub={`opened ${ago(w.created_at)}`} right={<span className="chip tone-amber">Assign a tech</span>} />)}
      </Section>

      <Section title="Schedule a trip" count={toSchedule.length} hot>
        {toSchedule.map((w) => <Item key={w.id} w={w} onOpen={onOpen} sub={`Accepted ${dateTime(w.accepted_at)}`} right={<span className="chip tone-amber">Schedule</span>} />)}
      </Section>

      <Section title="Missed a window" count={missed.length} hot>
        {missed.map((w) => <Item key={w.id} w={w} onOpen={onOpen} urgent sub={`Was due ${dateTime(latest(w)?.scheduled_start)}`} right={<span className="chip tone-red">Late</span>} />)}
      </Section>

      <Section title="Needs review" count={review.length} hot>
        {review.map((f) => (
          <button key={f.id} type="button" className="today-item" onClick={() => onOpen(f.work_order_id)}>
            <span className="stack" style={{ gap: 2 }}><span className="small muted">#{f.work_orders?.number} · {f.work_orders?.sites?.name}</span>
              <strong>{FLAG_LABEL[f.flag] || f.flag}</strong><span className="small">{f.description}</span></span>
            <span className="go" aria-hidden="true">›</span>
          </button>
        ))}
      </Section>

      <Section title="Bills to send" count={toBill.length} hot={toBill.some((w) => daysUntil(w.invoice_due_at) < 0)}>
        {toBill.map((w) => {
          const d = daysUntil(w.invoice_due_at);
          return <Item key={w.id} w={w} onOpen={onOpen} urgent={d < 0} sub={`Finished ${date(w.completed_at)}`}
            right={<span className={`chip ${d < 0 ? 'tone-red' : d <= 2 ? 'tone-amber' : 'tone-slate'}`}>{d < 0 ? `${-d} days late` : `due in ${d} day${d === 1 ? '' : 's'}`}</span>} />;
        })}
      </Section>

      <Section title="On site now" count={onSite.length}>
        {onSite.map((w) => <Item key={w.id} w={w} onOpen={onOpen} sub={latest(w)?.profiles?.full_name ? `🔧 ${latest(w).profiles.full_name}` : null}
          right={(w.po_lines || []).some((l) => l.status === 'pending') ? <span className="chip tone-red">Waiting on approval</span> : <span className="chip tone-green">On site</span>} />)}
      </Section>

      <Section title="Waiting on parts / return trip" count={parts.length}>
        {parts.map((w) => <Item key={w.id} w={w} onOpen={onOpen} right={<span className="chip tone-slate">{w.status === 'return_needed' ? 'Return trip' : 'Parts'}</span>} />)}
      </Section>

      <Section title="Maintenance due" count={pm.length} hot={pm.some((w) => daysUntil(w.due_on) < 0)}>
        {pm.map((w) => {
          const d = daysUntil(w.due_on);
          return <Item key={w.id} w={w} onOpen={onOpen} urgent={d < 0} right={<span className={`chip ${d < 0 ? 'tone-red' : 'tone-amber'}`}>{d < 0 ? `${-d} days overdue` : `due ${date(w.due_on)}`}</span>} />;
        })}
      </Section>
    </div>
  );
}
