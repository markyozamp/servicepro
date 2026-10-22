'use client';

// One Settings area for a store company's admin: company & plan, locations, team, equipment, contractors & QR.
import { useState } from 'react';
import CompanyPlan from './CompanyPlan';
import LocationSettings from './LocationSettings';
import StoreTeam from './StoreTeam';
import StoreEquipment from './StoreEquipment';
import ContractorSettings from './ContractorSettings';

export const SETTINGS_TABS = [
  ['company', 'Company & plan'], ['locations', 'Locations'], ['team', 'Team'], ['equipment', 'Equipment'], ['contractors', 'Contractors & QR'],
];

export default function StoreSettings({ tab, setTab, onClose, me, org, onOrgChanged }) {
  const [t, setT] = useState(tab || 'company');
  const go = (x) => { setT(x); setTab?.(x); };
  return (
    <div className="panel panel-pad stack">
      <div className="spread"><h2>Settings</h2><button onClick={onClose}>Close</button></div>
      <div className="tabs-row">
        {SETTINGS_TABS.map(([k, label]) => <button key={k} className={t === k ? 'on' : ''} onClick={() => go(k)}>{label}</button>)}
      </div>
      {t === 'company' && <CompanyPlan org={org} onSaved={onOrgChanged} />}
      {t === 'locations' && <LocationSettings />}
      {t === 'team' && <StoreTeam me={me} />}
      {t === 'equipment' && <StoreEquipment />}
      {t === 'contractors' && <ContractorSettings />}
    </div>
  );
}
