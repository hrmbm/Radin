# ReHolz HRIS — Rilis v14.9.0

## Isi paket
- `index.html`: dashboard 3 panel, akses Approver, refresh data bertahap, cache foto, halaman Manajemen Data / Penyesuaian Data, dan kolom `Ket` pada Laporan Absensi.
- `sw.js`: Service Worker v77, cocok dengan penanda rilis HTML v14.9.0.
- `supabase/migrations/20261119_admin_data_management.sql`: dependensi pengelolaan data dari rilis sebelumnya (hapus Time Off/Reimbursement dan penanganan lampiran).
- `supabase/migrations/20261119_vnext_approver_dashboard_attendance.sql`: fungsi akses Approver, laporan presensi, dashboard, konsistensi persetujuan Clock Out, dan audit Penyesuaian Data.
- `supabase/functions/api/index.ts` dan `edge_functions/functions/api/index.ts`: source Edge Function API yang disertakan dalam proyek.
- `assets/`: aset logo yang dibutuhkan aplikasi.

## Urutan penerapan
1. Pastikan direktori ini terhubung ke Supabase project yang benar.
2. Terapkan migration sesuai urutan nama file. Jika migration `20261119_admin_data_management.sql` sudah pernah berhasil diterapkan pada project tersebut, jangan jalankan ulang secara manual; biarkan Supabase CLI mencocokkan riwayat migration.
3. Jalankan `supabase db push` untuk menerapkan migration yang belum tercatat.
4. Deploy Edge Function `api` bila source API pada project Supabase belum sama dengan file yang disertakan: `supabase functions deploy api`.
5. Publikasikan `index.html`, `sw.js`, dan seluruh folder `assets/` secara bersamaan. Jangan mengunggah HTML tanpa Service Worker v77.
6. Setelah rilis, buka aplikasi dan lakukan Refresh Data. Untuk klien yang masih menyimpan worker lama, tutup tab aplikasi lalu buka kembali.

> **Status penerapan:** paket dan file SQL disiapkan secara lokal. Migration belum dijalankan pada database Supabase aktif dan Edge Function belum dideploy dari sesi ini.

## Ringkasan perilaku

### Refresh Data dan Reboot
- Refresh Data memperbarui konteks profil/lokasi, antrean persetujuan Approver, data tim dan pengajuan, referensi Time Off, lalu pemanasan cache data/foto.
- Label tombol menampilkan tahap sinkronisasi. Cache dashboard utama dan cache tiga panel dashboard dipaksa kedaluwarsa setelah refresh.
- Cache foto hanya mengunduh foto yang belum tersedia/berubah sesuai versi foto; data cache lama yang masih valid tidak sengaja dikosongkan ketika pemuatan gagal.
- Reboot membersihkan penyimpanan lokal milik aplikasi, database IndexedDB/cache foto, Cache Storage ReHolz, serta registrasi Service Worker dalam scope aplikasi, kemudian memuat ulang aplikasi.
- Browser tidak mengizinkan halaman menghapus HTTP cache global Chrome atau data situs lain pada origin yang sama.

### Akses Approver
- Karyawan aktif yang mempunyai bawahan langsung aktif melalui `approval_line_id` memperoleh akses Approver secara otomatis.
- Prioritas role tetap SUPERADMIN, ADMIN, APPROVER, lalu KARYAWAN; identitas dasar akun Karyawan tidak diganti menjadi role baru yang dapat mengganggu alur lama.
- Hak Approver mencakup Dashboard, antrean Menunggu Persetujuan, pengajuan Time Off sendiri, Rekap Absensi, Rekap Time Off, Persebaran Karyawan, dan Laporan Absensi untuk bawahan langsung.
- Pemeriksaan backend membatasi data tim pada bawahan langsung, tidak meluas ke bawahan dari bawahan atau tim manager lain.

### Dashboard
- Tiga panel menampilkan Pengeluaran Tim Hybrid, Insentif Dinas Luar, dan Karyawan Absen Hari Ini.
- Reimbursement hanya menghitung status yang sudah disetujui, dengan periode payroll tanggal 6 sampai tanggal 5.
- Insentif menggunakan fungsi kalkulasi insentif yang sudah ada; perhitungan insentif tidak diganti.
- Daftar absen memakai karyawan aktif yang belum Clock In, menghormati tanggal mulai kerja, zona waktu Asia/Jakarta, dan scope role. Kode Time Off kosong tetap ditampilkan sebagai kosong.

### Presensi dan laporan
- Status laporan terlambat dimulai pada `scheduled_check_in + 1 minute`: jadwal 08:00 berarti 08:00:59 masih Ontime dan 08:01:00 mulai Late.
- WFA dan HYBRID dikenali dari `job_code`, bukan lokasi.
- DL/Standby yang ditandai `DL…` / `SDL…` dikecualikan dari Late dan Clock Out Lebih Awal. Untuk transaksi Dinas Luar hari kerja yang tidak menyimpan marker `RHATT`, backend memakai kombinasi `outside_location` dan area pilihan yang tervalidasi (`Area 1`–`Area 4` atau `Area lainnya`). `Surabaya & Sekitarnya` / Area Sekitar tidak termasuk pengecualian Dinas Luar.
- Ketentuan lima menit yang dipakai mesin insentif/uang makan tetap dipertahankan; ambang satu menit diterapkan di laporan dan rekap presensi, bukan mengubah snapshot toleransi mesin insentif.
- Laporan Absensi menyertakan seluruh karyawan aktif untuk hari setelah `join_date`, walaupun `contract_end_date` sudah lewat; kolom paling kanan `Ket` menampilkan `-`, `Ontime`, atau `Late`.
- Clock Out yang Clock In-nya memerlukan approval ikut memerlukan approval walaupun Clock Out dilakukan di dalam radius kantor. Clock Out tanpa Clock In tetap diizinkan dan tetap melalui validasi GPS/Face ID/catatan yang relevan.

### Penyesuaian Data
- Menu berada di Manajemen Data dan hanya ditampilkan kepada SUPERADMIN; RPC juga memvalidasi role pada server.
- Dapat menambah presensi historis atau memperbaiki jam Clock In/Clock Out dengan alasan wajib.
- Audit menyimpan actor, alasan, aksi, data sebelum, data sesudah, dan waktu perubahan.
- Penyesuaian tidak membuat data GPS atau Face ID palsu; laporan/rekap membaca jam presensi hasil penyesuaian.

## Pemeriksaan lokal yang dilakukan
- Seluruh 7 blok JavaScript inline pada `index.html` lolos `node --check`.
- `sw.js` lolos `node --check`.
- Salinan Edge Function dalam dua lokasi identik.
- Pemeriksaan struktur source dilakukan pada fungsi SQL yang relevan: fungsi rekap/laporan, helper scope Approver, submit presensi, RPC dashboard, dan RPC audit penyesuaian.
- Pemeriksaan runtime pada database, approval end-to-end, GPS/Face ID, dan tampilan browser belum dapat dilakukan dari sesi ini karena tidak ada koneksi ke project Supabase atau browser aplikasi yang sedang berjalan.

## Skenario uji setelah deploy
1. Jadwal 08:00: uji Clock In 08:00:59 (Ontime) dan 08:01:00 (Late).
2. Uji karyawan WFA, HYBRID, Dinas Luar Area 1–4/Area lainnya, Standby, serta Area Sekitar untuk memastikan pengecualian tidak salah diterapkan.
3. Uji Approver hanya melihat bawahan langsung di masing-masing laporan dan hanya antrean persetujuan yang menjadi kewenangannya.
4. Uji Clock In pending lalu Clock Out di dalam radius; Clock Out harus ikut pending. Uji Clock Out tanpa Clock In; transaksi tetap dapat dikirim.
5. Uji Laporan Absensi untuk karyawan aktif dengan `contract_end_date` lampau dan karyawan sebelum `join_date`.
6. Uji Penyesuaian Data sebagai SUPERADMIN, lalu verifikasi audit before/after/reason/actor dan hasil Rekap/Laporan Absensi.
7. Uji Refresh Data dan Reboot pada akun Karyawan serta Approver; periksa cache foto sesuai scope role.
