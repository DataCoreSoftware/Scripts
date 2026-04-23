# Original Hardening Lists (Windows Hardening)

This folder contains **unmodified hardening lists** sourced from the official
**windows_hardening** repository, which is maintained by the HardeningKitty
project contributors.

Source repository:
https://github.com/0x6d69636b/windows_hardening

## Purpose

These lists represent the **original upstream security baselines** (Microsoft,
CIS, DoD STIG, etc.) and are stored locally in this repository to:

- Ensure **reproducibility** of audits and hardening operations
- Avoid dependency on upstream repository changes
- Provide a **baseline reference** for comparison against DataCore-customized
  hardening lists

## Scope

- The lists in this folder are **not modified**.
- Any security exceptions or tuning required for DataCore SANsymphony are
  implemented **outside of this folder**, in DataCore-specific lists.

## Execution

These lists are consumed by HardeningKitty as the execution engine.
HardeningKitty itself is downloaded separately and is **not the source of these
baselines**.

