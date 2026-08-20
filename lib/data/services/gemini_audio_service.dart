import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/models/detected_event.dart';
import 'logger_service.dart';
import 'platform_file/platform_file.dart';

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

class GeminiAudioService {
  static final GeminiAudioService _instance = GeminiAudioService._internal();
  factory GeminiAudioService() => _instance;
  GeminiAudioService._internal();

  final LoggerService _logger = LoggerService();

  static const String _prefApiKey = 'gemini_api_key';
  static const String _envApiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

  Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_prefApiKey);
    if (key != null && key.trim().isNotEmpty) {
      return key.trim();
    }
    return _envApiKey;
  }

  Future<void> saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefApiKey, key.trim());
  }

  /// Classifies a single audio event segment using Google Gemini Multimodal AI
  Future<GeminiAudioClassificationResult> classifyAudioSegment({
    required AppFile wavFile,
    required int startMs,
    required int durationMs,
  }) async {
    if (kIsWeb) {
      return const GeminiAudioClassificationResult(
        category: EventCategory.general,
        confidence: 0.5,
      );
    }

    try {
      final apiKey = await getApiKey();
      if (apiKey.isEmpty) {
        return const GeminiAudioClassificationResult(
          category: EventCategory.general,
          confidence: 0.5,
        );
      }

      // 1. Extract the audio snippet as WAV bytes
      final snippetBytes = await _extractWavSnippetBytes(
        wavFile: wavFile,
        startMs: startMs,
        durationMs: durationMs,
      );

      if (snippetBytes == null || snippetBytes.length <= 44) {
        return const GeminiAudioClassificationResult(
          category: EventCategory.noise,
          confidence: 0.7,
          explanation: 'Audiodatei war zu kurz oder leer',
        );
      }

      final base64Audio = base64Encode(snippetBytes);

      // Candidate models in priority order
      final candidateModels = [
        'gemini-3-flash-preview',
        'gemini-3.5-flash-lite',
        'gemini-3.1-flash-lite',
      ];

      const prompt = '''
Du bist ein hochentwickelter KI-Schlaflabor-Assistent. Höre dir dieses Audio-Snippet aus dem Schlafzimmer an und bestimme präzise, was zu hören ist.

Wähle die passendste category aus:
- "speech": Menschliches Sprechen, Schlafreden, Flüstern, Gemurmel, Worte, Sätze, Ausrufe. (Transkribiere unbedingt den Text!)
- "snore": Schnarchen, rasselndes/schweres Atmen, Seufzen, Keuchen.
- "movement": Bettdeckenrascheln, Umdrehen, Kissen bewegen, Bettgestell-Quietschen.
- "traffic": Vorbeifahrendes Auto, Motorrad, Bus, Sirene, Hupe, Flugzeug, Straßenlärm.
- "household": Türenschlagen, Türklinke, Schritte, Möbelknacken, Lichtschalter, Wasserrohre.
- "cough": Husten, Räuspern, Niesen, Schnauben.
- "pet": Hundebellen, Katzenmaunzen, Pfotengetrappel.
- "noise": Sonstige Hintergrundgeräusche, Stille oder Raumrauschen.

Antworte AUSSCHLIESSLICH als valides JSON-Objekt im folgenden Format:
{
  "category": "speech" | "snore" | "movement" | "traffic" | "household" | "cough" | "pet" | "noise",
  "subType": "Prägnanter Begriff auf Deutsch (z.B. 'Bettdeckenrascheln', 'Vorbeifahrendes Auto', 'Tiefes Schnarchen', 'Husten', 'Flüstern')",
  "emoji": "Ein passendes Emoji (z.B. 🗣️, 😴, 🛏️, 🚗, 🚪, 🤧, 🐾, 🔊)",
  "confidence": 0.95,
  "transcription": "Transkription der gesprochenen Wörter oder null wenn kein Sprechen",
  "explanation": "Ein kurzer, prägnanter deutscher Satz, was genau passiert ist."
}
''';

      for (final model in candidateModels) {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
        );

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
        );

        if (response.statusCode == 200) {
          final resJson = jsonDecode(response.body) as Map<String, dynamic>;
          final candidates = resJson['candidates'] as List<dynamic>?;
          if (candidates != null && candidates.isNotEmpty) {
            final content = candidates[0]['content'] as Map<String, dynamic>?;
            final parts = content?['parts'] as List<dynamic>?;
            if (parts != null && parts.isNotEmpty) {
              for (final part in parts) {
                final text = part['text'] as String?;
                if (text != null && text.isNotEmpty) {
                  final parsed = jsonDecode(text) as Map<String, dynamic>;
                  final catStr = (parsed['category'] as String? ?? 'general').toLowerCase().trim();
                  final conf = (parsed['confidence'] as num?)?.toDouble() ?? 0.85;
                  final trans = parsed['transcription'] as String?;
                  final subType = parsed['subType'] as String?;
                  final expl = parsed['explanation'] as String?;
                  final emoji = parsed['emoji'] as String?;

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

                  // If transcription words are detected, it is definitively speech
                  if (trans != null &&
                      trans.trim().isNotEmpty &&
                      trans.toLowerCase() != 'null' &&
                      trans.toLowerCase() != 'keine') {
                    category = EventCategory.speech;
                  }

                  _logger.log('Gemini ($model) Result for $startMs ms: $category ($conf) - "$subType" / "$trans" ($expl)');
                  return GeminiAudioClassificationResult(
                    category: category,
                    confidence: conf,
                    transcription: trans,
                    subType: subType,
                    explanation: expl,
                    dynamicEmoji: emoji,
                  );
                }
              }
            }
          }
        } else {
          _logger.log('Gemini ($model) Status: ${response.statusCode} - trying next model...');
        }
      }
    } catch (e) {
      _logger.log('GeminiAudioService Exception: ${e.toString().replaceAll(apiKey, '***')}');
    }

    return const GeminiAudioClassificationResult(
      category: EventCategory.general,
      confidence: 0.5,
    );
  }

  /// Extracts a WAV snippet (with standard 44-byte WAV header) using low-memory stream slicing
  Future<Uint8List?> _extractWavSnippetBytes({
    required AppFile wavFile,
    required int startMs,
    required int durationMs,
  }) async {
    final fileSize = await wavFile.length();
    if (fileSize <= 44) return null;

    // 1. Read first 256 bytes for header parsing
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

    // Find "data" chunk
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

    // Add 0.5s padding before and 1.5s after
    final paddedStartMs = (startMs - 500).clamp(0, 86400000);
    final paddedDurMs = (durationMs + 1500).clamp(1000, 10000); // 1s to 10s per snippet

    int startByte = dataOffset + ((paddedStartMs / 1000.0) * bytesPerSec).round();
    startByte = dataOffset + (((startByte - dataOffset) ~/ blockAlign) * blockAlign);

    int lengthBytes = ((paddedDurMs / 1000.0) * bytesPerSec).round();
    lengthBytes = (lengthBytes ~/ blockAlign) * blockAlign;

    if (startByte >= fileSize) return null;

    // 2. Read ONLY the requested audio segment bytes from disk directly
    final pcmData = await wavFile.readRange(startByte, lengthBytes);
    if (pcmData.isEmpty) return null;

    final int pcmLength = pcmData.length;

    // Build standard 44-byte WAV Header
    final header = Uint8List(44);
    final hbd = ByteData.sublistView(header);

    // "RIFF"
    header.setRange(0, 4, [0x52, 0x49, 0x46, 0x46]);
    hbd.setUint32(4, 36 + pcmLength, Endian.little);
    // "WAVE"
    header.setRange(8, 12, [0x57, 0x41, 0x56, 0x45]);
    // "fmt "
    header.setRange(12, 16, [0x66, 0x6D, 0x74, 0x20]);
    hbd.setUint32(16, 16, Endian.little); // subchunk1 size
    hbd.setUint16(20, 1, Endian.little); // PCM format
    hbd.setUint16(22, numChannels, Endian.little);
    hbd.setUint32(24, sampleRate, Endian.little);
    hbd.setUint32(28, bytesPerSec, Endian.little);
    hbd.setUint16(32, bytesPerSample * numChannels, Endian.little);
    hbd.setUint16(34, bitsPerSample, Endian.little);
    // "data"
    header.setRange(36, 40, [0x64, 0x61, 0x74, 0x61]);
    hbd.setUint32(40, pcmLength, Endian.little);

    final wavSnippet = Uint8List(44 + pcmLength);
    wavSnippet.setRange(0, 44, header);
    wavSnippet.setRange(44, 44 + pcmLength, pcmData);

    return wavSnippet;
  }
}
