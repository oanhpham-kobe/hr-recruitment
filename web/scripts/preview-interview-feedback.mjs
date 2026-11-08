import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { build } from "esbuild";

const port = Number(process.env.FEEDBACK_PREVIEW_PORT ?? 3417);
if (!Number.isSafeInteger(port) || port < 1024 || port > 65535)
  throw new Error("Invalid preview port");
const result = await build({
  loader: { ".ttf": "dataurl", ".jpg": "dataurl" },
  absWorkingDir: process.cwd(),
  entryPoints: ["src/__tests__/fixtures/interview-feedback-preview.tsx"],
  bundle: true,
  format: "iife",
  platform: "browser",
  conditions: ["browser"],
  outdir: "feedback-preview-assets",
  write: false,
});
const script = result.outputFiles.find((f) => f.path.endsWith(".js"))?.contents;
const style = result.outputFiles.find((f) => f.path.endsWith(".css"))?.contents;
if (!script || !style) throw new Error("Preview bundle missing");
const html =
  '<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>EIU — Synthetic interview feedback preview</title><link rel="stylesheet" href="/preview.css"></head><body><div id="root"></div><script src="/preview.js" defer></script></body></html>';
const server = createServer(async (req, res) => {
  const pathname = new URL(req.url ?? "/", `http://127.0.0.1:${port}`).pathname;
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("X-Content-Type-Options", "nosniff");
  if (req.method !== "GET") {
    res.writeHead(405);
    res.end();
    return;
  }
  if (pathname === "/preview.js") {
    res.setHeader("Content-Type", "text/javascript; charset=utf-8");
    res.end(script);
    return;
  }
  if (pathname === "/preview.css") {
    res.setHeader("Content-Type", "text/css; charset=utf-8");
    res.end(style);
    return;
  }
  if (
    /^\/fonts\/[a-zA-Z0-9_./-]+\.(woff2?|ttf)$/.test(pathname) &&
    !pathname.includes("..")
  ) {
    try {
      const font = await readFile(path.join(process.cwd(), "public", pathname));
      res.setHeader(
        "Content-Type",
        pathname.endsWith(".woff2") ? "font/woff2" : "font/woff",
      );
      res.end(font);
      return;
    } catch {
      res.writeHead(404);
      res.end();
      return;
    }
  }
  if (
    pathname === "/" ||
    pathname === "/interview-feedback" ||
    /^\/interview-feedback\/[a-f0-9-]+$/i.test(pathname)
  ) {
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(html);
    return;
  }
  res.writeHead(404);
  res.end("Not found");
});
server.listen(port, "127.0.0.1", () =>
  process.stdout.write(
    `Synthetic preview (no email): http://127.0.0.1:${port}/interview-feedback\n`,
  ),
);
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, () => server.close(() => process.exit(0)));
