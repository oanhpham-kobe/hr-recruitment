const SENSITIVE_KEY_PARTS = [
  "token",
  "secret",
  "password",
  "cookie",
  "authorization",
  "otp",
  "service_role",
  "cv_text",
  "document_url",
];

const bearerTokenPattern = /Bearer\s+[A-Za-z0-9\-._~+/]+=*/gi;
const jwtPattern =
  /\beyJ[A-Za-z0-9-_=]+\.[A-Za-z0-9-_=]+\.?[A-Za-z0-9-_.+/=]*/g;
const signedUrlParameterPattern =
  /([?&])(token|signature|apikey|key|secret|sig)=[^&\s]+/gi;
const embeddedCredentialPattern = /:\/\/([^:]+):([^@]+)@/g;
const otpPattern = /\b(otp|code|one-time password)[\s:=]+(\d{6})\b/gi;

export function redactString(value: string): string {
  return value
    .replace(bearerTokenPattern, "Bearer [REDACTED]")
    .replace(signedUrlParameterPattern, "$1$2=[REDACTED]")
    .replace(embeddedCredentialPattern, "://$1:[REDACTED]@")
    .replace(otpPattern, "$1: [REDACTED]")
    .replace(jwtPattern, "[REDACTED_JWT]");
}

function isSensitiveKey(key: string): boolean {
  const normalizedKey = key.toLowerCase();

  return SENSITIVE_KEY_PARTS.some((part) => normalizedKey.includes(part));
}

function redactValue(value: unknown, seen: WeakSet<object>): unknown {
  if (typeof value === "string") {
    return redactString(value);
  }

  if (value === null || typeof value !== "object") {
    return value;
  }

  if (value instanceof Error) {
    return {
      name: value.name,
      message: redactString(value.message),
    };
  }

  if (seen.has(value)) {
    return "[CIRCULAR]";
  }

  seen.add(value);

  if (Array.isArray(value)) {
    return value.map((entry) => redactValue(entry, seen));
  }

  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [
      key,
      isSensitiveKey(key) ? "[REDACTED]" : redactValue(entry, seen),
    ]),
  );
}

export function redactSensitiveData(value: unknown): unknown {
  return redactValue(value, new WeakSet<object>());
}

export function logError(error: unknown): void {
  console.error("command.error", redactSensitiveData(error));
}
