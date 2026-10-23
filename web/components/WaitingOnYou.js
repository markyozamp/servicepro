'use client';

// "Waiting on you": everything at your locations that needs your answer, oldest first, with how long it has waited.
// Tap one to go to it. If nobody answers, a reminder goes out (15 min for urgent, 4 hours for routine), then it goes
// to the location's backup person.
import { ago } from '@/lib/format';

export default function WaitingOnYou({ attention, siteId, sites, onGoTo }) {
  const many = (sites || []).length > 1 && !siteId;
  const list = (attention || [])
    .filter((a) => !siteId || a.site_id === siteId)
    .flatMap((a) => (a.items || []).filter((i) => i.waiting).map((i) => ({ ...i, site_id: a.site_id, site: a.name })))
    .sort((x, y) => (y.urgent - x.urgent) || (new Date(x.at || 0) - new Date(y.at || 0)));
  if (!list.length) return null;
  return (
    <div id="waiting" className="panel panel-pad stack waiting-list" style={{ gap: 6 }}>
      <strong>Waiting on you ({list.length})</strong>
      <ol className="stack" style={{ gap: 4, margin: 0, paddingLeft: 0, listStyle: 'none' }}>
        {list.map((i) => (
          <li key={`${i.target}-${i.kind}`}>
            <button type="button" className="waiting-row" onClick={() => onGoTo(i.site_id, i.target)}>
              {i.urgent && <span className="chip tone-red">Urgent</span>}
              <span className="grow">{i.label}{many ? <span className="muted"> · {i.site}</span> : null}</span>
              {i.at && <span className="small muted">{ago(i.at)}</span>}
              <span aria-hidden="true">›</span>
            </button>
          </li>
        ))}
      </ol>
    </div>
  );
}
