# CHECKPOINT — HRIS Reimbursement Desktop UI v72

## Status
**Perbaikan tampilan selesai pada source dan pengujian UI lokal.** Paket ini adalah revisi visual untuk Paket C, bukan perubahan alur backend.

## Checkpoint visual
- [x] Desktop 1440 px: dua panel; form kiri, riwayat kanan.
- [x] Desktop 1280 px: dua panel tetap seimbang.
- [x] Desktop 1024 px: panel ditumpuk agar input tidak sempit.
- [x] Tablet 768 px: satu kolom.
- [x] Mobile 390 dan 360 px: satu kolom tanpa overflow horizontal.
- [x] Seluruh field tanggal, nominal, catatan, bukti, dan tombol Ajukan tersedia.
- [x] Saldo, kategori, status riwayat, dan Over Budget memiliki hierarchy visual yang jelas.
- [x] Riwayat pengajuan menggunakan kontrol tombol yang keyboard-operable.

## Checkpoint fungsi
- [x] Pilihan Entertain/Transport tetap memperbarui state dan saldo kategori.
- [x] Nominal Over Budget mengubah tombol dan mewajibkan catatan.
- [x] Pengajuan tanpa catatan Over Budget diblok sebelum upload.
- [x] Upload bukti valid dan RPC pengajuan existing dipanggil dengan payload yang sama.
- [x] File di atas 8 MB ditolak sebelum upload.
- [x] Jenis file di luar JPG/PNG/WEBP/PDF ditolak sebelum upload.
- [x] Riwayat memanggil handler detail yang sama.

## Hasil tes
- Tes UI Chromium: **40/40 lulus**.
- Regresi Tahap 2–4: **9/9 suite, 223 pemeriksaan lulus**.
- Sintaks inline JavaScript: **7/7 blok lulus**.
- HTML release marker dan Service Worker v72: cocok.
- Arsip ZIP: integritas diverifikasi setelah build final.

## Batas verifikasi
- Endpoint upload dan RPC dimock dalam tes browser; tidak ada data yang dikirim ke Supabase aktif.
- Belum diuji memakai akun Hybrid nyata, signed-in session, atau deployment staging/produksi.
- Tidak ada perubahan schema/database, RPC, RLS, maupun aturan akses.

## Checkpoint akhir
Paket dapat diserahkan untuk ditinjau. Sesudah paket ini dikirim, pekerjaan dihentikan dan menunggu instruksi pengguna.
