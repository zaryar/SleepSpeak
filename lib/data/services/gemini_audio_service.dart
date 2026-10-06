import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/models/detected_event.dart';
import 'logger_service.dart';
import 'platform_file/platform_file.dart';

enum AiProvider { oracle, gemini }

class GeminiAudioClassificationResult {
  final EventCategory category;
  final double confidence;
  final String? transcription;
  final String? subType;
  final String? explanation;
  final String? dynamicEmoji;

  const GeminiAudioClassificationResult({
    required this.category,
    required this.confidence,
    this.transcription,
    this.subType,
    this.explanation,
    this.dynamicEmoji,
  });
}

typedef AiAudioClassificationResult = GeminiAudioClassificationResult;

class GeminiAudioService {
  static final GeminiAudioService _instance = GeminiAudioService._internal();
  factory GeminiAudioService() => _instance;
  GeminiAudioService._internal();

  final LoggerService _logger = LoggerService();

  static const String _prefProvider = 'ai_backend_provider';
  static const String _prefOracleUrl = 'oracle_server_url';
  static const String _prefOracleApiKey = 'oracle_api_key';
  static const String _prefGeminiApiKey = 'gemini_api_key';
  static const String _prefWhisperModel = 'oracle_whisper_model';
  static const String _envApiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

  static const String defaultOracleUrl = '';
  static const String defaultOracleApiKey = '';
  static const String defaultWhisperModel = 'base';

  static DateTime? _lastGeminiRequestTime;

  Future<AiProvider> getProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(_prefProvider) ?? 'gemini';
    return mode == 'oracle' ? AiProvider.oracle : AiProvider.gemini;
  }

  Future<void> saveProvider(AiProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefProvider, provider.name);
  }

  Future<String> getOracleUrl() async {
    final prefs = await SharedPreferences.getInstance();
    String? stored = prefs.getString(_prefOracleUrl);
    var url = (stored ?? defaultOracleUrl).trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Future<void> saveOracleUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    var cleanUrl = url.trim();
    while (cleanUrl.endsWith('/')) {
      cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1);
    }
    await prefs.setString(_prefOracleUrl, cleanUrl);
  }

  Future<String> getOracleApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefOracleApiKey) ?? defaultOracleApiKey;
  }

  Future<void> saveOracleApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefOracleApiKey, key.trim());
  }

  Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_prefGeminiApiKey);
    if (key != null && key.trim().isNotEmpty) {
      return key.trim();
    }
    return _envApiKey;
  }

  Future<void> saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefGeminiApiKey, key.trim());
  }

  Future<String> getWhisperModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefWhisperModel) ?? defaultWhisperModel;
  }

  Future<void> saveWhisperModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = (model.toLowerCase().trim() == 'small') ? 'small' : 'base';
    await prefs.setString(_prefWhisperModel, clean);
  }

  Future<bool> testOracleConnection() async {
    try {
      final url = await getOracleUrl();
      if (url.isEmpty) return false;
      final uri = Uri.parse('$url/health');
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Classifies a single audio event segment using Oracle Server or Gemini
  Future<GeminiAudioClassificationResult> classifyAudioSegment({
    required AppFile wavFile,
    required int startMs,
    required int durationMs,
    void Function(String status)? onStatusUpdate,
  }) async {
    if (kIsWeb) {
      return const GeminiAudioClassificationResult(
        category: EventCategory.general,
        confidence: 0.0,
        subType: 'Unklassifiziert',
        explanation: 'Web-Version unterstützt keine Audio-Klassifizierung',
      );
    }

    final snippetBytes = await _extractWavSnippetBytes(
      wavFile: wavFile,
      startMs: startMs,
      durationMs: durationMs,
    );

    if (snippetBytes == null || snippetBytes.length <= 44) {
      return const GeminiAudioClassificationResult(
        category: EventCategory.noise,
        confidence: 0.5,
        subType: 'Kurzes Rauschen',
        explanation: 'Audiodatei war zu kurz oder leer',
      );
    }

    final provider = await getProvider();
    if (provider == AiProvider.oracle) {
      return _classifyWithOracle(snippetBytes, onStatusUpdate: onStatusUpdate);
    } else {
      return _classifyWithGemini(snippetBytes, startMs: startMs, onStatusUpdate: onStatusUpdate);
    }
  }

  /// Single classification via Oracle Cloud Server
  Future<GeminiAudioClassificationResult> _classifyWithOracle(
    Uint8List wavBytes, {
    void Function(String status)? onStatusUpdate,
  }) async {
    try {
      final url = await getOracleUrl();
      if (url.isEmpty) {
        return const GeminiAudioClassificationResult(
          category: EventCategory.general,
          confidence: 0.0,
          subType: 'Kein Server konfiguriert',
          explanation: 'Keine Server-URL in den Einstellungen hinterlegt',
        );
      }
      final apiKey = await getOracleApiKey();
      final model = await getWhisperModel();
      final uri = Uri.parse('$url/api/v1/classify?model=$model');

      final request = http.MultipartRequest('POST', uri);
      request.headers['X-API-Key'] = apiKey;
      request.files.add(http.MultipartFile.fromBytes(
        'audio',
        wavBytes,
        filename: 'snippet.wav',
      ));

      final streamedResponse = await request.send().timeout(const Duration(seconds: 15));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final catStr = (data['category'] as String? ?? 'general').toLowerCase().trim();
        final conf = (data['confidence'] as num?)?.toDouble() ?? 0.85;
        final trans = data['transcription'] as String?;
        final subType = data['subType'] as String?;
        final expl = data['explanation'] as String?;
        final emoji = data['emoji'] as String?;

        return GeminiAudioClassificationResult(
          category: _mapCategory(catStr, trans),
          confidence: conf,
          transcription: trans,
          subType: subType,
          explanation: expl,
          dynamicEmoji: emoji,
        );
      } else {
        _logger.log('Oracle AI Server HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      _logger.log('Oracle AI Server Error: $e');
    }

    return const GeminiAudioClassificationResult(
      category: EventCategory.general,
      confidence: 0.0,
      subType: 'Unklassifiziert',
      explanation: 'Fehler bei der Verbindung zum Oracle KI-Server',
    );
  }

  /// Single classification via Google Gemini API
  Future<GeminiAudioClassificationResult> _classifyWithGemini(
    Uint8List snippetBytes, {
    required int startMs,
    void Function(String status)? onStatusUpdate,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) {
      return const GeminiAudioClassificationResult(
        category: EventCategory.general,
        confidence: 0.0,
        subType: 'Unklassifiziert',
        explanation: 'Kein Gemini API-Key hinterlegt',
      );
    }

    // Rate Limiting: ensure >= 4.2 seconds between requests (14 RPM max for 15 RPM free tier)
    final lastReq = _lastGeminiRequestTime;
    if (lastReq != null) {
      final elapsed = DateTime.now().difference(lastReq);
      if (elapsed < const Duration(milliseconds: 4200)) {
        final waitMs = 4200 - elapsed.inMilliseconds;
        try {
          onStatusUpdate?.call('Warte kurz für Gemini Free Tier (${(waitMs / 1000).toStringAsFixed(1)}s)...');
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: waitMs));
      }
    }
    _lastGeminiRequestTime = DateTime.now();

    final base64Audio = base64Encode(snippetBytes);
    final candidateModels = ['gemini-2.0-flash', 'gemini-1.5-flash'];

    const prompt = '''
Du bist ein hochentwickelter KI-Schlaflabor-Assistent. Höre dir dieses Audio-Snippet aus dem Schlafzimmer an und bestimme präzise, was zu hören ist.
Wähle die passendste category aus: speech, snore, movement, traffic, household, cough, pet, noise.
Wenn du "speech" auswählst, transkribiere unbedingt den Text (auch Flüstern)!

Antworte AUSSCHLIESSLICH als valides JSON-Objekt im Format:
{
  "category": "speech" | "snore" | "movement" | "traffic" | "household" | "cough" | "pet" | "noise",
  "subType": "Prägnanter Begriff auf Deutsch",
  "emoji": "Passendes Emoji",
  "confidence": 0.95,
  "transcription": "Transkription oder null",
  "explanation": "Kurzer Satz"
}
''';

    for (final model in candidateModels) {
      try {
        final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent');
        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'X-goog-api-key': apiKey,
          },
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {
                    'inline_data': {
                      'mime_type': 'audio/wav',
                      'data': base64Audio,
                    }
                  },
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'response_mime_type': 'application/json',
              'temperature': 0.1,
            }
          }),
        ).timeout(const Duration(seconds: 25));

        if (response.statusCode == 200) {
          final resJson = jsonDecode(response.body) as Map<String, dynamic>;
          final candidates = resJson['candidates'] as List<dynamic>?;
          if (candidates != null && candidates.isNotEmpty) {
            final content = candidates[0]['content'] as Map<String, dynamic>?;
            final parts = content?['parts'] as List<dynamic>?;
            if (parts != null && parts.isNotEmpty) {
              final text = parts[0]['text'] as String?;
              if (text != null && text.isNotEmpty) {
                final cleanedText = _stripJsonFences(text);
                final parsed = jsonDecode(cleanedText) as Map<String, dynamic>;
                final catStr = (parsed['category'] as String? ?? 'general').toLowerCase().trim();
                final conf = (parsed['confidence'] as num?)?.toDouble() ?? 0.85;
                final trans = parsed['transcription'] as String?;
                final subType = parsed['subType'] as String?;
                final expl = parsed['explanation'] as String?;
                final emoji = parsed['emoji'] as String?;

                return GeminiAudioClassificationResult(
                  category: _mapCategory(catStr, trans),
                  confidence: conf,
                  transcription: trans,
                  subType: subType,
                  explanation: expl,
                  dynamicEmoji: emoji,
                );
              }
            }
          }
        } else if (response.statusCode == 429) {
          onStatusUpdate?.call('Gemini Rate-Limit (429) erreicht. Warte 20s...');
          await Future.delayed(const Duration(seconds: 20));
          continue;
        }
      } catch (e) {
        _logger.log('Gemini $model Exception: $e');
      }
    }

    return const GeminiAudioClassificationResult(
      category: EventCategory.general,
      confidence: 0.0,
      subType: 'Unklassifiziert',
      explanation: 'Keine Antwort von Gemini erhalten',
    );
  }

  /// Classifies multiple audio event segments in a batch
  Future<List<GeminiAudioClassificationResult>> classifyAudioSegmentsBatch({
    required AppFile wavFile,
    required List<DetectedEvent> events,
    void Function(String status)? onStatusUpdate,
  }) async {
    final List<GeminiAudioClassificationResult> fallbackResults = List.generate(
      events.length,
      (_) => const GeminiAudioClassificationResult(
        category: EventCategory.general,
        confidence: 0.0,
        subType: 'Unklassifiziert',
        explanation: 'Fehler bei der KI-Analyse',
      ),
    );

    if (kIsWeb || events.isEmpty) return fallbackResults;

    final provider = await getProvider();
    if (provider == AiProvider.oracle) {
      final List<GeminiAudioClassificationResult> results = [];
      for (int i = 0; i < events.length; i++) {
        final ev = events[i];
        try {
          onStatusUpdate?.call('Analysiere Geräusch ${i + 1} von ${events.length} auf Oracle-Server...');
        } catch (_) {}
        final res = await classifyAudioSegment(
          wavFile: wavFile,
          startMs: ev.startOffset.inMilliseconds,
          durationMs: ev.duration.inMilliseconds,
          onStatusUpdate: onStatusUpdate,
        );
        results.add(res);
      }
      return results;
    } else {
      final List<GeminiAudioClassificationResult> results = [];
      for (int i = 0; i < events.length; i++) {
        final ev = events[i];
        try {
          onStatusUpdate?.call('Analysiere Geräusch ${i + 1} von ${events.length} mit Gemini...');
        } catch (_) {}
        final res = await classifyAudioSegment(
          wavFile: wavFile,
          startMs: ev.startOffset.inMilliseconds,
          durationMs: ev.duration.inMilliseconds,
          onStatusUpdate: onStatusUpdate,
        );
        results.add(res);
      }
      return results;
    }
  }

  String _stripJsonFences(String input) {
    var text = input.trim();
    if (text.startsWith('```json')) {
      text = text.substring(7);
    } else if (text.startsWith('```')) {
      text = text.substring(3);
    }
    if (text.endsWith('```')) {
      text = text.substring(0, text.length - 3);
    }
    return text.trim();
  }

  EventCategory _mapCategory(String catStr, String? trans) {
    EventCategory category = EventCategory.general;
    if (catStr.contains('speech') || catStr.contains('sprech') || catStr.contains('rede')) {
      category = EventCategory.speech;
    } else if (catStr.contains('snore') || catStr.contains('schnarch') || catStr.contains('atem')) {
      category = EventCategory.snore;
    } else if (catStr.contains('movement') || catStr.contains('beweg') || catStr.contains('bett') || catStr.contains('deck')) {
      category = EventCategory.movement;
    } else if (catStr.contains('traffic') || catStr.contains('verkehr') || catStr.contains('auto') || catStr.contains('straß')) {
      category = EventCategory.traffic;
    } else if (catStr.contains('household') || catStr.contains('haus') || catStr.contains('tür') || catStr.contains('knack')) {
      category = EventCategory.household;
    } else if (catStr.contains('cough') || catStr.contains('hust') || catStr.contains('nies') || catStr.contains('räusp')) {
      category = EventCategory.cough;
    } else if (catStr.contains('pet') || catStr.contains('tier') || catStr.contains('hund') || catStr.contains('katz')) {
      category = EventCategory.pet;
    } else if (catStr.contains('noise') || catStr.contains('geräusch')) {
      category = EventCategory.noise;
    }

    if (trans != null &&
        trans.trim().isNotEmpty &&
        trans.toLowerCase() != 'null' &&
        trans.toLowerCase() != 'keine') {
      category = EventCategory.speech;
    }
    return category;
  }

  /// Extracts a WAV snippet with automatic digital Gain Boost ("Lauter-Machen" für Flüstern)
  Future<Uint8List?> _extractWavSnippetBytes({
    required AppFile wavFile,
    required int startMs,
    required int durationMs,
  }) async {
    final fileSize = await wavFile.length();
    if (fileSize <= 44) return null;

    final headerChunk = await wavFile.readRange(0, 256.clamp(0, fileSize));
    if (headerChunk.length < 44) return null;

    final bd = ByteData.sublistView(headerChunk);

    int numChannels = 1;
    int sampleRate = 16000;
    int bitsPerSample = 16;
    int dataOffset = 44;

    try {
      numChannels = bd.getUint16(22, Endian.little);
      sampleRate = bd.getUint32(24, Endian.little);
      bitsPerSample = bd.getUint16(34, Endian.little);
    } catch (_) {}

    for (int i = 12; i < headerChunk.length - 8; i++) {
      if (headerChunk[i] == 0x64 &&
          headerChunk[i + 1] == 0x61 &&
          headerChunk[i + 2] == 0x74 &&
          headerChunk[i + 3] == 0x61) {
        dataOffset = i + 8;
        break;
      }
    }

    final int bytesPerSample = (bitsPerSample / 8).round().clamp(1, 4);
    final int blockAlign = bytesPerSample * numChannels;
    final int bytesPerSec = sampleRate * blockAlign;

    final paddedStartMs = (startMs - 400).clamp(0, 86400000);
    final paddedDurMs = (durationMs + 800).clamp(800, 10000);

    int startByte = dataOffset + ((paddedStartMs / 1000.0) * bytesPerSec).round();
    startByte = dataOffset + (((startByte - dataOffset) ~/ blockAlign) * blockAlign);

    int lengthBytes = ((paddedDurMs / 1000.0) * bytesPerSec).round();
    lengthBytes = (lengthBytes ~/ blockAlign) * blockAlign;

    if (startByte >= fileSize) return null;

    final pcmData = await wavFile.readRange(startByte, lengthBytes);
    if (pcmData.isEmpty) return null;

    // --- Audio Gain Boost ("Lauter-Machen" für leises Flüstern & schwache Geräusche) ---
    Uint8List finalPcm = pcmData;
    if (bitsPerSample == 16 && pcmData.length >= 2) {
      final pcmBd = ByteData.sublistView(pcmData);
      final int numSamples = pcmData.length ~/ 2;
      int maxPeak = 0;
      for (int i = 0; i < numSamples; i++) {
        final val = pcmBd.getInt16(i * 2, Endian.little).abs();
        if (val > maxPeak) maxPeak = val;
      }

      // If audio is quiet (peak between -50 dBFS and -6 dBFS: 100 to 18000)
      if (maxPeak > 50 && maxPeak < 18000) {
        final double multiplier = (26000.0 / maxPeak).clamp(1.0, 16.0);
        final boostedBytes = Uint8List(pcmData.length);
        final boostedBd = ByteData.sublistView(boostedBytes);
        for (int i = 0; i < numSamples; i++) {
          final int raw = pcmBd.getInt16(i * 2, Endian.little);
          final int boosted = (raw * multiplier).round().clamp(-32768, 32767);
          boostedBd.setInt16(i * 2, boosted, Endian.little);
        }
        finalPcm = boostedBytes;
      }
    }

    final int pcmLength = finalPcm.length;

    // Build standard 44-byte WAV Header
    final header = Uint8List(44);
    final hbd = ByteData.sublistView(header);

    header.setRange(0, 4, [0x52, 0x49, 0x46, 0x46]); // "RIFF"
    hbd.setUint32(4, 36 + pcmLength, Endian.little);
    header.setRange(8, 12, [0x57, 0x41, 0x56, 0x45]); // "WAVE"
    header.setRange(12, 16, [0x66, 0x6D, 0x74, 0x20]); // "fmt "
    hbd.setUint32(16, 16, Endian.little);
    hbd.setUint16(20, 1, Endian.little);
    hbd.setUint16(22, numChannels, Endian.little);
    hbd.setUint32(24, sampleRate, Endian.little);
    hbd.setUint32(28, bytesPerSec, Endian.little);
    hbd.setUint16(32, bytesPerSample * numChannels, Endian.little);
    hbd.setUint16(34, bitsPerSample, Endian.little);
    header.setRange(36, 40, [0x64, 0x61, 0x74, 0x61]); // "data"
    hbd.setUint32(40, pcmLength, Endian.little);

    final wavSnippet = Uint8List(44 + pcmLength);
    wavSnippet.setRange(0, 44, header);
    wavSnippet.setRange(44, 44 + pcmLength, finalPcm);

    return wavSnippet;
  }
}
