# Plan — Rekap Absensi Fix v73

1. Confirm the runtime error against the delivered v72 source.
2. Identify the ES-module/classic-script scope boundary.
3. Expose a live read-only accessor without making SESSION_GEN mutable from other scripts.
4. Update only the two Rekap Absensi session-key reads.
5. Keep RPC names, dates, access controls, SQL and business rules unchanged.
6. Run existing regression suites, browser runtime proof, syntax checks and release-integrity checks.
7. Package the targeted fix with this Plan, Walkthrough and Checkpoint.
