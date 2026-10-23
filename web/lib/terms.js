'use client';

// What a customer calls its places: stores, restaurants, facilities, properties, homes, or just "locations".
// Chosen at setup and in Settings (customers.place_word). Every customer-side screen takes its wording from here,
// so the whole app speaks the customer's language. Contractor- and tech-facing text stays neutral ("customer", "location").
import { useSyncExternalStore } from 'react';

const WORDS = {
  location:   ['location', 'locations', 'Location manager'],
  store:      ['store', 'stores', 'Store manager'],
  restaurant: ['restaurant', 'restaurants', 'Restaurant manager'],
  facility:   ['facility', 'facilities', 'Facility manager'],
  property:   ['property', 'properties', 'Property manager'],
  home:       ['home', 'homes', 'Homeowner'],
};

export const PLACE_CHOICES = [
  ['store', 'Stores'], ['restaurant', 'Restaurants'], ['facility', 'Facilities'],
  ['property', 'Properties'], ['home', 'Homes'], ['location', 'Locations (general)'],
];

const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);

export function placeTerms(word) {
  const [one, many, manager] = WORDS[word] || WORDS.location;
  return {
    word: WORDS[word] ? word : 'location',
    one, many, One: cap(one), Many: cap(many), manager,
    count: (n) => `${n} ${n === 1 ? one : many}`,
    pin: `${cap(one)} PIN`,
  };
}

let current = 'location';
const subs = new Set();
export function setPlaceWord(w) {
  const next = WORDS[w] ? w : 'location';
  if (next === current) return;
  current = next;
  subs.forEach((f) => f());
}
const subscribe = (f) => { subs.add(f); return () => subs.delete(f); };

// The signed-in customer's words. Before the company has loaded (and for contractors), the neutral "location".
export function usePlace() {
  const w = useSyncExternalStore(subscribe, () => current, () => 'location');
  return placeTerms(w);
}
