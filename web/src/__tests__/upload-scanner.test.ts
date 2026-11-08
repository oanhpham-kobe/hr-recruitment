import assert from "node:assert/strict";
import test from "node:test";
import { detectUploadMimeType } from "@/lib/storage/upload-scanner";

function asciiBytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

test("detectUploadMimeType rejects generic ZIP bytes", () => {
  const bytes = asciiBytes("PK\u0003\u0004generic archive payload");

  assert.equal(detectUploadMimeType(bytes), null);
});

test("detectUploadMimeType distinguishes Word and PowerPoint OOXML packages", () => {
  const word = asciiBytes("PK\u0003\u0004[Content_Types].xmlword/document.xml");
  const presentation = asciiBytes(
    "PK\u0003\u0004[Content_Types].xmlppt/presentation.xml",
  );

  assert.equal(
    detectUploadMimeType(word),
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  );
  assert.equal(
    detectUploadMimeType(presentation),
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  );
});

test("detectUploadMimeType identifies PDF and rejects renamed cross-format bytes", () => {
  const pdf = asciiBytes("%PDF-1.7\n");

  assert.equal(detectUploadMimeType(pdf), "application/pdf");
  assert.notEqual(
    detectUploadMimeType(pdf),
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  );
});
