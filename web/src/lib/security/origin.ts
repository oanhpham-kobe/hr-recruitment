export function validateSameOrigin(request: Request): boolean {
  const source =
    request.headers.get("origin") ?? request.headers.get("referer");
  const host =
    request.headers.get("x-forwarded-host")?.split(",")[0]?.trim() ??
    request.headers.get("host");

  if (!source || !host) {
    return false;
  }

  try {
    const requestUrl = new URL(request.url);
    const protocol =
      request.headers.get("x-forwarded-proto")?.split(",")[0]?.trim() ??
      requestUrl.protocol.slice(0, -1);
    const expectedOrigin = new URL(`${protocol}://${host}`).origin;

    return new URL(source).origin === expectedOrigin;
  } catch {
    return false;
  }
}
