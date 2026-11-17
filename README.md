# HRIS Reholz — Rekap Absensi Fix v73

Paket perbaikan terarah untuk error `ReferenceError: SESSION_GEN is not defined` saat membuka Rekap Absensi desktop setelah deployment v72.

## Deploy

Deploy these together at the same application scope:
- `index.html`
- `sw.js`
- `assets/`

No SQL migration is required for this fix. After deployment, refresh the browser/service worker and run the smoke test in `CHECKPOINT.md`.

## Package contents
- `index.html` — frontend v73.
- `sw.js` — Service Worker v73.
- `assets/` — existing logos.
- `tests/` — previous regression suites plus the new scope/runtime test.
- `PLAN.md`, `WALKTHROUGH.md`, `CHECKPOINT.md`, `REPORT.md`, `TEST_RESULTS.md`.

## Important boundary

The fix removes the JavaScript exception that stopped Rekap Absensi before network access. It does not change the RPC contract or SQL. Live RPC availability and returned data must still be confirmed in the deployed Supabase project.
