# Release Notes v73 — Rekap Absensi session-scope fix

- Fixed `ReferenceError: SESSION_GEN is not defined` on the desktop attendance monitoring page.
- Exposed a read-only live accessor for the module-scoped session generation.
- Updated the classic desktop script to use the accessor in both monitoring and No Clock In cache keys.
- Preserved `hr_get_attendance_monitoring`, request parameters, timeout, RPC broker and backend permissions.
- No SQL changes.
- Service Worker and app-shell cache advanced to v73.
