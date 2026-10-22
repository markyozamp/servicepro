'use client';

// One Settings area for a store company's admin: company & plan, locations, team, equipment, contractors & QR.
import { useState } from 'react';
import CompanyPlan from './CompanyPlan';
import LocationSettings from './LocationSettings';
import StoreTeam from './StoreTeam';
import StoreEquipment from './StoreEquipment';
import ContractorSettings from './ContractorSettings';

export const SETTINGS_TABS = [
  ['company', 'Settings & plan'], ['locations', 'Locations'], ['team', 'Team'], ['equipment', 'Equipment'], ['contractors', 'Contractors & QR'],
];

// What this person may open (admin sees everything).
export function storePerms(me) {
  const a = !!me?.is_org_admin;
  return {
    company: a || !!me?.can_manage_company,
    locations: a || !!me?.can_manage_locations,
    team: a || !!me?.can_manage_team,
    equipment: a || !!me?.can_manage_equipment || !!me?.can_manage_pm,
    contractors: a || !!me?.can_manage_contractors,
  };
}

export default function StoreSettings({ tab, setTab, onClose, me, org, onOrgChanged, hideTabs }) {
  const can = storePerms(me);
  const allowed = SETTINGS_TABS.filter(([k]) => can[k]);
  const [own, setOwn] = useState(null);
  const want = tab || own;
  const t = can[want] ? want : allowed[0]?.[0];
  const go = (x) => { setOwn(x); setTab?.(x); };
  return (
    <div className="panel panel-pad stack">
      <div className="spread"><h2>{SETTINGS_TABS.find(([k]) => k === t)?.[1] || 'Settings'}</h2><button onClick={onClose}>Close</button></div>
      {!hideTabs && <div className="tabs-row">
        {allowed.map(([k, label]) => <button key={k} className={t === k ? 'on' : ''} onClick={() => go(k)}>{label}</button>)}
      </div>}
      {t === 'company' && <CompanyPlan org={org} onSaved={onOrgChanged} />}
      {t === 'locations' && <LocationSettings />}
      {t === 'team' && <StoreTeam me={me} />}
      {t === 'equipment' && <StoreEquipment />}
      {t === 'contractors' && <ContractorSettings />}
    </div>
  );
}
