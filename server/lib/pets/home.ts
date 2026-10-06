import type { PetStoredContext } from "@/lib/db/schema";

/** Farther than this from home, the owner is on a trip. A commute or a day out stays well inside it. */
export const TRAVEL_DISTANCE_KM = 80;
/** Away from home this long, the owner has moved: where they are now becomes home. */
export const HOME_MOVES_AFTER_MS = 21 * 24 * 60 * 60 * 1000;
/** Context older than this says nothing about where the owner is now. */
export const LOCATION_STALE_MS = 24 * 60 * 60 * 1000;

type Point = { latitude: number; longitude: number };

/** The great-circle distance between two points, in kilometres. */
export function distanceKm(a: Point, b: Point): number {
  const radians = (degrees: number) => (degrees * Math.PI) / 180;
  const dLat = radians(b.latitude - a.latitude);
  const dLon = radians(b.longitude - a.longitude);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(radians(a.latitude)) * Math.cos(radians(b.latitude)) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Where the owner is now, or null when the server has no location for them, or only an old one. */
export function currentLocation(context: PetStoredContext | null, now: Date): Point | null {
  if (context?.latitude === undefined || context.longitude === undefined) return null;
  if (now.getTime() - new Date(context.updatedAt).getTime() >= LOCATION_STALE_MS) return null;
  return { latitude: context.latitude, longitude: context.longitude };
}

/** Whether the owner is far from home right now. */
export function isTraveling(context: PetStoredContext | null, now: Date): boolean {
  const here = currentLocation(context, now);
  return !!here && !!context?.home && distanceKm(here, context.home) > TRAVEL_DISTANCE_KM;
}

/**
 * Learns home from where the owner keeps being: the first place they are seen is home, and being
 * far from it starts a trip, which ends when they are back. A trip that lasts weeks was a move, so
 * home follows them. A context without a location leaves home as it was.
 */
export function trackHome(context: PetStoredContext, now: Date): PetStoredContext {
  if (context.latitude === undefined || context.longitude === undefined) return context;
  const here = { latitude: context.latitude, longitude: context.longitude };
  if (!context.home) return { ...context, home: here, awaySince: undefined };
  if (distanceKm(here, context.home) <= TRAVEL_DISTANCE_KM) return { ...context, awaySince: undefined };
  const awaySince = context.awaySince ?? now.toISOString();
  if (now.getTime() - new Date(awaySince).getTime() >= HOME_MOVES_AFTER_MS) {
    return { ...context, home: here, awaySince: undefined };
  }
  return { ...context, awaySince };
}

/** Everything the server knows of where the owner is or was, gone: tracking was turned off. */
export function forgetLocation(context: PetStoredContext): PetStoredContext {
  const rest = { ...context };
  delete rest.latitude;
  delete rest.longitude;
  delete rest.home;
  delete rest.awaySince;
  return rest;
}
