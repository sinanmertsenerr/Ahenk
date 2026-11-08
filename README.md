# Ahenk

**English** · [Türkçe](#türkçe)

Ahenk is a macOS app that lets the desktop live with the music: an edge
light around every screen that moves with the beat in the album's colors, a
glass player on the desktop, synced lyrics, a live wallpaper from the song's
motion artwork or video, and a Dock icon that becomes the album cover. It
follows the music apps on your Mac, music sites in the browser, any app that
shows what is playing, and your own files.

> Status: in development. The foundation is in place: settings, menu bar,
> Settings window, demo mode. The features arrive step by step; see
> [docs/PROGRESS.md](docs/PROGRESS.md).

### Requirements

macOS 14.2 or later, Xcode 16 or later (Swift 6).

### Build and run

```sh
./Scripts/make-app.sh              # build and sign dist/Ahenk.app
./Scripts/run-demo.sh              # launch with invented songs (no music needed)
./Scripts/test.sh                  # lint and unit tests
./Scripts/smoke.sh                 # headless check of every subsystem
./Scripts/install.sh               # install to /Applications
```

Ahenk asks for two permissions when the features that need them arrive:
system audio (so the light hears the music; nothing is recorded, never the
microphone) and Automation (to read the song and cover from your music apps).

### License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

## Türkçe

Ahenk, masaüstünü müzikle birlikte yaşatan bir macOS uygulamasıdır: her
ekranın kenarında albümün renkleriyle ritme göre hareket eden bir ışık,
masaüstünde cam bir oynatıcı, eşzamanlı şarkı sözleri, şarkının hareketli
kapağından ya da videosundan canlı duvar kâğıdı ve albüm kapağına dönüşen bir
Dock simgesi. Mac'inizdeki müzik uygulamalarını, tarayıcıdaki müzik
sitelerini, çalan şarkıyı gösteren her uygulamayı ve kendi dosyalarınızı izler.

> Durum: geliştiriliyor. Temel hazır: ayarlar, menü çubuğu, Ayarlar penceresi,
> demo modu. Özellikler adım adım geliyor; ayrıntılar
> [docs/PROGRESS.md](docs/PROGRESS.md) dosyasında.

### Gereksinimler

macOS 14.2 ya da sonrası, Xcode 16 ya da sonrası (Swift 6).

### Derleme ve çalıştırma

```sh
./Scripts/make-app.sh              # dist/Ahenk.app paketini derler ve imzalar
./Scripts/run-demo.sh              # kurgusal şarkılarla açar (müzik gerekmez)
./Scripts/test.sh                  # denetimler ve birim testleri
./Scripts/smoke.sh                 # tüm alt sistemleri arayüzsüz dener
./Scripts/install.sh               # /Applications klasörüne kurar
```

Ahenk, bu izinleri kullanan özellikler geldiğinde iki izin ister: sistem sesi
(ışık müziği duysun diye; hiçbir şey kaydedilmez, mikrofon asla kullanılmaz)
ve Otomasyon (müzik uygulamalarınızdan şarkıyı ve kapağı okumak için).

### Lisans

MIT. Ayrıntılar [LICENSE](LICENSE) ve
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) dosyalarında.
