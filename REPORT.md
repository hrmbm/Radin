# Incident Report — Rekap Absensi cannot load after v72 deployment

## User-provided runtime error

`ReferenceError: SESSION_GEN is not defined` at `fetchAttendanceMonitoring`, called by `renderAttPage` → `goPage`.

## Root cause

`SESSION_GEN` is declared at top level inside `<script type="module">`. `fetchAttendanceMonitoring()` and `showAttendanceMetricDetail()` are in a separate classic `<script>`. Top-level bindings in an ES module are module-scoped; they are not automatically added to `window` and cannot be referenced as free identifiers from a separate classic script.

The exception occurs while building the `noInDetailKey`, before the request function is called. Therefore, `hr_get_attendance_monitoring` does not appear in Network. This matches the user's observation.

## Fix

1. Add `window.rhGetSessionGeneration = function() { return SESSION_GEN; };` beside the module-scoped variable. This is a live read-only accessor, not a copied numeric value.
2. Add classic-script helper `attMonitorSessionGeneration()` that calls the accessor.
3. Replace the two classic-script references used by the attendance monitoring and No Clock In detail cache keys.
4. Keep RPC name, parameters, token broker, timeout, role gates, SQL and attendance rules unchanged.
5. Bump HTML and Service Worker release markers/cache to v73 so clients fetch the corrected frontend.

## Files changed

- `index.html`
- `sw.js`
- Regression expectations and dedicated runtime test files only.

No SQL changes or migrations are included.
