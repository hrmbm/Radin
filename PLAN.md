# PLAN — HRIS Reimbursement Desktop UI v72

## Tujuan
Merapikan tampilan **Reimbursement → Pengajuan Reimbursement** pada desktop agar terasa sebagai adaptasi desktop yang wajar dari form mobile, bukan form mobile yang diperlebar.

## Prinsip yang dipertahankan
- Satu node `#reimbursementApp` untuk mobile dan desktop; tidak membuat form atau ID baru yang terpisah.
- Field, kategori Entertain/Transport, perhitungan saldo, validasi, upload lampiran, RPC pengajuan, dan riwayat tetap memakai fungsi yang sama.
- Hak akses Hybrid/non-Hybrid/Admin serta menu desktop tidak diubah.
- Tidak ada perubahan database, RPC, RLS, Edge Function, atau aturan persetujuan.

## Rencana UI
1. Ringkasan saldo tersedia, disetujui, menunggu, dan periode dirapikan menjadi satu baris informasi.
2. Kategori Entertain dan Transport ditampilkan sebagai pilihan tab yang jelas, termasuk saldo tersedia per kategori.
3. Pada desktop lebar (>=1200 px), area kerja memakai dua panel: form di kiri, riwayat di kanan.
4. Pada desktop lebih sempit (1024–1199 px) dan tablet, form serta riwayat ditumpuk agar lebar input tetap terbaca.
5. Pada mobile, susunan tetap satu kolom dan semua kontrol tetap mudah disentuh.
6. Over Budget tetap menampilkan label tombol, kewajiban catatan, dan petunjuk yang jelas.
7. Riwayat dibuat lebih mudah dipindai serta tombolnya dapat dioperasikan dengan keyboard.

## Pengujian
- Render Chromium pada 1440, 1280, 1024, 768, 390, dan 360 px.
- Periksa overflow horizontal, susunan panel, seluruh input, kategori, riwayat, serta tampilan Over Budget.
- Jalankan simulasi validasi form, file size/type, upload bukti, dan payload RPC.
- Jalankan semua regresi Tahap 2–4 dan pemeriksaan sintaks JavaScript/Service Worker.
