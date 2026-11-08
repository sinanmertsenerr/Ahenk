# Ahenk

**English** · [Türkçe](#türkçe)

Ahenk is a macOS app that lets the desktop live with the music: an edge
light around every screen that moves with the beat in the album's colors, a
glass player on the desktop, synced lyrics, a live wallpaper from the song's
motion artwork or video, and a Dock icon that becomes the album cover. It
follows the music apps on your Mac, music sites in the browser, any app that
shows what is playing, and your own files.

> Status: in development. In place: settings, menu bar, Settings window,
> demo mode, the now-playing hub that follows Apple Music, Spotify, browsers
> and any app that shows what is playing, the analysis that hears the beat,
> and the edge light around every screen in 22 styles. The features arrive
> step by step; see [docs/PROGRESS.md](docs/PROGRESS.md).

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

Ahenk uses two permissions: system audio (so the light hears the music;
nothing is recorded, never the microphone) and Automation (to read the song,
cover, shuffle, repeat and favorites from Apple Music and Spotify and send
the commands you choose). macOS asks for system audio only when you press
**Allow Listening…** in Settings › Sound or in the menu bar menu; Ahenk then
listens to the app that plays your music, only while music plays, and
analyzes the sound in memory. If you said no, turn Ahenk on in System
Settings › Privacy & Security › Screen & System Audio Recording › System
Audio Recording Only. Without Automation, Ahenk still shows what plays;
it asks only when you press **Allow Access…** in Settings › Sources. To find
covers, Ahenk sends a song's title and artist to Apple's public catalog and
asks Spotify's public page for a track's cover; nothing else leaves your Mac.

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

> Durum: geliştiriliyor. Hazır olanlar: ayarlar, menü çubuğu, Ayarlar
> penceresi, demo modu, Apple Music'i, Spotify'ı, tarayıcıları ve çalan
> şarkıyı gösteren her uygulamayı izleyen "şu an çalıyor" merkezi, ritmi
> duyan ses analizi ve her ekranın kenarında 22 farklı stille parlayan kenar
> ışığı. Özellikler adım adım geliyor; ayrıntılar
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

Ahenk iki izin kullanır: sistem sesi (ışık müziği duysun diye; hiçbir şey
kaydedilmez, mikrofon asla kullanılmaz) ve Otomasyon (Apple Music ile
Spotify'dan şarkıyı, kapağı, karıştırma, tekrar ve favori bilgisini okumak ve
seçtiğiniz komutları göndermek için). macOS sistem sesi iznini yalnızca
Ayarlar › Ses'teki ya da menü çubuğu menüsündeki **Dinlemeye İzin Ver…**
düğmesine bastığınızda sorar; Ahenk bundan sonra yalnızca müzik çalarken,
müziğinizi çalan uygulamayı dinler ve sesi bellekte analiz eder. Hayır
dediyseniz Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi
Kaydı › Yalnızca Sistem Sesi Kaydı bölümünden Ahenk'i açın. Otomasyon izni
olmadan da neyin çaldığını gösterir; izni yalnızca Ayarlar › Kaynaklar'daki
**Erişime İzin Ver…** düğmesine bastığınızda ister. Kapakları bulmak için
şarkının adını ve sanatçısını Apple'ın herkese açık kataloğuna gönderir, bir
parçanın kapağını Spotify'ın herkese açık sayfasından ister; Mac'inizden başka
hiçbir şey çıkmaz.

### Lisans

MIT. Ayrıntılar [LICENSE](LICENSE) ve
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) dosyalarında.
