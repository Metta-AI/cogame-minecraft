#!/usr/bin/env node
// Smoke-tests the STATIC WASM replay viewer bundle — the artifact the
// observatory actually serves — by loading a fixture replay and stepping
// frames inside the wasm32 runtime, exactly as index.html does.
//
// Why this exists: the native test suite runs 64-bit, where Nim `int` is
// 64 bits and multi-GB allocations succeed. The shipped viewer is
// --cpu:wasm32 — `int` is 32 bits (overflow checks trap on arithmetic that
// is silently fine natively) and the address space ends at 2 GB. Both
// classes of bug reached prod invisible to CI and killed every hosted
// replay into a permanent "WARMING UP" (see PR #189: trenchEdgeNoise
// overflow, keyframe map-bake bloat). This script fails CI on the next one.
//
// Usage: node tools/wasm_replay_smoke.cjs <dist-dir> <replay-file> [frames]

'use strict';
const fs = require('fs');
const path = require('path');

const distDir = path.resolve(process.argv[2] || 'replay-viewer/dist');
const replayPath = process.argv[3];
const frameBudget = parseInt(process.argv[4] || '300', 10);
if (!replayPath) {
  console.error('usage: wasm_replay_smoke.cjs <dist-dir> <replay-file> [frames]');
  process.exit(2);
}

// A hung load (e.g. an allocation loop) must fail loudly, not stall the job.
const watchdog = setTimeout(() => {
  console.error('FAIL: smoke did not finish within 120s');
  process.exit(1);
}, 120000);

// The bundle is injected below with `Module` as a function parameter — a
// plain require() cannot configure it: the emitted `var Module` declaration
// hoists over any global we set, so locateFile/onRuntimeInitialized would be
// silently ignored and the .data preload resolves against the cwd.
const Module = {
  locateFile: (p) => path.join(distDir, p),
  onRuntimeInitialized: run,
  onAbort: (what) => {
    // Allocation failure aborts (-s ABORTING_MALLOC=1) but leaves linear
    // memory intact: the stage buffer still says what exhausted it.
    const stage = readStageNote();
    console.error('FAIL: wasm runtime aborted: ' + what +
      (stage ? '\nruntime was: ' + stage : ''));
    process.exit(1);
  },
};

function readStageNote() {
  try {
    const length = Module._minecraft_stage_len ? Module._minecraft_stage_len() : 0;
    if (!length) return '';
    const pointer = Module._minecraft_stage_ptr();
    return Buffer.from(Module.HEAPU8.subarray(pointer, pointer + length)).toString('utf8');
  } catch (ignored) {
    return '';
  }
}

function readRuntimeError() {
  const length = Module._minecraft_error_len();
  if (length) {
    const pointer = Module._minecraft_error_ptr();
    return Buffer.from(Module.HEAPU8.subarray(pointer, pointer + length)).toString('utf8');
  }
  const stage = readStageNote();
  return stage
    ? '(no error text; runtime was: ' + stage + ')'
    : '(runtime reported no error text)';
}

function run() {
  const bytes = fs.readFileSync(replayPath);
  const pointer = Module._malloc(bytes.length);
  Module.HEAPU8.set(bytes, pointer);
  const loaded = Module._minecraft_load_replay(pointer, bytes.length);
  Module._free(pointer);
  if (loaded !== 1) {
    console.error('FAIL: minecraft_load_replay rejected ' + path.basename(replayPath) +
      '\n' + readRuntimeError());
    process.exit(1);
  }
  if (Module._minecraft_packet_len() <= 0) {
    console.error('FAIL: first frame produced an empty packet');
    process.exit(1);
  }
  if (Module._minecraft_mismatch_tick() !== -1) {
    console.error('FAIL: replay hash mismatch at tick ' + Module._minecraft_mismatch_tick() +
      ' — the wasm sim diverged from the recording');
    process.exit(1);
  }
  let packetBytes = 0;
  for (let i = 0; i < frameBudget; i++) {
    if (Module._minecraft_frame() !== 1) {
      console.error('FAIL: minecraft_frame died at frame ' + i + '\n' + readRuntimeError());
      process.exit(1);
    }
    packetBytes += Module._minecraft_packet_len();
  }
  if (Module._minecraft_mismatch_tick() !== -1) {
    console.error('FAIL: replay hash mismatch at tick ' + Module._minecraft_mismatch_tick() +
      ' after ' + frameBudget + ' frames');
    process.exit(1);
  }
  clearTimeout(watchdog);
  console.log('ok: loaded ' + path.basename(replayPath) + ', advanced ' +
    frameBudget + ' frames (' + packetBytes + ' packet bytes, heap ' +
    Math.round(Module.HEAPU8.length / 1024 / 1024) + ' MB)');
  process.exit(0);
}

const bundlePath = path.join(distDir, 'minecraft_replay.js');
new Function('Module', 'require', '__filename', '__dirname',
  fs.readFileSync(bundlePath, 'utf8'))(Module, require, bundlePath, distDir);
