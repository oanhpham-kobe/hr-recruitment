import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const webRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const fixtureRoot = path.join(
  webRoot,
  "src/__tests__/fixtures/project-preview",
);
const args = process.argv.slice(2);
let output = path.join(webRoot, ".preview/eiu-project-preview.html");
let buildOnly = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--build-only") buildOnly = true;
  else if (
    args[i] === "--output" &&
    args[i + 1] &&
    path.isAbsolute(args[i + 1])
  )
    output = args[++i];
  else
    throw new Error(
      "Usage: node scripts/preview-project.mjs [--build-only] [--output ABS_PATH]",
    );
}
const portText = process.env.PROJECT_PREVIEW_PORT ?? "3427";
const port = Number(portText);
if (
  !/^\d+$/.test(portText) ||
  !Number.isSafeInteger(port) ||
  port < 1024 ||
  port > 65535
) {
  throw new Error(
    "PROJECT_PREVIEW_PORT must be an integer between 1024 and 65535.",
  );
}

function contained(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}
const aliases = JSON.parse(
  await readFile(path.join(fixtureRoot, "aliases.json"), "utf8"),
);
if (!aliases || Array.isArray(aliases) || typeof aliases !== "object")
  throw new Error("aliases.json must be an object.");
for (const [specifier, target] of Object.entries(aliases)) {
  if (
    !specifier ||
    typeof target !== "string" ||
    path.isAbsolute(target) ||
    !contained(fixtureRoot, path.resolve(webRoot, target))
  ) {
    throw new Error(`Invalid fixture alias: ${specifier}`);
  }
}
const mimeTypes = {
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".avif": "image/avif",
};
const result = await build({
  absWorkingDir: webRoot,
  entryPoints: [path.join(fixtureRoot, "main.tsx")],
  bundle: true,
  format: "iife",
  platform: "browser",
  conditions: ["browser"],
  minify: true,
  write: false,
  outdir: path.join(webRoot, ".preview/bundle"),
  define: { "process.env.NODE_ENV": '"production"' },
  loader: Object.fromEntries(
    Object.keys(mimeTypes).map((extension) => [extension, "dataurl"]),
  ),
  plugins: [
    {
      name: "synthetic-preview-boundary",
      setup(builder) {
        builder.onResolve({ filter: /.*/ }, async (args) => {
          if (Object.hasOwn(aliases, args.path))
            return { path: path.resolve(webRoot, aliases[args.path]) };
          if (/^(?:https?:)?\/\//i.test(args.path))
            throw new Error(`External resource is not allowed: ${args.path}`);
          if (args.kind !== "url-token" || /^(?:data:|#)/i.test(args.path))
            return;
          const root = args.path.startsWith("/")
            ? path.join(webRoot, "public")
            : webRoot;
          const assetPath = path.resolve(
            args.path.startsWith("/") ? root : args.resolveDir,
            args.path.replace(/^\//, "").split(/[?#]/)[0],
          );
          const resolved = await realpath(assetPath);
          if (!contained(await realpath(root), resolved))
            throw new Error(`Asset escapes preview root: ${args.path}`);
          return { path: resolved, namespace: "inline-preview-asset" };
        });
        builder.onLoad(
          { filter: /.*/, namespace: "inline-preview-asset" },
          async (args) => {
            const mime = mimeTypes[path.extname(args.path).toLowerCase()];
            if (!mime)
              throw new Error(`Unsupported preview asset: ${args.path}`);
            return { contents: await readFile(args.path), loader: "dataurl" };
          },
        );
      },
    },
  ],
});
const script = result.outputFiles.find((file) =>
  file.path.endsWith(".js"),
)?.text;
const style =
  result.outputFiles.find((file) => file.path.endsWith(".css"))?.text ?? "";
if (!script) throw new Error("Preview JavaScript bundle missing.");
const html = `<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'"><title>EIU Recruitment — Bản dùng thử</title><style>${style.replace(/<\/style/gi, "<\\/style")}</style></head><body><div id="root"></div><script>${script.replace(/<\/script/gi, "<\\/script")}</script></body></html>`;
await mkdir(path.dirname(output), { recursive: true });
await writeFile(output, html, "utf8");
console.log(`Standalone synthetic UAT preview: ${output}`);
if (!buildOnly) {
  const server = createServer((request, response) => {
    response.setHeader("Cache-Control", "no-store");
    response.setHeader("X-Content-Type-Options", "nosniff");
    if (request.method !== "GET" && request.method !== "HEAD") {
      response.writeHead(405, { Allow: "GET, HEAD" });
      response.end();
      return;
    }
    let pathname;
    try {
      pathname = new URL(request.url ?? "/", `http://127.0.0.1:${port}`)
        .pathname;
    } catch {
      response.writeHead(400);
      response.end();
      return;
    }
    if (pathname !== "/" && pathname !== "/project-preview") {
      response.writeHead(404);
      response.end(request.method === "HEAD" ? undefined : "Not found");
      return;
    }
    response.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Length": Buffer.byteLength(html),
    });
    response.end(request.method === "HEAD" ? undefined : html);
  });
  server.on("error", (error) => {
    console.error(
      error.code === "EADDRINUSE"
        ? `Port ${port} is in use. Stop the existing preview or set PROJECT_PREVIEW_PORT to another port. The standalone HTML was still generated.`
        : `Preview server failed: ${error.message}`,
    );
    process.exitCode = 1;
  });
  server.listen(port, "127.0.0.1", () =>
    console.log(
      `Synthetic UAT preview (no real services): http://127.0.0.1:${port}/project-preview`,
    ),
  );
  for (const signal of ["SIGINT", "SIGTERM"])
    process.once(signal, () => {
      server.close(() => process.exit(0));
      server.closeAllConnections();
    });
}
