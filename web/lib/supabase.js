import { createClient } from '@supabase/supabase-js';

// These two values are public by design (the publishable key only allows what
// the database's row-level security allows). Environment variables override them.
const url = process.env.NEXT_PUBLIC_SUPABASE_URL || 'https://svaoljxdoaefdqvvshhv.supabase.co';
const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_KqvxfxaerUNeBkVQvwhvZQ_HFviMsbL';

export const supabase = createClient(url, key, {
  auth: { persistSession: true, autoRefreshToken: true },
});

// Call a database action; returns data or throws a readable error.
export async function act(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}

export async function q(query) {
  const { data, error } = await query;
  if (error) throw new Error(error.message);
  return data;
}
