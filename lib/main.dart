import 'package:flutter/material.dart';
// import 'package:file_picker/file_picker.dart'; // Otomatik yükleme için gerek yok
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:csv/csv.dart';

// *** CSV PARSE İÇİN pubspec.yaml dosyasına 'csv: ^5.0.0' ekleyin. ***
// record ve audioplayers paketleri de ekli olmalı.

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dataset Ses Kaydedici',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const SentenceRecorderPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- Yeni Veri Yapısı: CSV Satırını Temsil Eder ---
class SentenceEntry {
  final String id;
  final String text;
  final String speaker;
  final String language;

  SentenceEntry({
    required this.id,
    required this.text,
    required this.speaker,
    required this.language,
  });

  // CSV satırından SentenceEntry oluşturma
  factory SentenceEntry.fromCsvRow(List<dynamic> csvRow) {
    // Minimum 4 sütun bekliyoruz: ID, Text, Speaker, Language
    if (csvRow.length < 4) {
      throw FormatException("Invalid CSV row format: $csvRow");
    }
    return SentenceEntry(
      id: csvRow[0]?.toString().trim() ?? '', // ID (String veya int olabilir)
      text: csvRow[1]?.toString().trim() ?? '', // Metin
      speaker: csvRow[2]?.toString().trim() ?? '', // Konuşmacı
      language: csvRow[3]?.toString().trim() ?? '', // Dil Kodu
    );
  }

  // SentenceEntry'yi TTS Metadata satırı formatına çevirme (Eğitim için)
  // Format: göreli/yol/ses.wav|Metin|Konuşmacı|Dil Kodu
  String toMetadataLine(String wavsDirName) {
    final safeId = id.trim().replaceAll(RegExp(r'[^\w\s\d\-_~,;\[\]().]'), '');
    // Eğer ID temizlendikten sonra boş kalıyorsa uyarı ver veya farklı bir işlem yap
    // Şu an sadece temizlenmiş ID'yi kullanıyoruz. Boş ID'li girişler metadata'ya eklenmez (_generateMetadataFile içinde kontrol var)
    final audioFileName = '$safeId.wav';
    final audioFilePathRelative = p.join(wavsDirName, audioFileName);
    return '$audioFilePathRelative|$text|$speaker|$language';
  }
}

class SentenceRecorderPage extends StatefulWidget {
  const SentenceRecorderPage({super.key});

  @override
  State<SentenceRecorderPage> createState() => _SentenceRecorderPageState();
}

class _SentenceRecorderPageState extends State<SentenceRecorderPage> {
  // State Değişkenleri
  List<SentenceEntry> sentenceEntries = [];
  int currentIndex = 0;
  bool isRecording = false;
  bool isPlaying = false;
  bool isLoading = true; // Uygulama başlangıcında yükleniyor
  String? currentErrorMessage; // Hata mesajlarını göstermek için

  // Paket Nesneleri
  late final AudioRecorder audioRecorder;
  late final AudioPlayer audioPlayer;
  late SharedPreferences _prefs;

  // Kayıtların kaydedileceği ana dizin ve metadata dosyası yolu
  // BU YOLLARI KENDİ CİHAZINIZA GÖRE AYARLAYIN!
  // Örnek yol: '/storage/emulated/0/Download/MyVoiceDataset'
  static const String _datasetBasePath =
      '/storage/emulated/0/Download/MyVoiceDataset'; // << BURAYI AYARLAYIN
  static const String _metadataFileName = 'metadata.csv';
  static const String _wavsDirName =
      'wavs'; // WAV dosyalarının bulunacağı alt dizin (metadata içinde kullanılacak)

  String get _metadataFilePath => p.join(_datasetBasePath, _metadataFileName);
  String get _wavsDirPath => p.join(_datasetBasePath, _wavsDirName);

  // Sabitler
  static const String _lastIndexKey = 'lastSentenceIndex';
  // SentenceEntry listesini artık SharedPreferences'a kaydetmiyoruz.
  // Uygulama açılışında CSV'den okunuyor.

  @override
  void initState() {
    super.initState();
    audioRecorder = AudioRecorder();
    audioPlayer = AudioPlayer();
    _initialize();

    audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) {
        _stopPlayback();
      }
    });
  }

  @override
  void dispose() {
    _stopRecording();
    _stopPlayback();
    audioRecorder.dispose();
    audioPlayer.dispose();
    super.dispose();
  }

  // --- Başlangıç Hazırlıkları (Async) ---
  Future<void> _initialize() async {
    if (mounted) {
      setState(() {
        isLoading = true;
        currentErrorMessage = null; // Yeni başlangıçta hatayı temizle
      });
    }

    try {
      await _initSharedPreferences(); // SharedPreferences'ı başlat
      // İzinleri Dizinleri hazırlamadan ve CSV okumadan önce iste
      if (!await _requestPermissions()) {
        // İzinler verilmediyse burada bir hata durumu ayarla ve geri dön
        if (mounted) {
          setState(() {
            currentErrorMessage =
                "Uygulama çalışmak için gerekli depolama ve mikrofon izinlerine sahip değil.\nLütfen uygulama ayarlarına giderek izinleri manuel olarak verin."; // Kullanıcıya bilgi eklendi
            sentenceEntries = [];
            currentIndex = 0;
            // isLoading true kalacak ki hata ekranı görünsün
          });
        }
        debugPrint("Gerekli izinler verilmedi.");
        return; // İzin yoksa devam etme
      }
      await _prepareAppDirectory(); // Dizinleri hazırla (_datasetBasePath ve altındaki wavs)
      await _loadSentencesFromCsv(); // CSV'yi okuyup cümle listesini yükle
      await _loadLastIndex(); // Son kalınan indexi yükle (Liste yüklendikten sonra)

      // Eğer liste yüklendi ama yüklenen index listenin dışındaysa veya liste boşsa, indexi sıfırla
      if (currentIndex >= sentenceEntries.length || sentenceEntries.isEmpty) {
        if (currentIndex != 0) {
          debugPrint(
              "Yüklenen index ($currentIndex) liste boyutu (${sentenceEntries.length}) dışında veya liste boş. Index sıfırlanıyor.");
          currentIndex = 0;
          await _saveCurrentIndex(); // Sıfırlanan indexi kaydet
        } else {
          debugPrint("Liste boş veya index zaten sıfır.");
        }
      } else {
        // Başarılı yükleme ve index geçerli
        debugPrint(
          "${sentenceEntries.length} giriş yüklendi. ${currentIndex + 1}. girişte devam ediliyor.",
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${sentenceEntries.length} giriş yüklendi. ${currentIndex + 1}. girişte devam ediliyor.',
              ),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Başlangıç hazırlık hatası: $e");
      if (mounted) {
        setState(() {
          currentErrorMessage = "Başlangıç hatası: ${e.toString()}";
          sentenceEntries = []; // Hata durumunda listeyi temizle
          currentIndex = 0; // Indexi sıfırla
          // isLoading true kalacak ki hata ekranı görünsün
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Başlangıç hatası: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted && currentErrorMessage == null) {
        // Eğer bir hata mesajı ayarlanmadıysa yükleme bitti
        setState(() {
          isLoading = false;
        });
      } else if (mounted && currentErrorMessage != null) {
        // Hata mesajı ayarlandıysa, yükleme bitti olarak işaretlemeye gerek yok
        // Hata ekranı görünecek
      }
    }
  }

  // --- SharedPreferences Başlatma ---
  Future<void> _initSharedPreferences() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // --- Son Kalınan Indexi Yükleme ---
  Future<void> _loadLastIndex() async {
    try {
      int? savedIndex = _prefs.getInt(_lastIndexKey);
      // Yüklenen index liste sınırları içindeyse kullan, aksi halde sıfırla
      // Bu fonksiyon _loadSentencesFromCsv bittikten sonra çağrılmalı
      if (savedIndex != null &&
          savedIndex >= 0 &&
          savedIndex < sentenceEntries.length) {
        currentIndex = savedIndex;
        debugPrint("Son kalınan index yüklendi: $currentIndex");
      } else {
        currentIndex = 0; // Geçersiz index veya liste boş, sıfırla
        debugPrint(
            "Son kalınan index bulunamadı, geçersiz veya liste boş. Index sıfırlandı.");
      }
    } catch (e) {
      debugPrint("Index yükleme hatası: $e");
      currentIndex = 0; // Hata durumunda indexi sıfırla
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Son index yüklenirken hata: ${e.toString()}')),
        );
      }
    }
    // UI build metodu tarafından güncellenecek (isLoading false olduğunda)
  }

  // --- Cümle Indexini Kaydetme ---
  Future<void> _saveCurrentIndex() async {
    try {
      // Sadece liste boş değilse ve index sınırları içindeyse kaydedelim
      if (sentenceEntries.isNotEmpty &&
          currentIndex >= 0 &&
          currentIndex < sentenceEntries.length) {
        await _prefs.setInt(_lastIndexKey, currentIndex);
        debugPrint("Cümle indexi kaydedildi: $currentIndex");
      } else {
        debugPrint(
            "Liste boş veya index geçersiz olduğu için index kaydedilmedi.");
      }
    } catch (e) {
      debugPrint("Index kaydetme hatası: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Index kaydedilirken hata oluştu: ${e.toString()}')),
        );
      }
    }
  }

  // --- Uygulama Dizinlerini Hazırlama ---
  Future<void> _prepareAppDirectory() async {
    try {
      // Ana veri seti dizinini oluştur
      final datasetBaseDir = Directory(_datasetBasePath);
      if (!await datasetBaseDir.exists()) {
        debugPrint("Ana veri seti dizini oluşturuluyor: $_datasetBasePath");
        await datasetBaseDir.create(recursive: true);
      }

      // WAVs alt dizinini oluştur
      final wavsDir = Directory(_wavsDirPath);
      if (!await wavsDir.exists()) {
        debugPrint("WAVs kayıt dizini oluşturuluyor: $_wavsDirPath");
        await wavsDir.create(recursive: true);
      }

      debugPrint("Ana Veri Seti Dizini: $_datasetBasePath");
      debugPrint("WAV Kayıt Dizini: $_wavsDirPath");
    } catch (e) {
      debugPrint("Dizin hazırlama hatası: $e");
      // Hatayı yukarı fırlat ki _initialize yakalayabilsin
      rethrow; // throw e; yerine rethrow kullanıldı
    }
  }

  // --- Belirtilen Yoldaki CSV Dosyasını Okuma (Otomatik Yükleme) ---
  Future<void> _loadSentencesFromCsv() async {
    if (mounted) {
      setState(() {
        sentenceEntries = []; // Önceki listeyi temizle
        // currentIndex loadLastIndex tarafından güncellenecek
        currentErrorMessage = null; // Hata mesajını temizle
      });
    }

    final csvFile = File(_metadataFilePath);

    if (!await csvFile.exists()) {
      debugPrint("Metadata dosyası bulunamadı: $_metadataFilePath");
      if (mounted) {
        currentErrorMessage =
            "Metadata dosyası bulunamadı:\n$_metadataFilePath\nLütfen bu konuma CSV dosyasını kopyalayın.";
      }
      // Dosya yoksa listeyi boş bırak, hata mesajını göster
      return;
    }

    try {
      final String csvString = await csvFile.readAsString(encoding: utf8);

      List<List<dynamic>> rawCsvList = const CsvToListConverter(
        // <-- rawCsvList artık final değil
        fieldDelimiter: '|',
        eol: '\n',
        shouldParseNumbers: false,
      ).convert(csvString);

      List<SentenceEntry> loadedEntries = [];
      // Başlık satırı atlama (Eğer CSV'nizde başlık satırı varsa bu satırı aktif edin)
      // Genellikle CSV dosyasının ilk satırı başlık içerir.
      if (rawCsvList.isNotEmpty && rawCsvList[0].length >= 4) {
        // Başlık satırının en az 4 sütunu olduğundan emin ol
        // İlk sütun başlığı "ID", "id", "ID " vb. gibi başlığa benzeyen bir şey mi kontrol et
        String firstCellValue =
            rawCsvList[0][0]?.toString().trim().toLowerCase() ?? '';
        // Hem ID hem de Text sütun başlıklarını kontrol edelim daha sağlam olur
        String secondCellValue =
            rawCsvList[0][1]?.toString().trim().toLowerCase() ?? '';
        if ((firstCellValue == 'id') &&
            (secondCellValue == 'metin' || secondCellValue == 'text')) {
          // Farklı olası başlık varyasyonları
          rawCsvList = rawCsvList.skip(1).toList();
          debugPrint("Başlık satırı atlandı.");
        }
      }

      for (var row in rawCsvList) {
        // Minimum 4 sütun ve ilk sütun (ID) boş olmamalı
        if (row.length >= 4 &&
            row[0] != null &&
            row[0].toString().trim().isNotEmpty) {
          try {
            loadedEntries.add(SentenceEntry.fromCsvRow(row));
          } catch (e) {
            debugPrint("Satır parsing hatası, atlandı: $row - Hata: $e");
          }
        } else {
          debugPrint("Geçersiz formatlı veya boş satır atlandı: $row");
        }
      }

      if (mounted) {
        setState(() {
          sentenceEntries = loadedEntries; // Yeni listeyi ata
          // currentIndex loadLastIndex tarafından güncellenecek
        });
      }

      if (sentenceEntries.isEmpty && rawCsvList.isNotEmpty) {
        // Dosya boş değil ama geçerli giriş bulunamadı
        debugPrint("Dosyada geçerli giriş bulunamadı: $_metadataFilePath");
        if (mounted) {
          currentErrorMessage = "Metadata dosyasında geçerli giriş bulunamadı.";
        }
      } else if (sentenceEntries.isEmpty) {
        // Dosya boştu veya başlık satırından başka bir şey içermiyordu
        debugPrint("Metadata dosyası boş: $_metadataFilePath");
        if (mounted) {
          currentErrorMessage = "Metadata dosyası boş:\n$_metadataFilePath";
        }
      } else {
        debugPrint("${sentenceEntries.length} giriş CSV'den yüklendi.");
      }
    } catch (e) {
      debugPrint("CSV okuma veya parse hatası: $e");
      if (mounted) {
        currentErrorMessage = "CSV okuma hatası: ${e.toString()}";
      }
      // Hata durumunda listeyi boş bırak
      if (mounted) {
        setState(() {
          sentenceEntries = [];
        });
      }
      rethrow; // Hatayı yukarı fırlat ki _initialize yakalayabilsin (throw e; yerine rethrow kullanıldı)
    }
    // isLoading ve diğer state güncellemeleri _initialize içinde yapılıyor
  }

  // --- İzinleri Kontrol Etme ve İsteme ---
  Future<bool> _requestPermissions() async {
    // Mikrofon izni gerekiyor
    var microphoneStatus = await Permission.microphone.status;
    // Depolama izni (Okuma ve Yazma için)
    // permission_handler dokümantasyonuna göre Android 11+ için MANAGE_EXTERNAL_STORAGE daha uygun
    // Permission.storage Android 10'a kadar ve MediaStore erişimleri için kullanılabilir.
    // Biz genel /Download klasörüne eriştiğimiz için ManageExternalStorage denemek daha doğru olabilir.
    // Kullanıcının bu izni manuel vermesi gerekeceği unutulmamalı.
    var storageStatus =
        await Permission.manageExternalStorage.status; // Android 11+
    // Eğer Android 10 veya öncesini hedefliyorsanız veya manageExternalStorage desteklenmiyorsa:
    // var storageStatus = await Permission.storage.status;

    bool granted = true; // Başlangıçta izinler tam varsayalım
    List<Permission> permissionsToRequest = [];

    if (microphoneStatus != PermissionStatus.granted) {
      permissionsToRequest.add(Permission.microphone);
    }

    if (storageStatus != PermissionStatus.granted) {
      permissionsToRequest
          .add(Permission.manageExternalStorage); // veya Permission.storage
    }

    if (permissionsToRequest.isNotEmpty) {
      Map<Permission, PermissionStatus> statuses =
          await permissionsToRequest.request();

      // İstenen tüm izinlerin verilip verilmediğini kontrol et
      for (var permission in permissionsToRequest) {
        if (statuses[permission] != PermissionStatus.granted) {
          granted = false; // En az bir izin verilmediyse
          debugPrint("İzin verilmedi: $permission");
          // İzin verilmediğinde kullanıcıyı ayarlara yönlendirme mantığı buraya eklenebilir
          // openAppSettings() // permission_handler paketi bu fonksiyonu içerir
          break; // Bir hata mesajı yeterli
        }
      }
    }

    if (!granted) {
      // İzinler tam olarak verilmediyse kullanıcıya bilgi ver
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Uygulama çalışmak için gerekli izinlere sahip değil. Ayarları kontrol edin.')),
        );
      }
    }

    return granted; // Tüm gerekli izinler verildiyse true dön
  }

  // --- Ses Kayıt (unused uyarısı için () => kullanıldı) ---
  Future<void> _startRecording() async {
    // isRecording, isPlaying, isLoading kontrolleri UI'da buton aktifliğinde yapılıyor.
    // Burada sadece temel hazır olma durumlarını kontrol edelim.
    // _wavsDirPath'in null olmadığını initialize garantiliyor eğer hata yoksa.
    if (sentenceEntries.isEmpty ||
        currentIndex < 0 ||
        currentIndex >= sentenceEntries.length) {
      // Index kontrolü eklendi
      debugPrint("Kayıt başlatılamaz: Liste boş veya index geçersiz.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Liste boş veya index geçersiz.')),
        );
      }
      return;
    }

    // İzin kontrolünü initialize içinde yaptık, burada tekrar istemeye gerek yok.
    // Ancak uygulamanın yaşam döngüsü içinde izinler geri alınabilir.
    // Kayıttan önce izinleri *kontrol etmek* iyi olabilir, istemek değil.
    // Eğer _requestPermissions false dönüyorsa initialize zaten hata ekranını gösterir.
    // Buraya geliyorsak izinler verilmiş olmalı (initialize başarılı varsayımıyla).

    try {
      final currentEntry = sentenceEntries[currentIndex];
      // Güvenlik: ID'de dosya yolu karakterleri olmamalı.
      final safeId = currentEntry.id
          .trim()
          .replaceAll(RegExp(r'[^\w\s\d\-_~,;\[\]().]'), '');
      if (safeId.isEmpty) {
        debugPrint("Geçersiz ID, kayıt yapılamaz: ${currentEntry.id}");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Geçersiz giriş ID\'si, kayıt yapılamaz.'),
            ),
          );
        }
        return;
      }

      final outputFileName = '$safeId.wav';
      // _wavsDirPath'in null olmadığını varsayıyoruz initialize başarılıysa
      final outputFile = File(p.join(_wavsDirPath, outputFileName));

      // Üzerine yazma çözümü: Eğer dosya zaten varsa, sil
      if (await outputFile.exists()) {
        try {
          await outputFile.delete();
          debugPrint("Mevcut dosya silindi: ${outputFile.path}");
        } catch (e) {
          debugPrint("Mevcut dosya silinirken hata: $e");
          // Hata çok kritik değil, devam edebiliriz, kullanıcıya bilgi verdik
        }
      }

      RecordConfig config = const RecordConfig(
        sampleRate: 16000, // Uygulamanızın kaydettiği sample rate
        bitRate: 128000,
        numChannels: 1,
        encoder: AudioEncoder.wav, // WAV formatı
      );
      await audioRecorder.start(config, path: outputFile.path);

      if (mounted) {
        setState(() {
          isRecording = true;
        });
      }

      debugPrint("Kayıt başladı: ${outputFile.path}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kayıt başladı: $outputFileName')),
        );
      }
    } catch (e) {
      debugPrint("Kayıt başlatma hatası: ${e.toString()}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kayıt başlatılamadı: ${e.toString()}')),
        );
      }
      if (mounted) {
        setState(() {
          isRecording = false;
        });
      }
    }
  }

  // --- Ses Durdur (Zaten vardı, korundu) ---
  Future<void> _stopRecording() async {
    if (!isRecording) {
      debugPrint("Kayıt zaten durduruldu.");
      return;
    }

    try {
      final path = await audioRecorder.stop();
      debugPrint("Kayıt durduruldu. Dosya: $path");

      if (mounted) {
        setState(() {
          isRecording = false;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Kayıt durduruldu.')));
      }
    } catch (e) {
      debugPrint("Kayıt durdurma hatası: ${e.toString()}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Kayıt durdurulurken hata oluştu: ${e.toString()}'),
          ),
        );
      }
      if (mounted) {
        setState(() {
          isRecording = false;
        });
      }
    }
  }

  // --- Ses Oynatma (unused uyarısı için () => kullanıldı) ---
  Future<void> _startPlayback() async {
    // isRecording, isPlaying, isLoading kontrolleri UI'da buton aktifliğinde yapılıyor.
    // Burada sadece temel hazır olma durumlarını kontrol edelim.
    // _wavsDirPath'in null olmadığını initialize garantiliyor eğer hata yoksa.
    if (sentenceEntries.isEmpty ||
        currentIndex < 0 ||
        currentIndex >= sentenceEntries.length) {
      // Index kontrolü eklendi
      debugPrint(
        "Oynatma başlatılamaz: Liste boş veya index geçersiz.",
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Liste boş veya index geçersiz.')),
        );
      }
      return;
    }

    // --- Oynatılacak Dosya Adını ID'den Al ---
    final currentEntry = sentenceEntries[currentIndex];
    final safeId = currentEntry.id
        .trim()
        .replaceAll(RegExp(r'[^\w\s\d\-_~,;\[\]().]'), '');
    if (safeId.isEmpty) {
      debugPrint("Geçersiz ID, oynatma yapılamaz: ${currentEntry.id}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Geçersiz giriş ID\'si, oynatma yapılamaz.'),
          ),
        );
      }
      return;
    }
    final audioFileName = '$safeId.wav';
    // _wavsDirPath'in null olmadığını varsayıyoruz initialize başarılıysa
    final audioFile = File(p.join(_wavsDirPath, audioFileName));

    if (!await audioFile.exists()) {
      debugPrint("Bu ID için kayıt bulunamadı: ${currentEntry.id}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bu cümle için kayıt bulunamadı.')),
        );
      }
      return;
    }

    try {
      Source audioSource = DeviceFileSource(audioFile.path);
      await audioPlayer.play(audioSource);

      if (mounted) {
        setState(() {
          isPlaying = true;
        });
      }

      debugPrint("Oynatma başladı: ${audioFile.path}");
    } catch (e) {
      debugPrint("Oynatma başlatma hatası: ${e.toString()}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Oynatma başlatılamadı: ${e.toString()}')),
        );
      }
      if (mounted) {
        setState(() {
          isPlaying = false;
        });
      }
    }
  }

  Future<void> _stopPlayback() async {
    if (!isPlaying) {
      return;
    }
    try {
      await audioPlayer.stop();
      debugPrint("Oynatma durduruldu.");
    } catch (e) {
      debugPrint("Oynatma durdurma hatası: ${e.toString()}");
    } finally {
      if (mounted) {
        setState(() {
          isPlaying = false;
        });
      }
    }
  }

  // --- Cümle Geçişi (Indexi kaydedecek şekilde güncellendi) ---
  void navigateSentence(int step) {
    // isRecording, isPlaying, isLoading kontrolleri UI'da buton aktifliğinde yapılıyor.
    // Burada sadece temel hazır olma durumlarını kontrol edelim.
    if (sentenceEntries.isEmpty ||
        currentIndex < 0 ||
        currentIndex >= sentenceEntries.length) {
      // Index kontrolü eklendi
      debugPrint(
        "Geçiş yapılamaz: Liste boş veya index geçersiz.",
      );
      if (sentenceEntries.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cümle listesi boş.')),
        );
      } else if (mounted) {
        // isRecording || isPlaying || isLoading durumları
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lütfen işlemi tamamlayın.')),
        );
      }
      return;
    }

    final nextIndex =
        (currentIndex + step).clamp(0, sentenceEntries.length - 1);
    if (nextIndex != currentIndex) {
      if (mounted) {
        setState(() {
          currentIndex = nextIndex;
        });
      }
      _saveCurrentIndex(); // Index değiştiğinde kaydet
    } else {
      // Zaten en başa veya en sona ulaşıldıysa, kullanıcıya bilgi ver.
      final edge = step > 0 ? "sonuna" : "başına";
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Metnin $edge ulaştınız.')));
      }
    }
  }

  // --- Metadata Dosyası Oluşturma (Güncel yüklü listeden ve var olan kayıtlardan) ---
  Future<void> _generateMetadataFile() async {
    // isRecording, isPlaying, isLoading kontrolleri UI'da buton aktifliğinde yapılıyor.
    // Burada sadece temel hazır olma durumlarını kontrol edelim.
    // _datasetBasePath ve _wavsDirPath null olmadığını initialize garantiliyor eğer hata yoksa.
    if (sentenceEntries.isEmpty) {
      debugPrint(
        "Metadata oluşturulamamaz: Liste boş.",
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cümle listesi yüklenemedi veya boş.')),
        );
      }
      return;
    }

    if (mounted) {
      setState(() {
        isLoading = true; // Metadata oluşturma sırasında UI'ı kilitle
      });
    }

    try {
      // metadata.csv dosyasını ana dizine kaydediyoruz
      final metadataFile = File(_metadataFilePath);

      final buffer = StringBuffer();
      int validEntryCount = 0;

      // Tüm yüklenmiş girişleri (SentenceEntry) döngüye al
      for (var entry in sentenceEntries) {
        // Bu girişe ait ses dosyasının mevcut olup olmadığını kontrol et
        final safeId =
            entry.id.trim().replaceAll(RegExp(r'[^\w\s\d\-_~,;\[\]().]'), '');
        if (safeId.isEmpty) {
          debugPrint("Geçersiz ID, metadata dışında bırakıldı: ${entry.id}");
          continue; // Geçersiz ID'li girişi atla
        }
        final audioFileName = '$safeId.wav';
        // İlgili ses dosyasının gerçek, tam yolunu oluştur ve var olup olmadığını kontrol et
        // _wavsDirPath'in null olmadığını varsayıyoruz initialize başarılıysa
        final actualAudioFilePathAbsolute = p.join(_wavsDirPath, audioFileName);
        final actualAudioFile = File(actualAudioFilePathAbsolute);

        if (await actualAudioFile.exists()) {
          // Eğer ses dosyası varsa, TTS eğitim formatındaki metadata satırını ekle
          // Format: göreli/yol/ses.wav|Metin|Konuşmacı|Dil Kodu
          buffer.writeln(entry.toMetadataLine(
              _wavsDirName)); // SentenceEntry içindeki toMetadataLine metodu
          validEntryCount++;
        } else {
          // Dosya yoksa konsola bilgi yaz, metadataya dahil etme
          debugPrint(
            "Metadataya dahil edilmedi: ${entry.id} (dosya bulunamadı: $actualAudioFilePathAbsolute)",
          );
        }
      }

      // Dosyayı yaz (UTF-8 olarak)
      await metadataFile.writeAsString(buffer.toString(), encoding: utf8);

      debugPrint(
        "Metadata dosyası oluşturuldu: ${metadataFile.path} ($validEntryCount geçerli giriş)",
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Metadata dosyası oluşturuldu: $_metadataFileName ($validEntryCount geçerli kayıt)',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint("Metadata oluşturma hatası: ${e.toString()}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Metadata oluşturulurken hata: ${e.toString()}'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false; // Metadata oluşturma bitti, UI kilidini kaldır
        });
      }
    }
  }

  // --- UI Yapısı ---
  @override
  Widget build(BuildContext context) {
    // Başlangıçta yükleniyorsa yükleme ekranını göster.
    // _datasetBasePath ve _wavsDirPath null kontrolleri initialize içinde yapılıyor
    // ve hata varsa currentErrorMessage ayarlanıyor.
    if (isLoading) {
      // Eğer hata mesajı var ve liste boşsa, hata ekranını göster
      if (currentErrorMessage != null && sentenceEntries.isEmpty) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Dataset Ses Kaydedici'),
            centerTitle: true,
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                currentErrorMessage!, // Hata mesajını göster
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 18),
              ),
            ),
          ),
        );
      }
      // Hata mesajı yoksa veya liste boş değilse yükleme göstergesi
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Yükleme bittiğinde ama liste boşsa (ve hata mesajı da yoksa), bilgilendirme ekranı.
    if (sentenceEntries.isEmpty && currentErrorMessage == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Dataset Ses Kaydedici'),
          centerTitle: true,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              "Metadata dosyası yüklenemedi veya geçerli giriş bulunamadı.\nLütfen CSV dosyasını şu konuma kopyalayın:\n$_metadataFilePath",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      );
    }

    // Ana uygulama arayüzü (Liste dolu ve her şey hazır olduğunda)
    // İlgili cümle için kayıt dosyası mevcut mu kontrol et (UI'da Dinle butonu aktifliği için)
    // Sadece liste boş değilse ve index geçerliyse kontrol et
    final bool canCheckAudioFile = sentenceEntries.isNotEmpty &&
        currentIndex >= 0 &&
        currentIndex < sentenceEntries.length;

    String? currentEntryId;
    // canCheckAudioFile true ise currentEntryId null olmayacaktır.
    if (canCheckAudioFile) {
      currentEntryId = sentenceEntries[currentIndex].id.trim();
    }

    // ID'de özel karakterleri temizlemeden dosya kontrolü yapmayalım
    // safeCurrentEntryId'yi sadece canCheckAudioFile true ise hesapla
    final String? safeCurrentEntryId = canCheckAudioFile
        ? currentEntryId?.replaceAll(
            RegExp(r'[^\w\s\d\-_~,;\[\]().]'), '') // String? olabilir
        : null;

    // currentAudioFileExists değişkenini burada tanımla ve kullan
    // Dinle butonu için kullanılır
    final bool currentAudioFileExists =
        (safeCurrentEntryId != null && safeCurrentEntryId.isNotEmpty)
            ? File(p.join(_wavsDirPath, '$safeCurrentEntryId.wav')).existsSync()
            : false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dataset Ses Kaydedici'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Metadata Oluştur Butonu
            ElevatedButton(
              // Liste doluysa VE boşta ise VE dizin hazırsa aktif
              // isLoading kontrolü eklendi
              onPressed: sentenceEntries.isNotEmpty &&
                      !isRecording &&
                      !isPlaying &&
                      !isLoading
                  ? _generateMetadataFile
                  : null,
              child: const Text('Metadata Dosyası Oluştur'),
            ),
            const SizedBox(height: 16),
            // Sayacı ve ilerlemeyi gösteren Text widget'ı
            Text(
              sentenceEntries.isNotEmpty
                  ? "${currentIndex + 1}/${sentenceEntries.length}"
                  : "0/0", // Liste boşken 0/0 gösterebilir
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(
                height:
                    8), // İlerleme sayısı ile ID/Dil/Konuşmacı arasına boşluk

            // ID, Konuşmacı ve Dil kodunu göster
            // Indexin ve listenin geçerli olduğundan emin ol
            if (sentenceEntries.isNotEmpty &&
                currentIndex >= 0 &&
                currentIndex < sentenceEntries.length)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  "ID: ${sentenceEntries[currentIndex].id} | Konuşmacı: ${sentenceEntries[currentIndex].speaker.isEmpty ? 'Belirtilmemiş' : sentenceEntries[currentIndex].speaker} | Dil: ${sentenceEntries[currentIndex].language.isEmpty ? 'Belirtilmemiş' : sentenceEntries[currentIndex].language}",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 16, fontStyle: FontStyle.italic),
                ),
              )
            else if (!isLoading &&
                sentenceEntries
                    .isEmpty) // Liste boşsa ve yükleme bittiyse boşluk bırak (currentIndex kontrolü kalktı)
              const SizedBox(height: 30),

            // Cümle metnini gösteren genişletilebilir alan
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: Text(
                    // Sadece liste boş değilse ve index geçerliyse metni göster
                    sentenceEntries.isNotEmpty &&
                            currentIndex >= 0 &&
                            currentIndex < sentenceEntries.length
                        ? sentenceEntries[currentIndex].text
                        : isLoading
                            ? "Yükleniyor..."
                            : (currentErrorMessage ??
                                "Liste Yüklenemedi"), // Hata durumunda veya liste boşken mesaj
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.fade,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Kontrol Butonları
            // Alt bar sorununu çözmek için artırılmış alt padding
            Padding(
              padding: EdgeInsets.only(
                bottom: (isRecording || isPlaying)
                    ? 70.0
                    : 16.0, // Kayıt/Oynatma sırasında alt padding'i artır
              ),
              child: Column(
                // Butonları dikey olarak düzenleyelim
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    // Yataydaki ilk 3 buton
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          // Liste doluysa VE ilk cümlede değilse VE boşta ise aktif
                          // isLoading kontrolü eklendi
                          onPressed: sentenceEntries.isNotEmpty &&
                                  currentIndex > 0 &&
                                  !isRecording &&
                                  !isPlaying &&
                                  !isLoading
                              ? () => navigateSentence(
                                  -1) // onPressed callback'i düzeltildi
                              : null,
                          child: const Text('Önceki'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          // Sadece liste doluysa ve boşta ise aktif
                          // isLoading kontrolü eklendi
                          onPressed: sentenceEntries.isNotEmpty &&
                                  !isRecording &&
                                  !isPlaying &&
                                  !isLoading
                              ? () =>
                                  _startRecording() // onPressed callback'i düzeltildi
                              : null,
                          child: const Text('Kaydet'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: isRecording
                              ? () => _stopRecording()
                              : null, // Sadece kayıt aktifse durdur aktif
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          child: const Text('Durdur'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8), // Yatay gruplar arasına boşluk
                  Row(
                    // Yataydaki sonraki 2 buton
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          // İlgili dosya varsa VE boşta ise aktif
                          // isLoading kontrolü eklendi
                          onPressed:
                              currentAudioFileExists && // Kayıt dosyası mevcut mu?
                                      !isRecording &&
                                      !isPlaying &&
                                      !isLoading
                                  ? () =>
                                      _startPlayback() // onPressed callback'i düzeltildi
                                  : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                          ),
                          child: const Text('Dinle'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          // Liste doluysa VE son cümlede değilse VE boşta ise aktif
                          // isLoading kontrolü eklendi
                          onPressed: sentenceEntries.isNotEmpty &&
                                  currentIndex < sentenceEntries.length - 1 &&
                                  !isRecording &&
                                  !isPlaying &&
                                  !isLoading
                              ? () => navigateSentence(
                                  1) // onPressed callback'i düzeltildi
                              : null,
                          child: const Text('Sonraki'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
