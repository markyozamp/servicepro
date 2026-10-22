// Time zone for a US state (the zone most of the state uses). Used when a location is added from its address.
const Z = {
  'America/New_York': 'CT DE DC FL GA IN KY ME MD MA MI NH NJ NY NC OH PA RI SC VT VA WV',
  'America/Chicago': 'AL AR IL IA KS LA MN MS MO NE ND OK SD TN TX WI',
  'America/Denver': 'CO ID MT NM UT WY',
  'America/Phoenix': 'AZ',
  'America/Los_Angeles': 'CA NV OR WA',
  'America/Anchorage': 'AK',
  'Pacific/Honolulu': 'HI',
  'America/Puerto_Rico': 'PR VI',
};
export function tzForState(st) {
  const s = String(st || '').toUpperCase();
  for (const [tz, list] of Object.entries(Z)) if (list.split(' ').includes(s)) return tz;
  return 'America/Chicago';
}
