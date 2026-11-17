# CHECKPOINT — Paket A

## Checklist
- [x] Label UI Surabaya & Sekitarnya, tanpa label kode SBY yang terlihat.
- [x] Status normal tetap H.
- [x] Piket di SBY tetap P melalui trigger server.
- [x] Sakit tetap SDR; tidak ada varian SDR-SBY.
- [x] Standby tidak menerima SBY.
- [x] GPS raw tetap outside dan validasi radius server tidak dilemahkan.
- [x] Rekap/ekspor memakai label Pengaturan Lokasi Surabaya & Sekitarnya.
- [x] Insentif SBY tidak diklasifikasikan sebagai Dinas Luar.

## Status verifikasi
Tes statis source dan pemeriksaan struktur SQL tersedia dalam `tests/subtask-A.test.cjs`. SQL belum dijalankan ke Supabase staging/produksi; validasi database runtime masih checkpoint deployment.

## Angka hasil tes
- Tes khusus sampai Paket A: **17/17 lulus**.
- Delapan suite regresi Tahap 2–4: **seluruhnya PASS**, tanpa kegagalan.
- 7 blok JavaScript inline dan Service Worker: **lolos pemeriksaan sintaks**.
- Marker HTML dan cache Service Worker: **cocok**.

## Regresi yang ikut disertakan
Pada snapshot ini seluruh 8 suite regresi sebelumnya lulus:
- Approval popup proportions: 12/12
- Approval cross-platform: 27/27
- Approval desktop layout: 23/23
- Approval independent checks: 30/30
- Approval UI consistency: 21/21
- Approval flow regression: seluruh pemeriksaan PASS
- Performance Stage 4: 39/39
- Reimbursement print Stage 3: 13/13

Pemeriksaan sintaks: 7 inline JavaScript blocks dan Service Worker lolos `node --check`. Marker HTML/Service Worker cocok.

**Catatan verifikasi:** tes ini statis/lokal. Migration SQL belum diterapkan atau dijalankan pada Supabase staging/produksi. Perlu uji runtime dengan akun Admin, Hybrid/non-Hybrid, dan data absensi uji sebelum rilis produksi.
