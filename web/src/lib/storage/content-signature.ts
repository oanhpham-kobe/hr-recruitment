const MIME_BY_EXTENSION: Record<string, string> = {
  pdf: "application/pdf",
  doc: "application/msword",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ppt: "application/vnd.ms-powerpoint",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
};

function hasPrefix(bytes: Uint8Array, prefix: number[]): boolean {
  return prefix.every((value, index) => bytes[index] === value);
}

function containsAscii(bytes: Uint8Array, value: string): boolean {
  for (let start = 0; start <= bytes.length - value.length; start += 1) {
    let matches = true;
    for (let index = 0; index < value.length; index += 1) {
      if (bytes[start + index] !== value.charCodeAt(index)) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

function containsUtf16Le(bytes: Uint8Array, value: string): boolean {
  const byteLength = value.length * 2;
  for (let start = 0; start <= bytes.length - byteLength; start += 1) {
    let matches = true;
    for (let index = 0; index < value.length; index += 1) {
      if (
        bytes[start + index * 2] !== value.charCodeAt(index) ||
        bytes[start + index * 2 + 1] !== 0
      ) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

export function detectUploadMimeType(bytes: Uint8Array): string | null {
  if (new TextDecoder().decode(bytes.slice(0, 5)) === "%PDF-") {
    return MIME_BY_EXTENSION.pdf;
  }
  if (hasPrefix(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return MIME_BY_EXTENSION.png;
  }
  if (hasPrefix(bytes, [0xff, 0xd8, 0xff])) {
    return MIME_BY_EXTENSION.jpg;
  }

  if (hasPrefix(bytes, [0x50, 0x4b, 0x03, 0x04])) {
    if (
      containsAscii(bytes, "[Content_Types].xml") &&
      containsAscii(bytes, "word/")
    ) {
      return MIME_BY_EXTENSION.docx;
    }
    if (
      containsAscii(bytes, "[Content_Types].xml") &&
      containsAscii(bytes, "ppt/")
    ) {
      return MIME_BY_EXTENSION.pptx;
    }
    return null;
  }

  if (hasPrefix(bytes, [0xd0, 0xcf, 0x11, 0xe0])) {
    if (
      containsAscii(bytes, "WordDocument") ||
      containsUtf16Le(bytes, "WordDocument")
    ) {
      return MIME_BY_EXTENSION.doc;
    }
    if (
      containsAscii(bytes, "PowerPoint Document") ||
      containsUtf16Le(bytes, "PowerPoint Document")
    ) {
      return MIME_BY_EXTENSION.ppt;
    }
  }
  return null;
}
