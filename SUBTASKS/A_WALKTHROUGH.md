# WALKTHROUGH — Paket A

1. UI menampilkan nama lengkap **Surabaya & Sekitarnya** pada pilihan area normal Clock In/Clock Out dan Piket.
2. Frontend memakai marker internal `RHAREA=SBY`; marker ini bukan kode kehadiran dan dibersihkan oleh trigger.
3. `hris_validate_outside_location_attendance` tetap menghitung `distance_m` terhadap radius kantor aktif. Jika berada di luar radius, `outside_location` tetap benar dan `NEW.area` disimpan sebagai `Surabaya & Sekitarnya`.
4. Ringkasan absensi mengeluarkan `H` untuk kehadiran normal SBY. Marker Piket server mengeluarkan `P`; sakit tetap melalui kode Time Off `SDR` tanpa area dinas luar.
5. Trigger Piket mengenali SBY sebagai office-equivalent sehingga kode tetap `P` dan perhitungan jam Piket mengikuti aturan kantor. Standby menolak SBY karena bukan kategori dinas luar.
6. Kolom Pengaturan Lokasi dan ekspor attendance monitoring memakai helper label yang sama. Perhitungan insentif memperlakukan SBY sebagai in-office untuk komponen kantor dan bukan tarif Dinas Luar.

## File database
`migrations/001_area_surabaya_sekitarnya.sql` memperbarui constraint area, trigger area, trigger Piket/Standby, fungsi ringkasan absensi, dan kalkulasi insentif.
