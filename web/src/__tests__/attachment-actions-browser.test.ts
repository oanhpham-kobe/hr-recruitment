import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { chromium } from "playwright";

test("attachment controls preserve capabilities, keyboard actions, pending state and 320px reflow", async () => {
  const bundle = await build({
    stdin: {
      contents: `
      import { createRoot } from 'react-dom/client';
      import { AttachmentActions } from './src/components/ui/AttachmentActions';
      import './src/app/globals.css';
      window.calls = [];
      const cases = [
        ['pdf', 'application/pdf'], ['png', 'image/png'], ['jpeg', 'image/jpeg'],
        ['doc', 'application/msword'], ['docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
        ['ppt', 'application/vnd.ms-powerpoint'], ['pptx', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'],
        ['blocked', 'application/pdf'], ['pending', 'application/pdf'], ['disabled', 'image/png'], ['no-access', 'application/pdf']
      ];
      createRoot(document.getElementById('root')).render(<main>{cases.map(([id,mime]) => <section key={id} aria-label={id} className="drawer-doc-item">
        <span className="drawer-doc-item__info">{'long-filename-'.repeat(12)}{id}</span>
        <AttachmentActions filename={id} mimeType={mime} locale="en" previewable={id !== 'blocked'} pending={id === 'pending'} disabled={id === 'disabled'}
          onPreview={id === 'no-access' ? undefined : () => window.calls.push([id,'preview'])}
          onDownload={id === 'no-access' ? undefined : () => window.calls.push([id,'download'])} />
      </section>)}</main>);
    `,
      resolveDir: process.cwd(),
      loader: "tsx",
    },
    jsx: "automatic",
    bundle: true,
    format: "iife",
    platform: "browser",
    conditions: ["browser"],
    write: false,
    outdir: "attachment-fixture",
    loader: { ".ttf": "dataurl", ".jpg": "dataurl" },
  });
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({
      viewport: { width: 320, height: 800 },
    });
    await page.setContent('<div id="root"></div>');
    await page.addStyleTag({
      content: bundle.outputFiles.find((f) => f.path.endsWith(".css"))?.text,
    });
    await page.addScriptTag({
      content: bundle.outputFiles.find((f) => f.path.endsWith(".js"))?.text,
    });
    const preview = page.getByRole("button", {
      name: "Preview: pdf",
      exact: true,
    });
    await preview.waitFor();
    for (const id of ["pdf", "png", "jpeg"])
      assert.equal(
        await page
          .getByRole("button", { name: `Preview: ${id}`, exact: true })
          .count(),
        1,
      );
    for (const id of ["doc", "docx", "ppt", "pptx", "blocked"]) {
      assert.equal(
        await page
          .getByRole("button", { name: `Preview: ${id}`, exact: true })
          .count(),
        0,
      );
      assert.equal(
        await page
          .getByRole("button", { name: `Download: ${id}`, exact: true })
          .count(),
        1,
      );
    }
    assert.equal(
      await page
        .getByRole("region", { name: "no-access", exact: true })
        .getByRole("button")
        .count(),
      0,
    );
    await preview.focus();
    await page.keyboard.press("Enter");
    await page.keyboard.press("Tab");
    await page.keyboard.press("Space");
    assert.deepEqual(
      await page.evaluate(
        () => (window as unknown as { calls: string[][] }).calls,
      ),
      [
        ["pdf", "preview"],
        ["pdf", "download"],
      ],
    );
    for (const id of ["pending", "disabled"])
      assert.equal(
        await page
          .getByRole("button", { name: `Download: ${id}`, exact: true })
          .isDisabled(),
        true,
      );
    assert.equal(
      await page
        .getByRole("button", { name: "Preview: pending", exact: true })
        .getAttribute("aria-busy"),
      "true",
    );
    const box = await preview.boundingBox();
    assert.ok(box && box.width >= 44 && box.height >= 44);
    assert.ok(
      await page.evaluate(() => document.documentElement.scrollWidth <= 320),
    );
  } finally {
    await browser.close();
  }
});
