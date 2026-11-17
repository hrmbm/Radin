# HRIS Reholz — Reimbursement Desktop UI v72

Paket lengkap hasil revisi tampilan **Reimbursement → Pengajuan Reimbursement** desktop, dibangun di atas snapshot v71.

## File utama
- `index.html` — aplikasi.
- `sw.js` — Service Worker v72.
- `assets/` — logo aplikasi.
- `migrations/` — migrasi Tahap 4 sebelumnya (tidak diubah oleh revisi UI ini).
- `tests/` — seluruh regresi Tahap 2–4 dan tes UI baru.
- `previews/` — screenshot desktop/tablet/mobile.

## Perubahan v72
Mengadaptasi form existing menjadi komposisi desktop yang lebih rapi: ringkasan saldo, tab kategori, panel form dan riwayat; responsive untuk desktop, tablet, dan mobile. Field, validasi, upload bukti, RPC, akses Hybrid, dan aturan backend tetap sama.

## Dokumen paket
- `PLAN.md`
- `WALKTHROUGH.md`
- `CHECKPOINT.md`
- `TEST_RESULTS.md`
- `RELEASE_NOTES.md`

## Tes
Regresi Node:
`node --test tests/*.test.cjs tests-stage4-additions.test.cjs`

Tes UI Chromium:
`python tests/ui/test_reimbursement_ui.py`

Tes UI memerlukan Python Playwright dan Chromium yang tersedia di lingkungan pengujian. `tests/ui/fixture.html` adalah fixture lokal; endpoint upload dan RPC dimock.

## Deployment
Deploy `index.html`, `sw.js`, dan folder `assets/` sebagai satu release. Pertahankan Service Worker berada pada scope yang sama dengan `index.html`. Lakukan smoke test dengan akun Hybrid pada staging sebelum produksi; jangan menguji dengan pengajuan yang mengubah data produksi.

## Batas
Paket ini belum di-deploy dan belum diuji dengan akun Hybrid/Supabase aktif.
