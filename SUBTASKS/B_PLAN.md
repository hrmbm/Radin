# PLAN — Paket B: Hak Presensi Pribadi Admin

## Tujuan
Mempertahankan akses baca-saja Admin untuk fungsi administrasi, tetapi mengizinkan akun Admin melakukan Clock In dan Clock Out miliknya sendiri.

## Cakupan
- Menghapus blokir role Admin pada entry point presensi pribadi.
- Mengizinkan `simpanAbsensi` dan RPC `submit_attendance_with_photo` melewati guard frontend read-only.
- Mengganti wrapper database `submit_attendance_with_photo` agar mengautentikasi sesi lalu meneruskan ke internal validated function.

## Yang tidak berubah
- Admin tetap tidak dapat mengubah data karyawan, pengaturan, time off, atau persetujuan.
- Pemeriksaan sesi, GPS/geofence, akurasi, Face ID, validasi trigger, serta alur persetujuan tetap dijalankan.
