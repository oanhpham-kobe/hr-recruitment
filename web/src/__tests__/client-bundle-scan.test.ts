import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

const forbiddenIdentifiers = [
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_SECRET_KEY",
  "SERVICE_ROLE_KEY",
];

async function readFilesRecursively(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(
    entries.map(async (entry) => {
      const entryPath = path.join(directory, entry.name);

      if (entry.isDirectory()) {
        return readFilesRecursively(entryPath);
      }

      return entry.isFile() ? [entryPath] : [];
    }),
  );

  return files.flat();
}

test("client chunks contain no server secret identifiers", async () => {
  const staticDirectory = path.resolve(".next/static");
  const files = await readFilesRecursively(staticDirectory);
  const contents = await Promise.all(
    files.map((file) => readFile(file, "utf8")),
  );
  const clientBundle = contents.join("\n");

  for (const identifier of forbiddenIdentifiers) {
    assert.equal(
      clientBundle.includes(identifier),
      false,
      `client bundle exposed ${identifier}`,
    );
  }
});
