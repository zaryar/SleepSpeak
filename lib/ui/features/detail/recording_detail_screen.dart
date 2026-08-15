import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import '../../../data/repositories/recording_repository.dart';
import '../../../data/services/audio_trimmer_service.dart';
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

  // Selected event ID for glowing highlight & direct playback
  String? _selectedEventId;

  // Event List Filters (Duration & Min Decibel)
  double _minDurationFilterSec = 0.0;
  double _minDbFilter = -60.0;

  // Step-by-step zoom level (1x to 50x)
  double _zoomFactor = 1.0;

  // Snippet selection bounds (0.0 to 1.0 ratio of session)
  double _snippetStartRatio = 0.0;
  double _snippetEndRatio = 0.25;

  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _currentSession = widget.session;
    _audioPlayer = AudioPlayer();

    _initAudioPlayer();
  }

  Future<void> _initAudioPlayer() async {
    final file = File(_currentSession.filePath);
    if (await file.exists()) {
      await _audioPlayer.setFilePath(_currentSession.filePath);

      _audioPlayer.positionStream.listen((pos) {
        _positionNotifier.value = pos;
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
  }

  @override
  void dispose() {
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
    _applyThresholdUpdate(val);
  }

  void _toggleNoiseFilter(bool enabled) {
    setState(() {
      _isNoiseFilterEnabled = enabled;
      _thresholdDb = enabled ? -38.0 : -60.0;
    });
    _applyThresholdUpdate(_thresholdDb);
  }

  void _applyThresholdUpdate(double val) {
    widget.repository.updateSessionEvents(_currentSession.id, val);
    final idx = widget.repository.sessions.indexWhere((s) => s.id == _currentSession.id);
    if (idx != -1) {
      setState(() {
        _currentSession = widget.repository.sessions[idx];
      });
    }
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  Future<void> _seekTo(Duration target) async {
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

    setState(() => _isExporting = true);

    try {
      final snippetPath = await _storageService.generateSnippetFilePath('${DateTime.now().millisecondsSinceEpoch}');
      final inputFile = File(_currentSession.filePath);
      final outputFile = File(snippetPath);

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
            const SizedBox(height: 16),

            // Noise Threshold & Filter Slider Card (With Checkbox to Turn Off Filter Completely)
            _buildThresholdCard(),
            const SizedBox(height: 16),

            // Snippet Selector & Share Controls
            _buildSnippetShareCard(startMs, endMs),
            const SizedBox(height: 20),

            // Event List Filter Controls Card (Filter by Duration & Min Decibel)
            _buildEventFilterCard(filteredEvents.length),
            const SizedBox(height: 16),

            // Events List Header
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
            const SizedBox(height: 8),

            // Events List
            if (filteredEvents.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Keine Geräusche passen zu den gewählten Filtern.\nPasse die Mindestdauer oder Mindest-Lautstärke oben an.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                  textAlign: TextAlign.center,
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
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Empfindlich (-50 dB)', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                Expanded(
                  child: Slider(
                    value: _thresholdDb,
                    min: -55.0,
                    max: -15.0,
                    divisions: 40,
                    activeColor: AppTheme.accent,
                    label: '${_thresholdDb.toStringAsFixed(1)} dB',
                    onChanged: _onThresholdChanged,
                  ),
                ),
                const Text('Streng (-15 dB)', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
              ],
            ),
            Center(
              child: Text(
                'Aktueller Filter: ${_thresholdDb.toStringAsFixed(1)} dB',
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

          // Filter by Min Decibel Slider (-60 dB to -20 dB)
          Row(
            children: [
              Text(
                'Mindest-Lautstärke: ${_minDbFilter.toStringAsFixed(1)} dB',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
              Expanded(
                child: Slider(
                  value: _minDbFilter,
                  min: -60.0,
                  max: -20.0,
                  divisions: 40,
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

  Widget _buildEventItem(DetectedEvent event) {
    final isSelected = (_selectedEventId == event.id);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected ? AppTheme.primaryGlow : Colors.transparent,
          width: isSelected ? 2.5 : 0.0,
        ),
      ),
      color: isSelected ? const Color(0xFF1E1B4B) : AppTheme.surface,
      elevation: isSelected ? 4 : 1,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: GestureDetector(
          onTap: () => _selectAndPlayEvent(event),
          child: CircleAvatar(
            backgroundColor: isSelected ? AppTheme.primaryGlow : const Color(0xFF312E81),
            child: Icon(
              isSelected && _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
              color: isSelected ? Colors.black : AppTheme.primaryGlow,
              size: 24,
            ),
          ),
        ),
        title: Text(
          event.formatClockTime(_currentSession.startTime),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: isSelected ? AppTheme.primaryGlow : Colors.white,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'Dauer: ${(event.duration.inMilliseconds / 1000).toStringAsFixed(1)}s • Max: ${event.maxDb.toStringAsFixed(1)} dB',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Direct WhatsApp Share Button for this specific event
            IconButton(
              icon: const Icon(Icons.share, color: Color(0xFF25D366), size: 20),
              tooltip: 'Diesen Clip per WhatsApp teilen',
              onPressed: () => _shareSpecificEvent(event),
            ),
            const Icon(Icons.arrow_forward_ios, size: 14, color: AppTheme.textSecondary),
          ],
        ),
        onTap: () => _selectAndPlayEvent(event),
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
