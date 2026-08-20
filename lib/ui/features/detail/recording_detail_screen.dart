import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import '../../../data/repositories/recording_repository.dart';
import '../../../data/services/audio_trimmer_service.dart';
import '../../../data/services/gemini_audio_service.dart';
import '../../../data/services/platform_file/platform_file.dart';
import '../../../data/services/storage_service.dart';
import '../../../domain/models/detected_event.dart';
import '../../../domain/models/recording_session.dart';
import '../../core/theme.dart';

class RecordingDetailScreen extends StatefulWidget {
  final RecordingSession session;
  final RecordingRepository repository;

  const RecordingDetailScreen({
    super.key,
    required this.session,
    required this.repository,
  });

  @override
  State<RecordingDetailScreen> createState() => _RecordingDetailScreenState();
}

class _RecordingDetailScreenState extends State<RecordingDetailScreen> {
  late AudioPlayer _audioPlayer;
  late RecordingSession _currentSession;

  final AudioTrimmerService _trimmerService = AudioTrimmerService();
  final StorageService _storageService = StorageService();
  final ScrollController _waveformScrollController = ScrollController();
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(Duration.zero);

  double _thresholdDb = -38.0; // Gentle default ("unterdrückt lieber zu wenig als zu viel")
  bool _isNoiseFilterEnabled = true;
  bool _isPlaying = false;

  // Highlights Auto-Skip Playback state
  bool _isHighlightPlayback = false;
  int _currentHighlightIndex = 0;
  List<DetectedEvent> _highlightQueue = [];
  double _playbackSpeed = 1.0;

  // Selected event ID for glowing highlight & direct playback
  String? _selectedEventId;

  // Category filter: null (All), or specific EventCategory
  EventCategory? _selectedCategoryFilter;

  // Event List Filters (Duration & Min Decibel)
  double _minDurationFilterSec = 0.0;
  double _minDbFilter = -60.0;

  // Step-by-step zoom level (1x to 50x)
  double _zoomFactor = 1.0;

  // Snippet selection bounds (0.0 to 1.0 ratio of session)
  double _snippetStartRatio = 0.0;
  double _snippetEndRatio = 0.25;

  bool _isExporting = false;
  Timer? _thresholdDebounceTimer;

  Future<void> _runAIAnalysis() async {
    if (_currentSession.detectedEvents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keine Geräusch-Events zum Analysieren vorhanden.')),
      );
      return;
    }

    double currentProgress = 0.05;
    String currentStatus = 'Initialisiere KI-Audio-Analyse...';
    StateSetter? dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            dialogSetState = setModalState;
            final percent = (currentProgress * 100).toInt().clamp(0, 100);
            return AlertDialog(
              backgroundColor: AppTheme.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Row(
                children: [
                  Icon(Icons.auto_awesome, color: Color(0xFFFBBF24)),
                  SizedBox(width: 10),
                  Text('KI-Geräusch-Analyse', style: TextStyle(fontSize: 18)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    currentStatus,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: currentProgress,
                      minHeight: 8,
                      backgroundColor: AppTheme.surfaceLight,
                      color: const Color(0xFFFBBF24),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '$percent %',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFFBBF24),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    try {
      final updatedSession = await widget.repository.classifySessionWithAI(
        _currentSession,
        onProgress: (ratio, text) {
          currentProgress = ratio;
          currentStatus = text;
          dialogSetState?.call(() {});
        },
      );

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // Close dialog
        setState(() {
          _currentSession = updatedSession;
        });

        final speechCount = updatedSession.detectedEvents.where((e) => e.isSpeech).length;
        final snoreCount = updatedSession.detectedEvents.where((e) => e.isSnore).length;
        final noiseCount = updatedSession.detectedEvents.where((e) => e.isNoise).length;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✨ Analyse fertig: $speechCount× Schlafreden 🗣️, $snoreCount× Schnarchen 😴, $noiseCount× Nebengeräusche 🚗',
            ),
            backgroundColor: const Color(0xFF065F46),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler bei der KI-Analyse: $e')),
        );
      }
    }
  }

  Future<void> _showApiKeyDialog() async {
    final geminiService = GeminiAudioService();
    final currentKey = await geminiService.getApiKey();
    final controller = TextEditingController(text: currentKey);

    if (!mounted) return;
    bool obscureKey = true;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: AppTheme.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Row(
                children: [
                  Icon(Icons.shield_outlined, color: Color(0xFF10B981)),
                  SizedBox(width: 10),
                  Text('Google Gemini API-Key', style: TextStyle(fontSize: 18)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Dein persönlicher kostenloser Google AI Studio API-Key für die multimodale Audio-Analyse.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.lock_outline, size: 14, color: Color(0xFF34D399)),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '100% lokal & privat auf deinem Smartphone gesichert.',
                            style: TextStyle(fontSize: 11, color: Color(0xFF34D399), fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    obscureText: obscureKey,
                    decoration: InputDecoration(
                      labelText: 'API-Key',
                      hintText: 'Hier API-Key einfügen...',
                      filled: true,
                      fillColor: AppTheme.surfaceLight,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      suffixIcon: IconButton(
                        icon: Icon(obscureKey ? Icons.visibility_off : Icons.visibility, color: Colors.white70, size: 20),
                        onPressed: () {
                          setDialogState(() {
                            obscureKey = !obscureKey;
                          });
                        },
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Abbrechen'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await geminiService.saveApiKey(controller.text);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ Gemini API-Key lokal & sicher gespeichert!'),
                          backgroundColor: Color(0xFF10B981),
                        ),
                      );
                    }
                  },
                  child: const Text('Speichern'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _currentSession = widget.session;
    _audioPlayer = AudioPlayer();

    _initAudioPlayer();
  }

  Future<void> _initAudioPlayer() async {
    try {
      final path = _currentSession.filePath;
      if (path.startsWith('assets/') || path.startsWith('asset://')) {
        final clean = path.replaceFirst('asset://', '');
        await _audioPlayer.setAsset(clean);
      } else if (kIsWeb) {
        if (path.startsWith('blob:') || path.startsWith('http://') || path.startsWith('https://')) {
          await _audioPlayer.setUrl(path);
        } else {
          await _audioPlayer.setAsset('assets/audio/demo_sleep.wav');
        }
      } else {
        final file = AppFile(path);
        if (await file.exists()) {
          await _audioPlayer.setFilePath(path);
        }
      }
    } catch (e) {
      debugPrint('AudioPlayer init error: $e');
    }

    _audioPlayer.positionStream.listen((pos) {
      _positionNotifier.value = pos;
      if (_isHighlightPlayback && _currentHighlightIndex < _highlightQueue.length) {
        final currentEv = _highlightQueue[_currentHighlightIndex];
        final endTarget = currentEv.startOffset + currentEv.duration + const Duration(milliseconds: 350);
        if (pos >= endTarget) {
          _playNextHighlight();
        }
      }
    });

    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        final playing = state.playing && state.processingState != ProcessingState.completed;
        if (_isPlaying != playing) {
          setState(() {
            _isPlaying = playing;
          });
        }
      }
    });
  }

  Future<void> _startHighlightPlayback(List<DetectedEvent> events) async {
    if (events.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keine Geräusche zum Abspielen vorhanden.')),
      );
      return;
    }
    _highlightQueue = List.from(events);
    _isHighlightPlayback = true;
    _currentHighlightIndex = 0;
    await _playHighlightAt(0);
  }

  Future<void> _playHighlightAt(int index) async {
    if (index >= _highlightQueue.length) {
      await _stopHighlightPlayback();
      return;
    }
    _currentHighlightIndex = index;
    final ev = _highlightQueue[index];
    _selectedEventId = ev.id;
    await _audioPlayer.setSpeed(_playbackSpeed);
    await _audioPlayer.seek(ev.startOffset);
    await _audioPlayer.play();
    if (mounted) setState(() {});
  }

  Future<void> _playNextHighlight() async {
    await _playHighlightAt(_currentHighlightIndex + 1);
  }

  Future<void> _stopHighlightPlayback() async {
    _isHighlightPlayback = false;
    await _audioPlayer.pause();
    if (mounted) setState(() {});
  }

  Future<void> _togglePlaybackSpeed() async {
    final speeds = [1.0, 1.25, 1.5, 2.0];
    final nextIdx = (speeds.indexOf(_playbackSpeed) + 1) % speeds.length;
    _playbackSpeed = speeds[nextIdx];
    await _audioPlayer.setSpeed(_playbackSpeed);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _thresholdDebounceTimer?.cancel();
    _audioPlayer.dispose();
    _waveformScrollController.dispose();
    _positionNotifier.dispose();
    super.dispose();
  }

  void _zoomIn() {
    if (_zoomFactor < 50.0) {
      setState(() {
        _zoomFactor += 1.0;
      });
    }
  }

  void _zoomOut() {
    if (_zoomFactor > 1.0) {
      setState(() {
        _zoomFactor -= 1.0;
      });
    }
  }

  void _onThresholdChanged(double val) {
    setState(() {
      _thresholdDb = val;
      _isNoiseFilterEnabled = true;
    });
    _debounceThresholdUpdate(val);
  }

  void _autoCalibrateNoiseFloor() {
    final noiseDb = _currentSession.estimateNoiseFloorDb();
    final newThreshold = (noiseDb + 1.0).clamp(-75.0, -10.0);
    _onThresholdChanged(newThreshold);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '🪄 Grundrauschen gemessen (${noiseDb.toStringAsFixed(1)} dB) ➔ Filter auf ${newThreshold.toStringAsFixed(1)} dB (+1 dB) gesetzt!',
        ),
        backgroundColor: const Color(0xFF10B981),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _calibrateNoiseAtCurrentPosition() {
    final currentPos = _positionNotifier.value;
    final noiseDb = _currentSession.measureNoiseAtTime(currentPos);
    final newThreshold = (noiseDb + 1.0).clamp(-75.0, -10.0);
    _onThresholdChanged(newThreshold);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '🎯 Rauschen bei ${_formatDuration(currentPos)} gemessen (${noiseDb.toStringAsFixed(1)} dB) ➔ Filter auf ${newThreshold.toStringAsFixed(1)} dB (+1 dB) gesetzt!',
        ),
        backgroundColor: const Color(0xFF0284C7),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _toggleNoiseFilter(bool enabled) {
    setState(() {
      _isNoiseFilterEnabled = enabled;
      _thresholdDb = enabled ? -38.0 : -60.0;
    });
    _debounceThresholdUpdate(_thresholdDb);
  }

  void _debounceThresholdUpdate(double val) {
    _thresholdDebounceTimer?.cancel();
    _thresholdDebounceTimer = Timer(const Duration(milliseconds: 150), () {
      _applyThresholdUpdate(val);
    });
  }

  Future<void> _applyThresholdUpdate(double val) async {
    await widget.repository.updateSessionEvents(_currentSession.id, val);
    if (mounted) {
      final idx = widget.repository.sessions.indexWhere((s) => s.id == _currentSession.id);
      if (idx != -1) {
        setState(() {
          _currentSession = widget.repository.sessions[idx];
        });
      }
    }
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      if (_audioPlayer.processingState == ProcessingState.completed) {
        await _audioPlayer.seek(Duration.zero);
      }
      await _audioPlayer.play();
    }
  }

  Future<void> _seekTo(Duration target) async {
    _positionNotifier.value = target;
    await _audioPlayer.seek(target);
  }

  void _selectAndPlayEvent(DetectedEvent event) async {
    setState(() {
      _selectedEventId = event.id;
    });

    _selectSnippetForEvent(event);
    await _audioPlayer.play();
  }

  void _selectSnippetForEvent(DetectedEvent event) {
    if (_currentSession.duration.inMilliseconds == 0) return;

    final totalMs = _currentSession.duration.inMilliseconds.toDouble();
    // Add 2 sec padding before and after event
    final startMs = (event.startOffset.inMilliseconds - 2000).clamp(0, totalMs.toInt());
    final endMs = (event.startOffset.inMilliseconds + event.duration.inMilliseconds + 2000)
        .clamp(startMs, totalMs.toInt());

    setState(() {
      _snippetStartRatio = startMs / totalMs;
      _snippetEndRatio = endMs / totalMs;
    });

    _seekTo(Duration(milliseconds: startMs));

    // Scroll waveform view to center on this event if zoomed
    if (_waveformScrollController.hasClients && _zoomFactor > 1.0) {
      final maxScroll = _waveformScrollController.position.maxScrollExtent;
      final targetScroll = (startMs / totalMs) * maxScroll;
      _waveformScrollController.animateTo(
        targetScroll.clamp(0.0, maxScroll),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _jumpToNextEvent({bool forward = true}) {
    final events = _getFilteredEvents();
    if (events.isEmpty) return;

    final currentMs = _positionNotifier.value.inMilliseconds;

    DetectedEvent? targetEvent;
    if (forward) {
      targetEvent = events.firstWhere(
        (e) => e.startOffset.inMilliseconds > currentMs + 500,
        orElse: () => events.first,
      );
    } else {
      targetEvent = events.lastWhere(
        (e) => e.startOffset.inMilliseconds < currentMs - 500,
        orElse: () => events.last,
      );
    }

    _selectAndPlayEvent(targetEvent);
  }

  List<DetectedEvent> _getFilteredEvents() {
    return _currentSession.detectedEvents.where((e) {
      if (_selectedCategoryFilter != null && e.category != _selectedCategoryFilter) {
        return false;
      }
      final durationSec = e.duration.inMilliseconds / 1000.0;
      final passesDuration = durationSec >= _minDurationFilterSec;
      final passesDb = e.maxDb >= _minDbFilter;
      return passesDuration && passesDb;
    }).toList();
  }

  Future<void> _shareSpecificEvent(DetectedEvent event) async {
    final totalMs = _currentSession.duration.inMilliseconds.toDouble();
    final startMs = (event.startOffset.inMilliseconds - 2000).clamp(0, totalMs.toInt());
    final endMs = (event.startOffset.inMilliseconds + event.duration.inMilliseconds + 2000)
        .clamp(startMs, totalMs.toInt());
    final snippetDuration = Duration(milliseconds: endMs - startMs);

    await _performShare(startMs: startMs, snippetDuration: snippetDuration);
  }

  Future<void> _shareSnippet() async {
    if (_currentSession.duration.inMilliseconds == 0) return;

    final totalMs = _currentSession.duration.inMilliseconds;
    final startMs = (_snippetStartRatio * totalMs).round();
    final endMs = (_snippetEndRatio * totalMs).round();
    final snippetDuration = Duration(milliseconds: endMs - startMs);

    await _performShare(startMs: startMs, snippetDuration: snippetDuration);
  }

  Future<void> _performShare({required int startMs, required Duration snippetDuration}) async {
    if (snippetDuration.inMilliseconds < 300) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ausschnitt zu kurz (mindestens 0.3s wählen)')),
      );
      return;
    }

    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Audio-Schnipsel-Export ist in der Android/iOS App verfügbar.')),
      );
      return;
    }

    setState(() => _isExporting = true);

    try {
      final snippetPath = await _storageService.generateSnippetFilePath('${DateTime.now().millisecondsSinceEpoch}');
      final inputFile = AppFile(_currentSession.filePath);
      final outputFile = AppFile(snippetPath);

      final trimmedFile = await _trimmerService.trimAudioSnippet(
        inputFile: inputFile,
        outputFile: outputFile,
        startOffset: Duration(milliseconds: startMs),
        duration: snippetDuration,
      );

      if (await trimmedFile.exists()) {
        // Open native Android Share Sheet with audio/mp4 mimeType for 100% WhatsApp audio compatibility
        await Share.shareXFiles(
          [XFile(trimmedFile.path, mimeType: 'audio/mp4')],
          text: 'Hör dir dieses Schlafschnipsel an! 🌙😴',
          subject: 'Schlaf-Aufnahme Schnipsel',
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fehler beim Exportieren des Audioschnipsels.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export Fehler: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalDuration = _currentSession.duration;
    final startMs = (_snippetStartRatio * totalDuration.inMilliseconds).round();
    final endMs = (_snippetEndRatio * totalDuration.inMilliseconds).round();
    final filteredEvents = _getFilteredEvents();

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentSession.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: Color(0xFFFBBF24)),
            tooltip: 'Mit KI analysieren (Schlafreden & Geräusche)',
            onPressed: _runAIAnalysis,
          ),
          IconButton(
            icon: const Icon(Icons.file_upload_outlined, color: AppTheme.primary),
            tooltip: 'Ganze Aufnahme als WAV exportieren',
            onPressed: () async {
              if (kIsWeb) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Export ist auf dem Smartphone verfügbar.')),
                );
                return;
              }
              final file = AppFile(_currentSession.filePath);
              if (await file.exists()) {
                await Share.shareXFiles(
                  [XFile(_currentSession.filePath, mimeType: 'audio/wav', name: '${_currentSession.id}.wav')],
                  text: 'SleepSpeak Aufnahme: ${_currentSession.title}',
                );
              }
            },
          ),
          IconButton(
            icon: Icon(
              _currentSession.isFavorite ? Icons.star : Icons.star_border,
              color: _currentSession.isFavorite ? Colors.amber : Colors.white,
            ),
            onPressed: () async {
              await widget.repository.toggleFavorite(_currentSession.id);
              setState(() {
                _currentSession = _currentSession.copyWith(isFavorite: !_currentSession.isFavorite);
              });
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Waveform Amplitude Visualizer Card (Lag-Free Engine with Magnifying Glass Zoom Controls)
            _buildWaveformCard(),
            const SizedBox(height: 14),

            // AI Noise & Speech Classifier Banner (with Category Summary Tags)
            _buildAIAnalysisBanner(),
            const SizedBox(height: 14),

            // Highlights Auto-Skip Player Bar (Play all noises/speech with auto silence-skipping)
            _buildHighlightPlayerBar(filteredEvents),
            const SizedBox(height: 16),

            // Events List Header & Category Filter Chips
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Erkannte Geräusche',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                ),
                Chip(
                  label: Text(
                    '${filteredEvents.length} / ${_currentSession.detectedEvents.length} Events',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Category Filter Chips (Dynamic emojis & category filters)
            _buildCategoryFilterChips(),
            const SizedBox(height: 14),

            // Events List (Main focus of the screen)
            if (filteredEvents.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.nightlight_round, size: 36, color: AppTheme.textSecondary),
                    SizedBox(height: 8),
                    Text(
                      'Keine Geräusche für die gewählten Filter vorhanden.',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: filteredEvents.length,
                itemBuilder: (context, index) {
                  final event = filteredEvents[index];
                  return _buildEventItem(event);
                },
              ),

            const SizedBox(height: 24),

            // Expandable Technical Tools (Noise Suppression Sliders, Snippet Export, Fine-tuning)
            _buildAdvancedToolsAccordion(startMs, endMs, filteredEvents.length),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildAdvancedToolsAccordion(int startMs, int endMs, int filteredCount) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.surfaceLight),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          leading: const Icon(Icons.tune, color: AppTheme.accent),
          title: const Text(
            'Erweiterte Werkzeuge & Filter',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: const Text(
            'Schwellenwert-Filter, dB-Regler & WhatsApp Zuschnitt',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
          childrenPadding: const EdgeInsets.all(12),
          children: [
            _buildThresholdCard(),
            const SizedBox(height: 12),
            _buildSnippetShareCard(startMs, endMs),
            const SizedBox(height: 12),
            _buildEventFilterCard(filteredCount),
          ],
        ),
      ),
    );
  }

  Widget _buildWaveformCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.surfaceLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Row(
                  children: [
                    Icon(Icons.multitrack_audio, color: AppTheme.primary),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Lautstärke-Verlauf',
                        style: TextStyle(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                    size: 36, color: AppTheme.primary),
                onPressed: _togglePlayback,
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Zoom & Quick Peak Navigator Controls Row
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              // Previous / Next Peak Jump buttons
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _jumpToNextEvent(forward: false),
                    icon: const Icon(Icons.skip_previous, size: 16),
                    label: const Text('Vorheriges', style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: () => _jumpToNextEvent(forward: true),
                    icon: const Icon(Icons.skip_next, size: 16),
                    label: const Text('Nächstes', style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),

              // Zoom In / Zoom Out Magnifying Glass Buttons (1x to 50x)
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.zoom_out, size: 20),
                      color: _zoomFactor > 1.0 ? AppTheme.primaryGlow : AppTheme.textSecondary,
                      tooltip: 'Herauszoomen',
                      visualDensity: VisualDensity.compact,
                      onPressed: _zoomFactor > 1.0 ? _zoomOut : null,
                    ),
                    Text(
                      '${_zoomFactor.toInt()}x Zoom',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white),
                    ),
                    IconButton(
                      icon: const Icon(Icons.zoom_in, size: 20),
                      color: _zoomFactor < 50.0 ? AppTheme.primaryGlow : AppTheme.textSecondary,
                      tooltip: 'Hineinzoomen',
                      visualDensity: VisualDensity.compact,
                      onPressed: _zoomFactor < 50.0 ? _zoomIn : null,
                    ),
                  ],
                ),
              ),

              // Quick 1-Click Noise Floor Calibrate (+1 dB) Button
              OutlinedButton.icon(
                onPressed: _autoCalibrateNoiseFloor,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF34D399),
                  side: const BorderSide(color: Color(0xFF059669)),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.auto_fix_high, size: 14, color: Color(0xFF34D399)),
                label: const Text('🪄 Rauschen filtern', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Scrollable Waveform Painter widget with Magnifying Glass Zoom support & zero-lag performance
          LayoutBuilder(
            builder: (context, constraints) {
              final baseWidth = constraints.maxWidth;
              final canvasWidth = baseWidth * _zoomFactor;

              return SingleChildScrollView(
                controller: _waveformScrollController,
                scrollDirection: Axis.horizontal,
                child: GestureDetector(
                  onTapDown: (details) {
                    if (_currentSession.duration.inMilliseconds > 0) {
                      final ratio = (details.localPosition.dx / canvasWidth).clamp(0.0, 1.0);
                      final seekMs = (ratio * _currentSession.duration.inMilliseconds).round();
                      _seekTo(Duration(milliseconds: seekMs));
                    }
                  },
                  child: SizedBox(
                    height: 130,
                    width: canvasWidth,
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: _positionNotifier,
                      builder: (context, pos, _) {
                        return CustomPaint(
                          painter: WaveformPainter(
                            amplitudeHistory: _currentSession.amplitudeHistory,
                            thresholdDb: _thresholdDb,
                            isNoiseFilterEnabled: _isNoiseFilterEnabled,
                            currentPositionRatio: _currentSession.duration.inMilliseconds > 0
                                ? pos.inMilliseconds / _currentSession.duration.inMilliseconds
                                : 0.0,
                            snippetStartRatio: _snippetStartRatio,
                            snippetEndRatio: _snippetEndRatio,
                            sessionStartTime: _currentSession.startTime,
                            sessionDuration: _currentSession.duration,
                            zoomFactor: _zoomFactor,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),

          // Time Position Indicators Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ValueListenableBuilder<Duration>(
                valueListenable: _positionNotifier,
                builder: (context, pos, _) {
                  return Text(
                    'Position: ${_formatDuration(pos)}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.primaryGlow, fontWeight: FontWeight.bold),
                  );
                },
              ),
              Text(
                'Gesamt: ${_formatDuration(_currentSession.duration)}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildThresholdCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.surfaceLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Row(
                  children: [
                    Icon(Icons.tune, color: AppTheme.accent),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Geräuschunterdrückung',
                        style: TextStyle(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

              // Checkbox to turn off noise suppression completely
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Aktiv', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  Switch(
                    value: _isNoiseFilterEnabled,
                    activeThumbColor: AppTheme.accent,
                    onChanged: _toggleNoiseFilter,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _isNoiseFilterEnabled
                ? 'Unterdrückt leises Hintergrundrauschen. Empfohlen: (-42 dB bis -35 dB).'
                : '❌ Filter ausgeschaltet: Zeigt JEDES Geräusch, Raunen und Flüstern der Nacht ungefiltert an (-60 dB).',
            style: TextStyle(
              fontSize: 12,
              color: _isNoiseFilterEnabled ? AppTheme.textSecondary : Colors.amber,
            ),
          ),
          if (_isNoiseFilterEnabled) ...[
            const SizedBox(height: 12),

            // Smart Noise Floor Calibration Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _autoCalibrateNoiseFloor,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF065F46),
                      foregroundColor: const Color(0xFF34D399),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.auto_fix_high, size: 16),
                    label: const Text(
                      '🪄 Auto-Kalibrieren',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _calibrateNoiseAtCurrentPosition,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF38BDF8),
                      side: const BorderSide(color: Color(0xFF0284C7)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.my_location, size: 16),
                    label: const Text(
                      '🎯 Hier messen',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.surfaceLight.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: Color(0xFF38BDF8)),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Misst das Raumrauschen und setzt den Filter exakt 1 dB darüber (+1 dB), sodass das Hintergrundrauschen komplett ausgegraut wird.',
                      style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Empfindlich (-75 dB)', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                Expanded(
                  child: Slider(
                    value: _thresholdDb.clamp(-75.0, -10.0),
                    min: -75.0,
                    max: -10.0,
                    divisions: 65,
                    activeColor: AppTheme.accent,
                    label: '${_thresholdDb.toStringAsFixed(1)} dB',
                    onChanged: _onThresholdChanged,
                  ),
                ),
                const Text('Streng (-10 dB)', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
              ],
            ),
            Center(
              child: Text(
                'Aktueller Filter: ${_thresholdDb.toStringAsFixed(1)} dB (alles darunter wird ausgegraut)',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.primaryGlow),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSnippetShareCard(int startMs, int endMs) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.surface, const Color(0xFF1E1B4B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.content_cut, color: AppTheme.primaryGlow),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Audioschnipsel auswählen & teilen',
                  style: TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Range Slider for start & end snippet selection
          RangeSlider(
            values: RangeValues(_snippetStartRatio, _snippetEndRatio),
            activeColor: AppTheme.primaryGlow,
            inactiveColor: AppTheme.surfaceLight,
            onChanged: (RangeValues vals) {
              setState(() {
                _snippetStartRatio = vals.start;
                _snippetEndRatio = vals.end;
              });
            },
          ),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Start: ${_formatDuration(Duration(milliseconds: startMs))}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              Text(
                'Ende: ${_formatDuration(Duration(milliseconds: endMs))}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Buttons row: Preview snippet & Share via WhatsApp
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _seekTo(Duration(milliseconds: startMs)),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Anhören', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: AppTheme.primary),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isExporting ? null : _shareSnippet,
                  icon: _isExporting
                      ? const SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.share, size: 18),
                  label: Text(_isExporting ? 'Export...' : 'Teilen (WhatsApp)',
                      style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    backgroundColor: const Color(0xFF25D366), // WhatsApp Green
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEventFilterCard(int count) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.surfaceLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.filter_list, color: AppTheme.primaryGlow, size: 20),
              const SizedBox(width: 8),
              const Text('Geräusche filtern (nach Dauer & Dezibel)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const Spacer(),
              if (_minDurationFilterSec > 0 || _minDbFilter > -60.0)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _minDurationFilterSec = 0.0;
                      _minDbFilter = -60.0;
                    });
                  },
                  child: const Text('Zurücksetzen', style: TextStyle(fontSize: 11, color: Colors.amber)),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Filter by Duration Slider (0s to 5s)
          Row(
            children: [
              Text(
                'Mindest-Dauer: ${_minDurationFilterSec.toStringAsFixed(1)}s',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
              Expanded(
                child: Slider(
                  value: _minDurationFilterSec,
                  min: 0.0,
                  max: 5.0,
                  divisions: 50,
                  activeColor: AppTheme.primary,
                  onChanged: (v) {
                    setState(() {
                      _minDurationFilterSec = v;
                    });
                  },
                ),
              ),
            ],
          ),

          // Filter by Min Decibel Slider (-75 dB to -20 dB)
          Row(
            children: [
              Text(
                'Mindest-Lautstärke: ${_minDbFilter.toStringAsFixed(1)} dB',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
              Expanded(
                child: Slider(
                  value: _minDbFilter.clamp(-75.0, -20.0),
                  min: -75.0,
                  max: -20.0,
                  divisions: 55,
                  activeColor: AppTheme.primaryGlow,
                  onChanged: (v) {
                    setState(() {
                      _minDbFilter = v;
                    });
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getCategoryColor(EventCategory category) {
    switch (category) {
      case EventCategory.speech:
        return const Color(0xFF10B981); // Emerald
      case EventCategory.snore:
        return const Color(0xFF8B5CF6); // Purple
      case EventCategory.movement:
        return const Color(0xFF3B82F6); // Blue
      case EventCategory.traffic:
        return const Color(0xFFF97316); // Orange
      case EventCategory.household:
        return const Color(0xFFEAB308); // Yellow
      case EventCategory.cough:
        return const Color(0xFFEC4899); // Pink
      case EventCategory.pet:
        return const Color(0xFF14B8A6); // Teal
      case EventCategory.noise:
        return const Color(0xFF64748B); // Slate
      case EventCategory.general:
        return AppTheme.primary; // Indigo
    }
  }

  String _getCategoryLabel(EventCategory category) {
    switch (category) {
      case EventCategory.speech:
        return 'Schlafreden';
      case EventCategory.snore:
        return 'Schnarchen';
      case EventCategory.movement:
        return 'Bett & Bewegung';
      case EventCategory.traffic:
        return 'Verkehr';
      case EventCategory.household:
        return 'Haushalt & Türen';
      case EventCategory.cough:
        return 'Husten & Niesen';
      case EventCategory.pet:
        return 'Haustiere';
      case EventCategory.noise:
        return 'Nebengeräusch';
      case EventCategory.general:
        return 'Geräusch';
    }
  }

  String _getCategoryEmoji(EventCategory category) {
    switch (category) {
      case EventCategory.speech:
        return '🗣️';
      case EventCategory.snore:
        return '😴';
      case EventCategory.movement:
        return '🛏️';
      case EventCategory.traffic:
        return '🚗';
      case EventCategory.household:
        return '🚪';
      case EventCategory.cough:
        return '🤧';
      case EventCategory.pet:
        return '🐾';
      case EventCategory.noise:
        return '🔊';
      case EventCategory.general:
        return '🔊';
    }
  }

  Widget _buildAIAnalysisBanner() {
    final Map<EventCategory, int> counts = {};
    for (final e in _currentSession.detectedEvents) {
      counts[e.category] = (counts[e.category] ?? 0) + 1;
    }

    final hasClassifiedEvents = counts.keys.any((k) => k != EventCategory.general);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E1B4B), Color(0xFF312E81)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFBBF24).withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFBBF24).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.auto_awesome, color: Color(0xFFFBBF24), size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'KI-Geräuscherkennung',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                    ),
                    Text(
                      'Erkennt Sprache, Schnarchen, Bett, Autos & mehr',
                      style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.key, color: Color(0xFFFBBF24), size: 18),
                tooltip: 'Google Gemini API-Key anpassen',
                onPressed: _showApiKeyDialog,
              ),
              const SizedBox(width: 4),
              ElevatedButton.icon(
                onPressed: _runAIAnalysis,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFBBF24),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.bolt, size: 16),
                label: const Text('KI-Analyse', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ],
          ),
          if (hasClassifiedEvents) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cat in EventCategory.values)
                  if ((counts[cat] ?? 0) > 0)
                    _buildCountTag(
                      '${cat == EventCategory.general ? "🔊" : _getCategoryEmoji(cat)} ${counts[cat]}× ${cat == EventCategory.general ? "Ungeprüft" : _getCategoryLabel(cat)}',
                      _getCategoryColor(cat),
                    ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCountTag(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: bg.withValues(alpha: 0.6)),
      ),
      child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white)),
    );
  }

  Widget _buildCategoryFilterChips() {
    final Map<EventCategory, int> counts = {};
    for (final e in _currentSession.detectedEvents) {
      counts[e.category] = (counts[e.category] ?? 0) + 1;
    }

    final activeCategories = EventCategory.values.where((cat) => (counts[cat] ?? 0) > 0).toList();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildFilterChip(
            label: 'Alle (${_currentSession.detectedEvents.length})',
            isSelected: _selectedCategoryFilter == null,
            onSelected: () => setState(() => _selectedCategoryFilter = null),
            activeColor: AppTheme.primary,
          ),
          for (final cat in activeCategories) ...[
            const SizedBox(width: 8),
            _buildFilterChip(
              label: '${_getCategoryEmoji(cat)} ${_getCategoryLabel(cat)} (${counts[cat]})',
              isSelected: _selectedCategoryFilter == cat,
              onSelected: () => setState(() => _selectedCategoryFilter = cat),
              activeColor: _getCategoryColor(cat),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onSelected,
    required Color activeColor,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelected(),
      selectedColor: activeColor.withValues(alpha: 0.3),
      backgroundColor: AppTheme.surface,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        color: isSelected ? Colors.white : AppTheme.textSecondary,
      ),
      side: BorderSide(color: isSelected ? activeColor : AppTheme.surfaceLight),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }

  Widget _buildHighlightPlayerBar(List<DetectedEvent> events) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _isHighlightPlayback
              ? [const Color(0xFF065F46), const Color(0xFF047857)]
              : [AppTheme.surface, const Color(0xFF1E1B4B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _isHighlightPlayback ? const Color(0xFF10B981) : AppTheme.primary.withValues(alpha: 0.3),
          width: _isHighlightPlayback ? 2.0 : 1.0,
        ),
      ),
      child: Row(
        children: [
          ElevatedButton.icon(
            onPressed: () {
              if (_isHighlightPlayback) {
                _stopHighlightPlayback();
              } else {
                _startHighlightPlayback(events);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _isHighlightPlayback ? Colors.amber : const Color(0xFF10B981),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: Icon(_isHighlightPlayback ? Icons.stop : Icons.play_arrow, size: 20),
            label: Text(
              _isHighlightPlayback ? 'Stopp' : 'Highlights abspielen',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isHighlightPlayback
                      ? 'Highlight ${_currentHighlightIndex + 1} von ${_highlightQueue.length}'
                      : 'Stille überspringen',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _isHighlightPlayback
                      ? 'Spielt alle Geräusche nacheinander'
                      : '${events.length} Geräusche ohne Wartezeit',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _togglePlaybackSpeed,
            style: TextButton.styleFrom(
              backgroundColor: AppTheme.surfaceLight,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(
              '${_playbackSpeed}x',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleEventFavorite(DetectedEvent event) async {
    await widget.repository.toggleEventFavorite(_currentSession.id, event.id);
    final updatedEvents = _currentSession.detectedEvents.map((e) {
      if (e.id == event.id) {
        return e.copyWith(isFavorite: !e.isFavorite);
      }
      return e;
    }).toList();
    setState(() {
      _currentSession = _currentSession.copyWith(detectedEvents: updatedEvents);
    });
  }

  Future<void> _removeTagFromEvent(DetectedEvent event, String tag) async {
    final updatedTags = List<String>.from(event.tags)..remove(tag);
    await widget.repository.updateEventTags(_currentSession.id, event.id, updatedTags);
    final updatedEvents = _currentSession.detectedEvents.map((e) {
      if (e.id == event.id) {
        return e.copyWith(tags: updatedTags);
      }
      return e;
    }).toList();
    setState(() {
      _currentSession = _currentSession.copyWith(detectedEvents: updatedEvents);
    });
  }

  void _showEventTagDialog(DetectedEvent event) {
    final textController = TextEditingController();
    final currentTags = List<String>.from(event.tags);
    final presetTags = ['⭐ Favorit', '🤣 Lustig', '🔒 Behalten', '👻 Gruselig', '💬 Schlafreden', '🤔 Unverständlich'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(modalCtx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.label, color: Color(0xFF38BDF8)),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Clip taggen & schützen',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Getaggte Clips werden nie nach 7 Tagen gelöscht',
                              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  const Text('Vorschläge:', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: presetTags.map((tag) {
                      final isSelected = currentTags.contains(tag);
                      return FilterChip(
                        label: Text(tag),
                        selected: isSelected,
                        selectedColor: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                        onSelected: (selected) {
                          setModalState(() {
                            if (selected) {
                              if (!currentTags.contains(tag)) currentTags.add(tag);
                            } else {
                              currentTags.remove(tag);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),

                  TextField(
                    controller: textController,
                    decoration: InputDecoration(
                      hintText: 'Eigenen Tag eingeben...',
                      hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                      filled: true,
                      fillColor: AppTheme.surfaceLight,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.add, color: Color(0xFF38BDF8)),
                        onPressed: () {
                          final text = textController.text.trim();
                          if (text.isNotEmpty && !currentTags.contains(text)) {
                            setModalState(() {
                              currentTags.add(text);
                            });
                            textController.clear();
                          }
                        },
                      ),
                    ),
                    onSubmitted: (text) {
                      final val = text.trim();
                      if (val.isNotEmpty && !currentTags.contains(val)) {
                        setModalState(() {
                          currentTags.add(val);
                        });
                        textController.clear();
                      }
                    },
                  ),
                  const SizedBox(height: 20),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await widget.repository.updateEventTags(_currentSession.id, event.id, currentTags);
                        final updatedEvents = _currentSession.detectedEvents.map((e) {
                          if (e.id == event.id) {
                            return e.copyWith(tags: currentTags);
                          }
                          return e;
                        }).toList();
                        setState(() {
                          _currentSession = _currentSession.copyWith(detectedEvents: updatedEvents);
                        });
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('🛡️ Tags gespeichert! Dieser Clip ist vor der 7-Tage-Löschung geschützt.'),
                              backgroundColor: Color(0xFF10B981),
                            ),
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF38BDF8),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Speichern & Schützen', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEventItem(DetectedEvent event) {
    final isSelected = (_selectedEventId == event.id);
    final categoryColor = _getCategoryColor(event.category);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isSelected ? AppTheme.primaryGlow : categoryColor.withValues(alpha: 0.35),
          width: isSelected ? 2.5 : 1.0,
        ),
      ),
      color: isSelected ? const Color(0xFF1E1B4B) : AppTheme.surface,
      elevation: isSelected ? 4 : 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Play Avatar, Time & Category Badge (Roomy and uncrowded)
            Row(
              children: [
                GestureDetector(
                  onTap: () => _selectAndPlayEvent(event),
                  child: CircleAvatar(
                    backgroundColor: isSelected ? AppTheme.primaryGlow : categoryColor.withValues(alpha: 0.2),
                    radius: 20,
                    child: isSelected && _isPlaying
                        ? const Icon(Icons.pause, color: Colors.black, size: 22)
                        : Text(event.categoryEmoji, style: const TextStyle(fontSize: 20)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            event.formatShortTime(_currentSession.startTime),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: isSelected ? AppTheme.primaryGlow : Colors.white,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            event.formatPeriod(_currentSession.startTime),
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Dauer: ${(event.duration.inMilliseconds / 1000).toStringAsFixed(1)}s • Max: ${event.maxDb.toStringAsFixed(1)} dB${event.confidence > 0 ? ' • ${(event.confidence * 100).toInt()}% KI' : ''}',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: categoryColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: categoryColor.withValues(alpha: 0.6)),
                  ),
                  child: Text(
                    '${event.categoryEmoji} ${event.subType ?? event.categoryLabel}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: categoryColor,
                    ),
                  ),
                ),
              ],
            ),

            // Speech transcription quote box (if speech detected)
            if (event.transcription != null &&
                event.transcription!.isNotEmpty &&
                event.transcription!.toLowerCase() != 'null') ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Text('🗣️ ', style: TextStyle(fontSize: 14)),
                    Expanded(
                      child: Text(
                        '„${event.transcription}“',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF34D399),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // AI Explanation box (if explanation exists)
            if (event.explanation != null && event.explanation!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceLight.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('✨ ', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Text(
                        event.explanation!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFCBD5E1),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Bottom Row: Tag Chips on the Left, Action Buttons on the Right
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final tag in event.tags)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0284C7).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.5)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                tag,
                                style: const TextStyle(fontSize: 11, color: Color(0xFF38BDF8), fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 4),
                              GestureDetector(
                                onTap: () => _removeTagFromEvent(event, tag),
                                child: const Icon(Icons.close, size: 12, color: Color(0xFF38BDF8)),
                              ),
                            ],
                          ),
                        ),
                      if (event.isProtected)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.5)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.shield_outlined, size: 12, color: Color(0xFF34D399)),
                              SizedBox(width: 4),
                              Text(
                                'Löschgeschützt',
                                style: TextStyle(fontSize: 10, color: Color(0xFF34D399), fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        event.isFavorite ? Icons.star : Icons.star_border,
                        color: event.isFavorite ? Colors.amber : AppTheme.textSecondary,
                        size: 22,
                      ),
                      tooltip: event.isFavorite ? 'Aus Favoriten entfernen' : 'Als Favorit markieren (Löschschutz)',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _toggleEventFavorite(event),
                    ),
                    IconButton(
                      icon: const Icon(Icons.label_outline, color: Color(0xFF38BDF8), size: 20),
                      tooltip: 'Tags verwalten (Löschschutz)',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _showEventTagDialog(event),
                    ),
                    IconButton(
                      icon: const Icon(Icons.share, color: Color(0xFF25D366), size: 20),
                      tooltip: 'Diesen Clip per WhatsApp teilen',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _shareSpecificEvent(event),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }
}

/// Fast, Zero-Lag Custom Waveform Painter
class WaveformPainter extends CustomPainter {
  final List<double> amplitudeHistory;
  final double thresholdDb;
  final bool isNoiseFilterEnabled;
  final double currentPositionRatio;
  final double snippetStartRatio;
  final double snippetEndRatio;
  final DateTime sessionStartTime;
  final Duration sessionDuration;
  final double zoomFactor;

  WaveformPainter({
    required this.amplitudeHistory,
    required this.thresholdDb,
    required this.isNoiseFilterEnabled,
    required this.currentPositionRatio,
    required this.snippetStartRatio,
    required this.snippetEndRatio,
    required this.sessionStartTime,
    required this.sessionDuration,
    required this.zoomFactor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFF0F172A);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)), bgPaint);

    if (amplitudeHistory.isEmpty) return;

    final barWidth = size.width / amplitudeHistory.length;
    final midY = (size.height - 18) / 2 + 18; // Reserve top 18px for time axis

    // Draw Snippet Selected Region Background Highlight
    final startX = snippetStartRatio * size.width;
    final endX = snippetEndRatio * size.width;
    final snippetHighlightPaint = Paint()..color = const Color(0x338B5CF6);
    canvas.drawRect(Rect.fromLTRB(startX, 18, endX, size.height), snippetHighlightPaint);

    // Draw Top Time Axis Scale when zoomed or full view
    _drawTimeAxis(canvas, size);

    // Fast rendering: Downsample lines to max 800 bars so GPU rendering takes 0ms
    final int step = (amplitudeHistory.length / 800).ceil().clamp(1, 500);

    for (int i = 0; i < amplitudeHistory.length; i += step) {
      final db = amplitudeHistory[i];

      // Convert dB (-60 to 0) to height ratio (0.05 to 1.0)
      final norm = ((db + 60) / 60).clamp(0.05, 1.0);
      final barHeight = norm * (size.height - 28);
      final x = i * barWidth;

      final isPeak = isNoiseFilterEnabled ? (db >= thresholdDb) : (db > -58.0);
      final barPaint = Paint()
        ..color = isPeak ? const Color(0xFF22D3EE) : const Color(0xFF475569)
        ..strokeWidth = (barWidth * 0.8).clamp(1.5, 6.0)
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(x, midY - barHeight / 2),
        Offset(x, midY + barHeight / 2),
        barPaint,
      );
    }

    // Draw Threshold Reference Line (only if filter enabled)
    if (isNoiseFilterEnabled) {
      final threshNorm = ((thresholdDb + 60) / 60).clamp(0.05, 1.0);
      final threshY = midY - (threshNorm * (size.height - 28)) / 2;
      final threshPaint = Paint()
        ..color = const Color(0xFFF59E0B).withValues(alpha: 0.6)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(0, threshY), Offset(size.width, threshY), threshPaint);
    }

    // Draw Snippet Boundary Lines & Handles
    final handlePaint = Paint()
      ..color = const Color(0xFF8B5CF6)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(startX, 18), Offset(startX, size.height), handlePaint);
    canvas.drawLine(Offset(endX, 18), Offset(endX, size.height), handlePaint);

    // Draw Playback Head Position Indicator Line
    final playX = (currentPositionRatio * size.width).clamp(0.0, size.width);
    final playHeadPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5;
    canvas.drawLine(Offset(playX, 18), Offset(playX, size.height), playHeadPaint);

    final dotPaint = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(playX, 22), 4, dotPaint);
  }

  void _drawTimeAxis(Canvas canvas, Size size) {
    final numTicks = (10 * zoomFactor).round().clamp(6, 40);
    final intervalMs = sessionDuration.inMilliseconds / numTicks;

    final textStyle = TextStyle(
      color: Colors.white70.withValues(alpha: 0.6),
      fontSize: 9,
      fontWeight: FontWeight.bold,
    );

    for (int i = 0; i <= numTicks; i++) {
      final x = (i / numTicks) * size.width;
      final timeOffsetMs = (i * intervalMs).round();
      final clockTime = sessionStartTime.add(Duration(milliseconds: timeOffsetMs));

      final hour = clockTime.hour.toString().padLeft(2, '0');
      final min = clockTime.minute.toString().padLeft(2, '0');
      final timeStr = '$hour:$min';

      final textSpan = TextSpan(text: timeStr, style: textStyle);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset((x - textPainter.width / 2).clamp(0, size.width - 25), 2));
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.currentPositionRatio != currentPositionRatio ||
        oldDelegate.thresholdDb != thresholdDb ||
        oldDelegate.isNoiseFilterEnabled != isNoiseFilterEnabled ||
        oldDelegate.zoomFactor != zoomFactor ||
        oldDelegate.snippetStartRatio != snippetStartRatio ||
        oldDelegate.snippetEndRatio != snippetEndRatio;
  }
}
