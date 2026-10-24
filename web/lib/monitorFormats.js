// Translate sensor messages from the brands we support into plain readings:
//   { id, at?, temp_c? | temp_f?, door_open?, battery? }
// Unknown fields are ignored; a message can hold one reading or many.

const num = (v) => (v === null || v === undefined || v === '' || Number.isNaN(Number(v)) ? undefined : Number(v));
const firstNum = (o, keys) => { for (const k of keys) { const v = num(o?.[k]); if (v !== undefined) return v; } return undefined; };

function door(o) {
  for (const k of ['door_open', 'door', 'magnet_status', 'magnet', 'open']) {
    if (o?.[k] === undefined || o?.[k] === null) continue;
    const v = String(o[k]).toLowerCase();
    if (['open', 'opened', '1', 'true', 'on'].includes(v)) return true;
    if (['close', 'closed', '0', 'false', 'off'].includes(v)) return false;
  }
  return undefined;
}

function one(id, at, d) {
  if (!id) return null;
  const r = { id: String(id).trim() };
  if (at) r.at = at;
  const tf = firstNum(d, ['temp_f', 'temperature_f']);
  const tc = tf === undefined ? firstNum(d, ['temp_c', 'temperature', 'temperature_c', 'probe_temperature', 'temperature_1', 'temp']) : undefined;
  if (tf !== undefined) r.temp_f = tf; else if (tc !== undefined) r.temp_c = tc;
  const dr = door(d); if (dr !== undefined) r.door_open = dr;
  const b = firstNum(d, ['battery', 'battery_pct', 'batteryLevel', 'battery_level', 'bat']); if (b !== undefined) r.battery = b;
  return Object.keys(r).length > 1 ? r : null;
}

export function translate(body) {
  if (!body || typeof body !== 'object') return [];
  if (Array.isArray(body)) return body.flatMap(translate);
  // Plain format: { readings: [...] }
  if (Array.isArray(body.readings)) return body.readings.map((x) => one(x.id, x.at, x)).filter(Boolean);
  // Monnit webhook: { gatewayMessage, sensorMessages: [{ sensorID, dataValue, batteryLevel, messageDate, dataType }] }
  if (Array.isArray(body.sensorMessages)) {
    return body.sensorMessages.map((m) => {
      const dv = m.dataValue;
      const d = { battery: m.batteryLevel };
      if (/temp/i.test(m.dataType || m.applicationID || 'temp') && num(dv) !== undefined) d.temperature = dv;
      if (/open|close/i.test(String(m.displayData || dv))) d.door = /open/i.test(String(m.displayData || dv));
      return one(m.sensorID, m.messageDate ? new Date(`${m.messageDate}Z`).toISOString() : undefined, d);
    }).filter(Boolean);
  }
  // The Things Network v3
  if (body.end_device_ids) {
    return [one(body.end_device_ids.dev_eui, body.received_at, body.uplink_message?.decoded_payload || {})].filter(Boolean);
  }
  // ChirpStack v4 / Milesight network server
  const id = body.devEUI || body.deveui || body.dev_eui || body.devEui || body.deviceInfo?.devEui || body.deviceEUI;
  const at = body.time || body.timestamp || undefined;
  const d = body.object || body.decoded || body.data_decoded || body.payload || body;
  const r = one(id, typeof at === 'string' && !Number.isNaN(Date.parse(at)) ? at : undefined, typeof d === 'object' ? d : body);
  return r ? [r] : [];
}
