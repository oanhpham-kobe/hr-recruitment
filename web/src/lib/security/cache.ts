export function getSensitiveCacheHeaders(): Record<string, string> {
  return { "Cache-Control": "private, no-store" };
}
