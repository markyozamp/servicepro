'use client';

// "Watch it work": the store screen (left) and the technician's phone (right), side by side, fully interactive.
// It runs entirely in this browser — each visitor has their own copy, nothing is saved, and "Start over" resets it.
// On phones the two sides are a toggle (Store | Tony's phone), with a dot when something changed on the other side.
import { useEffect, useState } from 'react';

const CODE = '7444';
const STEPS = [
  'Tony is at the door. Type the check-in code from the store screen (7444) into Tony\'s phone.',
  'Tony is checked in. Take a "before" photo on his phone; it lands on the store\'s call.',
  'Tony found a bad shutoff valve. Ask the store to approve $180 from his phone.',
  'The store has to decide. Approve or decline on the store side.',
  'Tony\'s done. Tap Leaving on his phone.',
  'The bill arrives, and it\'s checked against the verified time automatically.',
];

const Pin = ({ hot }) => (
  <svg className={`sim-pin${hot ? ' hot' : ''}`} viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
    <path d="M12 2a7 7 0 0 0-7 7c0 5.2 7 13 7 13s7-7.8 7-13a7 7 0 0 0-7-7z" /><circle cx="12" cy="9" r="2.6" fill="#fff" />
  </svg>
);
const Photo = () => (
  <svg viewBox="0 0 120 80" className="sim-photo" aria-label="Photo: under the sink">
    <rect width="120" height="80" fill="#cfd8e0" /><rect x="10" y="44" width="100" height="30" fill="#9aa9b6" />
    <rect x="52" y="8" width="8" height="40" fill="#7d8b97" /><circle cx="56" cy="40" r="7" fill="#c0392b" />
    <path d="M30 70 q8 -10 16 0" stroke="#3f6fa0" strokeWidth="3" fill="none" />
  </svg>
);

export default function DemoSim({ onDone }) {
  const [step, setStep] = useState(0);
  const [code, setCode] = useState('');
  const [bad, setBad] = useState(false);
  const [photo, setPhoto] = useState(false);
  const [decision, setDecision] = useState(null); // 'approved' | 'declined'
  const [left, setLeft] = useState(false);
  const [bill, setBill] = useState(false);
  const [view, setView] = useState('phone'); // phones: which side is showing

  // Which side the next action happens on (phones: show a dot on the other tab)
  const actOn = step === 3 ? 'store' : step >= 5 ? 'store' : 'phone';
  useEffect(() => { if (left) { const t = setTimeout(() => { setBill(true); setStep(5); }, 1400); return () => clearTimeout(t); } return undefined; }, [left]);
  // When the walkthrough is done, take the visitor to the real program below
  useEffect(() => { if (bill && onDone) { const t = setTimeout(onDone, 3000); return () => clearTimeout(t); } return undefined; }, [bill]); // eslint-disable-line react-hooks/exhaustive-deps

  function reset() { setStep(0); setCode(''); setBad(false); setPhoto(false); setDecision(null); setLeft(false); setBill(false); setView('phone'); }
  function checkIn(e) {
    e.preventDefault();
    if (code.trim() === CODE) { setBad(false); setStep(1); } else setBad(true);
  }
  const doorHot = step === 0;
  const approvalHot = step === 3;
  const pinHot = doorHot || approvalHot || bill;
  const onSite = step >= 1 && !left;
  const total = decision === 'approved' ? '$367.50' : '$187.50';

  const store = (
    <div className="sim-store" aria-label="Store screen">
      <div className="sim-bar"><span className="sim-dot" /><span className="sim-dot" /><span className="sim-dot" /><span className="sim-url">servicecallproof.com/store</span></div>
      <div className="sim-store-in">
        <div className="sim-head">
          <img src="/demo-logos/northside.svg" alt="Northside Grocers" className="sim-logo" />
          <span className={`sim-loc${pinHot ? ' hot' : ''}`}><Pin hot={pinHot} /> Store #114 {pinHot && <span className="sim-chip red">needs attention</span>}</span>
        </div>

        {doorHot && (
          <div className="sim-door">
            <div><strong>Tony Berg</strong> (Prairie Plumbing) is at the door</div>
            <div className="small">Call #1124 · PO NS-4482 · Leak under the 3-compartment sink</div>
            <div className="sim-code">Read this check-in code to them: <strong>{CODE}</strong></div>
          </div>
        )}

        {approvalHot && (
          <div className="sim-approve">
            <div><strong>Approval needed</strong> · Call #1124</div>
            <div className="small">Tony found a corroded shutoff valve. Replace it: parts and labor <strong>$180</strong>.</div>
            <div className="sim-row">
              <button className="sim-btn green" onClick={() => { setDecision('approved'); setStep(4); }}>Approve $180</button>
              <button className="sim-btn" onClick={() => { setDecision('declined'); setStep(4); }}>Decline</button>
            </div>
          </div>
        )}

        <div className="sim-card">
          <div className="sim-card-h">In the building now</div>
          {onSite ? <div className="small">🔧 <strong>Tony Berg</strong> · Prairie Plumbing · checked in 9:41 AM with the code</div>
            : <div className="small muted">{left ? 'Nobody right now. Tony left at 10:22 AM.' : 'Nobody checked in yet.'}</div>}
        </div>

        <div className="sim-card">
          <div className="sim-card-h">Call #1124 · Leak under the 3-compartment sink</div>
          <div className="sim-row small">
            <span className={`sim-chip ${step === 0 ? 'amber' : left ? 'slate' : 'green'}`}>{step === 0 ? 'Tech at the door' : left ? 'Done, bill pending' : 'On site'}</span>
            <span className="muted">Not to exceed $300</span>
          </div>
          {step >= 1 && <div className="small sim-times">Arrived 9:40 · Checked in 9:41{left ? ' · Left 10:22 · ' : ''}{left && <strong>Verified on site: 42 min</strong>}</div>}
          {photo && <div className="sim-row small" style={{ alignItems: 'center' }}><Photo /><span>Before photo · under the sink · 9:44 AM</span></div>}
          {decision && <div className="small">{decision === 'approved' ? '✓ You approved the $180 valve at 9:52 AM' : '✗ You declined the valve at 9:52 AM'}</div>}
        </div>

        {bill && (
          <div className="sim-bill">
            <div className="sim-card-h">Bill #6702 from Prairie Plumbing · {total}</div>
            <div className="sim-billgrid small">
              <span>Hours billed</span><strong>1.5 h</strong>
              <span>Hours verified on site</span><strong>0.7 h</strong>
              <span className="red">Not explained</span><strong className="red">0.8 h (48 min)</strong>
            </div>
            <div className="small">Service Call Proof caught it before you paid. One tap asks Prairie Plumbing to explain the extra time.</div>
            <div className="sim-row"><button className="sim-btn">Ask them to explain</button><button className="sim-btn ghost">Approve anyway</button></div>
          </div>
        )}
      </div>
    </div>
  );

  const phone = (
    <div className="sim-phone" aria-label="Technician's phone">
      <div className="sim-notch" />
      <div className="sim-screen">
        <div className="sim-ptop"><strong>Service Call <span>Proof</span></strong><span>Tony</span></div>
        <div className="sim-pbody">
          <div className="small muted">Northside Grocers · Store #114</div>
          <div className="sim-pjob">Leak under the 3-compartment sink</div>
          {step === 0 && (
            <form className="sim-stack" onSubmit={checkIn}>
              <div className="sim-chip green" style={{ alignSelf: 'flex-start' }}>📍 You're here</div>
              <div className="small">Ask someone at the store for the check-in code.</div>
              <input className="sim-input" inputMode="numeric" maxLength={6} value={code} onChange={(e) => { setCode(e.target.value.replace(/\D/g, '')); setBad(false); }} placeholder="Check-in code" aria-label="Check-in code" />
              {bad && <div className="small red">That code doesn't match. Look at the store screen.</div>}
              <button className="sim-btn big blue" type="submit">Check in</button>
            </form>
          )}
          {step >= 1 && !left && (
            <div className="sim-stack">
              <div className="sim-chip green" style={{ alignSelf: 'flex-start' }}>✓ Checked in 9:41 AM</div>
              <button className="sim-btn big" disabled={photo} onClick={() => { setPhoto(true); setStep(2); }}>📷 {photo ? 'Photo added' : 'Take a before photo'}</button>
              {photo && <Photo />}
              {step === 2 && <button className="sim-btn big blue" onClick={() => setStep(3)}>Ask the store: replace valve, $180</button>}
              {step === 3 && <div className="sim-wait small">⏳ Waiting for the store to approve $180…</div>}
              {decision && <div className={`small ${decision === 'approved' ? 'green' : 'red'}`}>{decision === 'approved' ? '✓ Approved by Sam (store manager). Go ahead.' : '✗ Declined. Finish the basic repair only.'}</div>}
              {step === 4 && <button className="sim-btn big red-b" onClick={() => setLeft(true)}>Leaving · job done</button>}
            </div>
          )}
          {left && (
            <div className="sim-stack">
              <div className="sim-chip slate" style={{ alignSelf: 'flex-start' }}>Left 10:22 AM</div>
              <div className="small">Job done. Your time on site is recorded: <strong>42 min</strong>. Your office enters the bill.</div>
            </div>
          )}
        </div>
      </div>
    </div>
  );

  return (
    <div className="sim">
      <div className="sim-hint">
        <span className="sim-stepno">{bill ? 'Done' : `Step ${Math.min(step, 4) + 1} of 5`}</span>
        <span>{bill ? 'That\'s Service Call Proof: who came, when, for how long, and a bill checked against it.' : STEPS[step]}</span>
        {bill && onDone && <button className="sim-btn small" onClick={onDone}>Try the real program ↓</button>}
        <button className="sim-btn ghost small" onClick={reset}>Start over</button>
      </div>
      <div className="sim-toggle">
        <button className={view === 'store' ? 'on' : ''} onClick={() => setView('store')}>Store{actOn === 'store' && view !== 'store' && <span className="sim-ping" />}</button>
        <button className={view === 'phone' ? 'on' : ''} onClick={() => setView('phone')}>Tony's phone{actOn === 'phone' && view !== 'phone' && <span className="sim-ping" />}</button>
      </div>
      <div className={`sim-grid show-${view}`}>
        <div className="sim-side store-side"><div className="sim-label">The store's screen</div>{store}</div>
        <div className="sim-side phone-side"><div className="sim-label">Tony's phone</div>{phone}</div>
      </div>
    </div>
  );
}
