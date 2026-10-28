# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-28

First public release.

### Added

- Tiered context ceilings (routine / deep) with a grace band that escalates
  instead of cutting a task off.
- `Stop` hook hard wrap: one `decision: "block"` per ceiling crossing, so the
  handoff brief is written before the session continues.
- Effort gears (`low` / `medium` / `xhigh` / `max`) with an escalate-only router.
- `/wrap` handoff writer and `SessionStart` re-seed, as an alternative to
  `/compact`.
- `audit.ps1` per-session token and cost report, `stats.ps1` decision summary,
  and a CSV decision log.
- `install.ps1` / `uninstall.ps1` with idempotent `settings.json` merging and
  timestamped backups.
- Self-test (45 assertions) and installer test (38 assertions), both sandboxed.
- GitHub Actions workflow running both suites on Windows.

### Notes

- Windows PowerShell 5.1 is the supported runtime. `pwsh` 7 works but was
  measured slower on the development machine; see the latency section.
- Hooks fail open: any error exits 0 and lets Claude Code continue.
