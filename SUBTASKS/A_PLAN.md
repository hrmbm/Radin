# PLAN — Paket A: Area Surabaya & Sekitarnya

## Tujuan
Menambahkan **Surabaya & Sekitarnya** sebagai pilihan Pengaturan Lokasi untuk karyawan kantor Surabaya yang Clock In/Clock Out dari luar radius kantor, tanpa menambah kode kehadiran.

## Cakupan
- Pilihan area normal Clock In dan Clock Out.
- SBY sebagai marker internal yang diubah server menjadi label display `Surabaya & Sekitarnya`.
- Status kehadiran normal tetap `H`; Piket di SBY tetap `P`; sakit tetap `SDR`.
- SBY tidak menjadi opsi Standby/dinas luar dan tidak membuat varian `SDR-SBY`, `PSBY`, atau `DLSBY`.
- Ringkasan absensi, kolom Pengaturan Lokasi, ekspor, dan perhitungan insentif.

## Batas keamanan
Koordinat GPS dan jarak dari lokasi kantor aktif tetap dihitung server. Pemilihan SBY tidak memalsukan koordinat atau menandai pengguna berada di dalam geofence. Persetujuan tetap mengikuti jalur existing.
