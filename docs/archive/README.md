# Archived development notes

See the [project documentation](../info.md) for the current project.
Files here describe past work, not the current submission.

## Original README — 2026-11-16

[README-before-cleanup-2026-11-16.md](README-before-cleanup-2026-11-16.md)
is an unchanged copy of the complete local README before cleanup, including
notes that had not been committed.

It contains DC/ICC2 setup instructions, floorplan and power-grid work, SRAM
integration notes, timing constraints, and earlier Formality/PrimeTime results.
Statements such as “not integrated” or “PG validation incomplete” describe
older stages. Relative paths refer to the old repository layout.

## Previous RTL integration settings

[rtl-integration/config_512.json](rtl-integration/config_512.json) and
[rtl-integration/config_1024.json](rtl-integration/config_1024.json) are historical
settings from before the full accelerator became a hard macro. They are not
runnable configurations for the current wrapper. Their old PDN scripts remain
in git history. The active configuration is `src/config.json` (512 B).

## Previous project documentation — 2026-11-16

[info-before-cleanup-2026-11-16.md](info-before-cleanup-2026-11-16.md)
is an unchanged copy of the previous `docs/info.md`. It includes historical
memory-controller details, earlier FIFO sizes, and pre-layout area comparisons.
Those figures do not describe the current hardened core.
