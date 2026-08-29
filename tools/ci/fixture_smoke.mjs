#!/usr/bin/env node
// Drives tools/ci/renderer_fixture.html against the SHIPPED static replay
// viewer bundle in headless chromium.
//
// Why a second harness beside tools/ci/viewer_smoke.mjs: viewer_smoke proves
// the bundle LOADS AND PLAYS a real replay, which is the load-bearing gate.
// It cannot prove the feed's narration path draws, because docker_smoke.sh
// runs with NO ANTHROPIC_API_KEY: the CI replay's seat plays scripted and
// emits no `say` at all (the cogchemists 2026-08-24 scar). This harness loads
// the same bundle, in the same browser, and drives the REAL drawing code with
// synthetic chrome frames through the one hook the appended game block exports
// (`MinecraftChrome.__fixture`). It never re-implements the drawing (the
// particle-worlds 2026-08-26 scar).
//
// Usage:
//   node tools/ci/fixture_smoke.mjs --bundle <dir> --replay <file> [--timeout 60]
//
// Success is data-fixture="ok" on <html> of the fixture page; failure is
// data-fixture-error, or silence until the timeout. Exit 0 / 1.

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

function die(code, message) {
  console.error(message);
  process.exit(code);
}

function parseArgs(argv) {
  const out = { timeout: 60 };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => argv[++i];
    switch (arg) {
      case "--bundle": out.bundle = next(); break;
      case "--replay": out.replay = next(); break;
      case "--timeout": out.timeout = Number(next()); break;
      case "--out": out.outDir = next(); break;
      default:
        die(2, "unknown argument: " + arg);
    }
  }
  if (!out.bundle) die(2, "usage: fixture_smoke.mjs --bundle <dir> --replay <file>");
  if (!out.replay) die(2, "usage: fixture_smoke.mjs --bundle <dir> --replay <file>");
  return out;
}

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".json": "application/json",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".webp": "image/webp",
  ".ttf": "font/ttf",
  ".data": "application/octet-stream",
  ".replay": "application/octet-stream",
};

async function main() {
  const args = parseArgs(process.argv);
  const bundle = path.resolve(args.bundle);
  const replay = path.resolve(args.replay);
  const fixtureSrc = path.resolve("tools/ci/renderer_fixture.html");
  if (!fs.existsSync(path.join(bundle, "index.html"))) {
    die(1, "no index.html in " + bundle);
  }
  if (!fs.existsSync(fixtureSrc)) die(1, "missing " + fixtureSrc);
  // The fixture is served FROM the bundle directory so its iframe resolves
  // ./index.html against the real bundle, exactly as the platform serves it.
  const fixtureDst = path.join(bundle, "_renderer_fixture.html");
  fs.copyFileSync(fixtureSrc, fixtureDst);
  const replayName = path.basename(replay);
  fs.copyFileSync(replay, path.join(bundle, replayName));

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const rel = decodeURIComponent(url.pathname).replace(/^\/+/, "");
    const file = path.join(bundle, rel);
    if (!file.startsWith(bundle) || !fs.existsSync(file) ||
        fs.statSync(file).isDirectory()) {
      res.writeHead(404); res.end("not found"); return;
    }
    res.writeHead(200, {
      "Content-Type": CONTENT_TYPES[path.extname(file)] || "application/octet-stream",
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    });
    fs.createReadStream(file).pipe(res);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;
  const url = `${base}/_renderer_fixture.html?replay=${encodeURIComponent(base + "/" + replayName)}`;

  const playwrightModule = process.env.PLAYWRIGHT_MODULE || "playwright";
  const { chromium } = require(playwrightModule);
  const browser = await chromium.launch({ args: ["--no-sandbox"] });
  const page = await browser.newPage({ viewport: { width: 1000, height: 720 } });
  const console_ = [];
  page.on("console", (m) => console_.push(m.type() + ": " + m.text()));
  page.on("pageerror", (e) => console_.push("pageerror: " + e.message));

  let status = null;
  try {
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: args.timeout * 1000 });
    status = await page.waitForFunction(() => {
      const el = document.documentElement;
      if (el.getAttribute("data-fixture-error")) {
        return { ok: false, message: el.getAttribute("data-fixture-error") };
      }
      if (el.getAttribute("data-fixture") === "ok") return { ok: true };
      return null;
    }, null, { timeout: args.timeout * 1000 }).then((h) => h.jsonValue());
  } catch (error) {
    status = { ok: false, message: "timed out: " + error.message };
  }

  const log = await page.textContent("#log").catch(() => "");
  const outDir = args.outDir || process.cwd();
  await page.screenshot({ path: path.join(outDir, "fixture-smoke.png") })
    .catch(() => {});
  await browser.close();
  server.close();
  fs.rmSync(fixtureDst, { force: true });

  if (!status || !status.ok) {
    console.error("FIXTURE FAILED: " + (status ? status.message : "no signal"));
    console.error("--- fixture log ---\n" + log);
    console.error("--- last console ---\n" + console_.slice(-30).join("\n"));
    process.exit(1);
  }
  console.log(JSON.stringify({ fixture: "ok", log: (log || "").split("\n").length }));
}

main().catch((error) => die(1, "fixture_smoke crashed: " + error.stack));
