# Repository Guidance

Before repository work, run `git fetch origin`. Do not implicitly merge or
rebase dirty or feature checkouts. Use a clean task worktree based on the
current remote default branch; keep the original checkout unchanged.

## Disposable QA Storage

This guidance applies only to this repository's first-party diagnostics, not
vendored/third-party code or other repositories.

- Default disposable diagnostic/audit logs, screenshots, frame dumps and
  browser reports to the OS temporary directory in an application-specific,
  unique per-run subdirectory, such as `cogame-minecraft-qa-<unique-run-id>`.
  Use platform temporary-directory APIs or `mktemp -d`, and existing helpers
  where available; do not reuse a fixed shared QA directory.
- Respect explicit output paths, artifact URIs and intentional retention.
  Preserve retained replays, evidence, saves, checkpoints, and research
  inputs/outputs, including game trajectory/proof records. Do not silently
  classify them as disposable or move them to temporary storage.
- Bound capture duration, frame/file count and supported byte limits; check
  free space on the destination filesystem before large captures and report
  the actual artifact path. Stop or skip if space is insufficient.
- Temporary storage may share the checkout's disk and is not guaranteed to
  clear on reboot. It does not reduce live disk consumption.
- Keep live IPC/control sockets, status pointers, leases and databases at
  their required fixed locations so consumers remain compatible.
- Codex/Claude sessions, prompts, traces, histories, recovery exports, indexes
  and databases are protected archival data, never disposable game QA output.
  NEVER delete, prune, rotate, truncate, rewrite or move any of them. Do not
  redirect coding-agent storage to temporary directories.
- This policy does not authorize cleanup. Leave existing artifacts, other
  tasks' outputs untouched.
- For AGENTS.md-only changes, use documentation checks (`git diff --check`
  and diff review); do not run game builds, dependency sync or populate global
  build/dependency caches.
- Repository-specific diagnostic reference:
  `tools/ci/viewer_smoke.mjs` supports `--out`, `--timeout`
  and `--soak` and emits `viewer-smoke.png` / `viewer-smoke.json`. For
  disposable local QA, pass a unique temporary directory via `--out`; keep
  explicit retained replay/evidence paths unchanged.
