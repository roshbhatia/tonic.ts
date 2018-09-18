import { IntervalQuality } from '../IntervalQuality';

export const shorthandNames = [
  'P1',
  'm2',
  'M2',
  'm3',
  'M3',
  'P4',
  'TT',
  'P5',
  'm6',
  'M6',
  'm7',
  'M7',
  'P8',
];

export const longIntervalNames = [
  'Unison',
  'Minor 2nd',
  'Major 2nd',
  'Minor 3rd',
  'Major 3rd',
  'Perfect 4th',
  'Tritone',
  'Perfect 5th',
  'Minor 6th',
  'Major 6th',
  'Minor 7th',
  'Major 7th',
  'Octave',
];

// Major scale degree indexed by pitch class. The tritone has a null degree.
export const semitoneDegrees: Array<number | null> = shorthandNames
  .map((s) => s.match(/\d+/))
  .map((m) => m && Number(m[0]));

// Interval qualities indexed by pitch class. The tritone has a null quality.
export const semitoneQualities: Array<IntervalQuality | null> = shorthandNames
  .map((s) => s.match(/[AMPmd]/))
  .map((m) => m && IntervalQuality.fromString(m[0]));

// TODO: P and M optional; test perf, min, maj, dim, aug; ordinals
export function parseInterval(
  name: string,
): {
  degree: number | null;
  semitones: number;
  quality: IntervalQuality | null;
} {
  // base case / fast path
  let pc = shorthandNames.indexOf(name);
  if (pc < 0) {
    pc = longIntervalNames.indexOf(name);
  }
  if (pc >= 0) {
    return {
      degree: semitoneDegrees[pc],
      quality: semitoneQualities[pc],
      semitones: pc,
    };
  }
  const m =
    name.match(/^([AMPmd])(\d+)$/) ||
    name.match(/^(augmented|diminished)\s*(\d+)$/i);
  if (!m) {
    throw new Error(`No interval named ${name}`);
  }
  const qualityName = m[1];
  const degree = Number(m[2]);
  if (degree <= 8) {
    // Augmented or diminished. Find the closest natural, and adjust from there.
    pc = shorthandNames.indexOf(`P${degree}`);
    if (pc < 0) {
      const quality = IntervalQuality.fromString(qualityName);
      const nat = IntervalQuality.closestNatural(quality!);
      pc = shorthandNames.indexOf(`${IntervalQuality.toString(nat!)}${degree}`);
    }
    return {
      degree: semitoneDegrees[pc],
      quality: IntervalQuality.fromString(qualityName),
      semitones: pc,
    };
  } else {
    // complex interval. May also be augmented or diminished.
    const simple = parseInterval(`${qualityName}${degree - 7}`);
    return {
      degree: simple.degree! + 7,
      quality: simple.quality,
      semitones: simple.semitones + 12,
    };
  }
}
