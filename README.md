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
> the edge light around every screen in 22 styles, and the glass desktop
> player: a big clock, Continue Playing, the artist's albums as a cover flow,
> search, the player bar and a play queue; synced lyrics beside the album
> cover in eight styles (Fisheye, Spread, Karaoke, Typewriter, Neon, Echo,
> Glitch, Cinema), with a countdown in instrumental parts, other versions,
> search and timing; the browser extension for YouTube Music, YouTube,
> Spotify, SoundCloud, Amazon Music, Deezer and TIDAL; and the live wallpaper:
> the album's motion artwork, the song's music video or another by the
> artist, or the cover itself, melting in over your wallpaper while the song
> plays, chosen with the dots above the player; and the desktop extras: the
> Dock icon as the cover with a ring that beats along, Clear Desk, stickers
> cut out of your photos, and your own song files played by Ahenk itself. The
> features arrive step by step; see [docs/PROGRESS.md](docs/PROGRESS.md).

### Requirements

macOS 14.2 or later, Xcode 16 or later (Swift 6).

### Build and run

```sh
./Scripts/make-app.sh              # build and sign dist/Ahenk.app
./Scripts/run-demo.sh              # launch with invented songs (no music needed)
./Scripts/test.sh                  # lint and unit tests
./Scripts/smoke.sh                 # headless check of every subsystem
./Scripts/bridge-e2e.sh            # the browser extension end to end in a headless test browser
./Scripts/install.sh               # install to /Applications
```

### Browser extension

Music sites in the browser (YouTube Music, YouTube, Spotify, SoundCloud,
Amazon Music, Deezer and TIDAL) report exactly what plays through the Ahenk
browser extension, and the desktop player plays your picks, playlists and
queue there. Install it once; the menu bar menu's **Install Browser
Extension…** shows its folders in Finder (`make-app.sh` puts them into
`Ahenk.app/Contents/Resources/Extension`):

- **Chrome, Edge, Brave, Arc, Opera, Vivaldi:** open the extensions page
  (`chrome://extensions`), turn on Developer mode, click **Load unpacked** and
  choose the `Chromium` folder. If you move Ahenk, load it again.
- **Search:** the puzzle button › **Load Unpacked…** › the `Chromium` folder.
- **Firefox:** `about:debugging` › This Firefox › **Load Temporary Add-on…** ›
  `manifest.json` in the `Firefox` folder. Firefox forgets it when it quits.

The extension's button shows whether it is connected; Settings › Sources
lists the connected browsers and their music tabs.

Ahenk uses two permissions: system audio (so the light hears the music;
nothing is recorded, never the microphone) and Automation (to read the song,
cover, shuffle, repeat and favorites from Apple Music and Spotify and send
the commands you choose). macOS asks for system audio only when you press
**Allow Listening…** in Settings › Sound or in the menu bar menu; Ahenk then
listens to the app that plays your music, only while music plays, and
analyzes the sound in memory. If you said no, turn Ahenk on in System
Settings › Privacy & Security › Screen & System Audio Recording › System
Audio Recording Only. Without Automation, Ahenk still shows what plays;
it asks only when you press **Allow Access…** in Settings › Sources (or, the
first time, when you pick a song in the desktop player to play there). To
find covers, albums and search results, Ahenk sends a song's title and artist,
or what you type into the search, to Apple's public catalog and asks
Spotify's public page for a track's cover; to play a pick in Spotify, it asks
ListenBrainz (MetaBrainz) for the song's Spotify ID by its title, artist and
album. While lyrics are on, it sends the playing song's title, artist, album
and length to LRCLIB, Musixmatch and NetEase to find its lyrics (each can be
turned off in Settings › Lyrics) and keeps what it finds on your Mac. The
browser extension talks only to Ahenk on this Mac (127.0.0.1, which accepts
nothing but the extension): it reads what the music site's own page shows
(the song, its position, and the site's own synced lyrics when its lyrics view
loads them) and carries out your commands there. Nothing else leaves your Mac.

### Live wallpaper

While a song plays, a layer just above your desktop picture shows the album's
motion artwork (from Apple's catalog), the song's music video or another one
by the same artist (YouTube's embedded player, privacy-enhanced and muted),
or the cover, blurred and slowly moving; your own wallpaper setting is never
changed. Videos stream while they show and are never downloaded. The dots
above the player choose among them; Settings › Live Wallpaper adds your own
video files and addresses. It pauses while windows cover the desktop and
shows only the cover in Low Power Mode.

### Desktop extras

- **Dock icon.** While a song plays, Ahenk's Dock icon is its cover with a
  ring in the cover's colors that swells on every beat and shows the song's
  progress; it stays still while paused and Ahenk's own icon comes back when
  nothing plays. The ring changes a few times a second (fewer in Optimized
  Mode and on battery, not at all in Low Power Mode). Settings › Desktop
  Player › Dock, or **Dock Art** in the menu bar menu.
- **Clear Desk.** The moon button beside the search field (or **Clear Desk**
  in the menu bar menu) hides every other app, so only the desktop, the
  widgets and the wallpaper remain; another click shows exactly the apps it
  hid. Apps are only hidden and shown, never quit; apps you had hidden
  yourself, full-screen apps and menu bar extras are left alone, and whatever
  Ahenk hid comes back when it quits.
- **Stickers.** Pick any photo (Settings › Stickers, **Add Sticker…** in the
  player's menu, or drop it on a widget) and Ahenk cuts its subject out on
  your Mac with Vision; nothing is uploaded. Drag a sticker to move it, its
  corner to resize it and the handle above it to turn it; right-click to stick
  it to the clock, the list or the player (it then moves with it) or to
  remove it.
- **Your own songs.** Drop a folder of songs (or song files) on Continue
  Playing, or choose **Add Folder…** in the list's menu, and Ahenk plays them
  itself as the source "Files on This Mac": titles and covers come from the
  files, and the light, the lyrics, the wallpaper, the queue, shuffle and
  repeat work as with any other source. The light needs no permission for these songs. The
  folders are remembered in Settings › Sources; the files are never copied.

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
> duyan ses analizi, her ekranın kenarında 22 farklı stille parlayan kenar
> ışığı ve masaüstündeki cam oynatıcı: büyük bir saat, Çalmaya Devam Et
> listesi, sanatçının albümlerini dizen kapak akışı, arama, oynatıcı çubuğu ve
> çalma sırası; albüm kapağının yanında sekiz stilde (Balıkgözü, Yayılma,
> Karaoke, Daktilo, Neon, Yankı, Bozulma, Sinema) eşzamanlı şarkı sözleri,
> enstrümantal bölümlerde geri sayım, sözlerin diğer sürümleri, söz arama ve
> zamanlama ayarı; YouTube Music, YouTube, Spotify, SoundCloud, Amazon Music,
> Deezer ve TIDAL için tarayıcı eklentisi; ve canlı duvar kâğıdı: şarkı
> çalarken albümün hareketli kapağı, şarkının müzik videosu ya da sanatçının
> başka bir videosu veya kapağın kendisi duvar kâğıdınızın üzerine yavaşça
> gelir; hangisinin gösterileceği oynatıcının üstündeki noktalarla seçilir;
> ve masaüstü ekleri: ritimle atan bir halkayla albüm kapağına dönüşen Dock
> simgesi, Masayı Temizle, fotoğraflarınızdan kesilen çıkartmalar ve Ahenk'in
> kendisinin çaldığı şarkı dosyalarınız. Özellikler adım adım geliyor;
> ayrıntılar [docs/PROGRESS.md](docs/PROGRESS.md) dosyasında.

### Gereksinimler

macOS 14.2 ya da sonrası, Xcode 16 ya da sonrası (Swift 6).

### Derleme ve çalıştırma

```sh
./Scripts/make-app.sh              # dist/Ahenk.app paketini derler ve imzalar
./Scripts/run-demo.sh              # kurgusal şarkılarla açar (müzik gerekmez)
./Scripts/test.sh                  # denetimler ve birim testleri
./Scripts/smoke.sh                 # tüm alt sistemleri arayüzsüz dener
./Scripts/bridge-e2e.sh            # tarayıcı eklentisini arayüzsüz bir test tarayıcısında baştan sona dener
./Scripts/install.sh               # /Applications klasörüne kurar
```

### Tarayıcı eklentisi

Tarayıcıdaki müzik siteleri (YouTube Music, YouTube, Spotify, SoundCloud,
Amazon Music, Deezer ve TIDAL), Ahenk tarayıcı eklentisi sayesinde neyin
çaldığını tam olarak bildirir; masaüstü oynatıcı da seçtiğiniz şarkıları,
çalma listelerini ve çalma sırasını orada çalar. Eklentiyi bir kez kurmanız
yeterli; menü çubuğu menüsündeki **Tarayıcı Eklentisini Kur…** komutu
klasörlerini Finder'da gösterir (`make-app.sh` bu klasörleri
`Ahenk.app/Contents/Resources/Extension` içine koyar):

- **Chrome, Edge, Brave, Arc, Opera, Vivaldi:** uzantılar sayfasını açın
  (`chrome://extensions`), Geliştirici modunu açın, **Paketlenmemiş öğe
  yükle** düğmesine tıklayın ve `Chromium` klasörünü seçin. Ahenk'i başka bir
  yere taşırsanız klasörü yeniden yükleyin.
- **Search:** yapboz düğmesi › **Load Unpacked…** › `Chromium` klasörü.
- **Firefox:** `about:debugging` › Bu Firefox › **Geçici Eklenti Yükle…** ›
  `Firefox` klasöründeki `manifest.json`. Firefox kapanınca eklentiyi unutur.

Eklentinin düğmesi bağlı olup olmadığını gösterir; Ayarlar › Kaynaklar bağlı
tarayıcıları ve müzik sekmelerini listeler.

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
**Erişime İzin Ver…** düğmesine bastığınızda (ya da masaüstü oynatıcıda o
uygulamada çalması için ilk kez bir şarkı seçtiğinizde) ister. Kapakları,
albümleri ve arama sonuçlarını bulmak için şarkının adını ve sanatçısını ya da
aramaya yazdıklarınızı Apple'ın herkese açık kataloğuna gönderir, bir parçanın
kapağını Spotify'ın herkese açık sayfasından ister; seçtiğiniz bir şarkıyı
Spotify'da çalmak için şarkının adını, sanatçısını ve albümünü ListenBrainz'e
(MetaBrainz) göndererek Spotify kimliğini bulur. Şarkı sözleri açıkken, çalan
şarkının sözlerini bulmak için adını, sanatçısını, albümünü ve süresini
LRCLIB, Musixmatch ve NetEase hizmetlerine gönderir (her biri Ayarlar › Şarkı
Sözleri'nden kapatılabilir) ve bulduklarını Mac'inizde saklar. Tarayıcı
eklentisi yalnızca bu Mac'teki Ahenk'le konuşur (127.0.0.1; Ahenk eklentiden
başkasını kabul etmez): müzik sitesinin kendi sayfasında görünenleri (şarkıyı,
konumunu ve sitenin sözler görünümü yüklediğinde sitenin kendi eşzamanlı
sözlerini) okur ve komutlarınızı orada yerine getirir. Mac'inizden başka hiçbir
şey çıkmaz.

### Canlı duvar kâğıdı

Şarkı çalarken masaüstü resminizin hemen üstündeki bir katman albümün
hareketli kapağını (Apple'ın kataloğundan), şarkının müzik videosunu ya da
aynı sanatçının başka bir videosunu (YouTube'un gizlilik odaklı, sessiz
yerleştirilmiş oynatıcısında) veya bulanık ve yavaşça hareket eden kapağı
gösterir; kendi duvar kâğıdı ayarınız hiç değişmez. Videolar gösterildikleri
sırada akış olarak oynatılır, asla indirilmez. Oynatıcının üstündeki noktalar
bunlar arasında seçim yapar; Ayarlar › Canlı Duvar Kâğıdı'ndan kendi video
dosyalarınızı ve adreslerinizi ekleyebilirsiniz. Pencereler masaüstünü
örttüğünde duraklar, Düşük Güç Modunda yalnızca kapağı gösterir.

### Masaüstü ekleri

- **Dock simgesi.** Şarkı çalarken Ahenk'in Dock simgesi şarkının kapağına
  dönüşür; çevresindeki halka kapağın renklerini taşır, her vuruşta genişler
  ve şarkının ne kadarının çalındığını gösterir. Şarkı duraklatıldığında halka
  durur, hiçbir şey çalmadığında Ahenk'in kendi simgesi geri gelir. Halka
  saniyede birkaç kez değişir (Optimize Edilmiş Modda ve pilde daha seyrek,
  Düşük Güç Modunda hiç). Ayarlar › Masaüstü Oynatıcı › Dock bölümünden ya da
  menü çubuğu menüsündeki **Dock'ta Albüm Kapağı** seçeneğinden açılıp
  kapatılır.
- **Masayı Temizle.** Arama alanının yanındaki ay düğmesi (ya da menü çubuğu
  menüsündeki **Masayı Temizle**) diğer bütün uygulamaları gizler; geriye
  masaüstü, araçlar ve duvar kâğıdı kalır. Bir kez daha tıkladığınızda yalnızca
  Ahenk'in gizlediği uygulamalar geri gelir. Uygulamalar yalnızca gizlenir ve
  gösterilir, hiçbiri kapatılmaz; sizin gizlediğiniz uygulamalara, tam ekran
  uygulamalara ve menü çubuğu araçlarına dokunulmaz. Ahenk kapanırken
  gizlediği her şeyi geri getirir.
- **Çıkartmalar.** Herhangi bir fotoğrafı seçin (Ayarlar › Çıkartmalar,
  oynatıcı menüsündeki **Çıkartma Ekle…** ya da fotoğrafı bir aracın üstüne
  bırakmak); Ahenk fotoğraftaki özneyi Vision ile Mac'inizde arka plandan
  ayırır, hiçbir şey yüklenmez. Çıkartmayı taşımak için kendisini, boyutunu
  değiştirmek için köşesini, döndürmek için üstündeki tutamacı sürükleyin;
  saate, listeye ya da oynatıcıya yapıştırmak (çıkartma artık onunla birlikte
  taşınır) veya silmek için sağ tıklayın.
- **Kendi şarkılarınız.** Bir şarkı klasörünü (ya da şarkı dosyalarını) Çalmaya
  Devam Et listesine bırakın veya listenin menüsünden **Klasör Ekle…**
  komutunu seçin; Ahenk bu şarkıları "Bu Mac'teki Dosyalar" kaynağı olarak
  kendisi çalar.
  Şarkı adları ve kapaklar dosyalardan okunur; ışık, şarkı sözleri, duvar
  kâğıdı, çalma sırası, karıştırma ve tekrar diğer kaynaklardaki gibi çalışır.
  Bu şarkılarda ışık için izin gerekmez. Klasörler Ayarlar › Kaynaklar'da
  durur; dosyalar hiçbir yere kopyalanmaz.

### Lisans

MIT. Ayrıntılar [LICENSE](LICENSE) ve
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) dosyalarında.
