import { LoginContent } from "@/components/auth/LoginContent";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const query = await searchParams;
  const first = (value: string | string[] | undefined) =>
    Array.isArray(value) ? value[0] : value;
  const errorCode = first(query.error) ?? null;
  const isInternal =
    first(query.persona) === "internal" ||
    [
      "FORBIDDEN",
      "NOT_FOUND",
      "IDENTITY_REBIND_FORBIDDEN",
      "MISSING_CODE",
      "AUTH_EXCHANGE_FAILED",
    ].includes(errorCode ?? "");

  return (
    <LoginContent
      key={`${isInternal ? "internal" : "candidate"}:${errorCode ?? ""}`}
      initialPersona={isInternal ? "internal" : "candidate"}
      initialErrorCode={errorCode}
    />
  );
}
