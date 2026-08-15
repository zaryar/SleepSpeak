import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../data/repositories/recording_repository.dart';
import '../../../data/services/audio_recorder_service.dart';
import '../../../data/services/logger_service.dart';
import '../../../data/services/storage_service.dart';
import '../../../domain/models/recording_session.dart';
import '../../core/theme.dart';
import '../detail/recording_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  final RecordingRepository repository;

  const HomeScreen({super.key, required this.repository});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioRecorderService _recorderService = AudioRecorderService();
  bool _isMicTesting = false;
  double _currentMicTestDb = -60.0;
  StreamSubscription<double>? _amplitudeSub;
  Timer? _uiRecordingTimer;
  bool _isBatteryOptIgnored = false;

  @override
  void initState() {
    super.initState();
    widget.repository.loadSessions();
    _checkBatteryOptStatus();

    // Setup 30-second periodic auto-flush to disk so no data is lost on crash
    _recorderService.onPeriodicFlush = (duration, history) async {
      await widget.repository.autoFlushOngoingSession(
        duration: duration,
        amplitudeHistory: history,
      );
    };

    // Listen for low battery auto-save
    _recorderService.onAutoSaveTriggered = (path, duration, history) async {
      final startTime = _recorderService.startTime ?? DateTime.now();
      await widget.repository.saveNewSession(
        audioFilePath: path,
        startTime: startTime,
        duration: duration,
        amplitudeHistory: history,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚡ Akku kritisch (<5%): Schlafaufnahme wurde automatisch abgespeichert!'),
            backgroundColor: Colors.amber,
          ),
        );
      }
    };
  }

  Future<void> _checkBatteryOptStatus() async {
    final status = await Permission.ignoreBatteryOptimizations.isGranted;
    if (mounted) {
      setState(() {
        _isBatteryOptIgnored = status;
      });
    }
  }

  @override
  void dispose() {
    _uiRecordingTimer?.cancel();
    _amplitudeSub?.cancel();
    _recorderService.dispose();
    super.dispose();
  }

  Future<void> _toggleMicTest() async {
    if (_isMicTesting) {
      await _recorderService.stopLiveMicTest();
      _amplitudeSub?.cancel();
      setState(() {
        _isMicTesting = false;
        _currentMicTestDb = -60.0;
      });
    } else {
      final perm = await _recorderService.hasMicPermission();
      if (!perm) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Mikrofon-Berechtigung erforderlich!')),
            );
          }
          return;
        }
      }

      await _recorderService.startLiveMicTest();
      _amplitudeSub = _recorderService.amplitudeStream?.listen((db) {
        if (mounted) {
          setState(() {
            _currentMicTestDb = db;
          });
        }
      });
      setState(() {
        _isMicTesting = true;
      });
    }
  }

  Future<void> _toggleSleepRecording() async {
    if (_recorderService.state == RecordingState.recordingSleep) {
      // Stop recording
      _uiRecordingTimer?.cancel();
      _uiRecordingTimer = null;
      final path = await _recorderService.stopSleepRecording();
      if (path != null) {
        final startTime = _recorderService.startTime ?? DateTime.now();
        final duration = _recorderService.elapsedDuration;
        final history = _recorderService.amplitudeHistory;

        final session = await widget.repository.saveNewSession(
          audioFilePath: path,
          startTime: startTime,
          duration: duration,
          amplitudeHistory: history,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('🌙 Schlafaufnahme erfolgreich gespeichert!')),
          );
          // Navigate to recording detail
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (ctx) => RecordingDetailScreen(
                session: session,
                repository: widget.repository,
              ),
            ),
          );
        }
      }
      setState(() {});
    } else {
      final micStatus = await Permission.microphone.request();
      await Permission.notification.request();

      if (!micStatus.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Mikrofon-Berechtigung wird für die Aufnahme benötigt.')),
          );
        }
        return;
      }

      final startTime = DateTime.now();
      final sessionId = 'sleep_${startTime.millisecondsSinceEpoch}';
      final storageService = StorageService();
      final targetPath = await storageService.generateAudioFilePath(sessionId);

      // Save initial unfinalized session on disk for crash recovery
      await widget.repository.createOngoingSession(
        audioFilePath: targetPath,
        startTime: startTime,
      );

      final success = await _recorderService.startSleepRecording(targetPath);
      if (success) {
        _uiRecordingTimer?.cancel();
        _uiRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fehler beim Starten der Aufnahme.')),
        );
      }
      setState(() {});
    }
  }

  Future<void> _showLogDialog() async {
    final logger = LoggerService();
    final logText = await logger.getLogContent();

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bug_report, color: AppTheme.primary),
            SizedBox(width: 8),
            Text('System-Log & Diagnose'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: SingleChildScrollView(
            child: SelectableText(
              logText,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await logger.clearLog();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Log leeren', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: logText));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Log in Zwischenablage kopiert!')),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Kopieren'),
          ),
        ],
      ),
    );
  }

  Future<void> _requestIgnoreBatteryOptimizations() async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    await _checkBatteryOptStatus();
    if (mounted) {
      if (status.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✓ Akku-Optimierung deaktiviert. Perfekt für die Nacht!')),
        );
      } else {
        openAppSettings();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = _recorderService.state == RecordingState.recordingSleep;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bedtime, color: AppTheme.primary),
            SizedBox(width: 8),
            Text('SleepSpeak'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report_outlined, color: AppTheme.textSecondary),
            tooltip: 'System-Log / Diagnose',
            onPressed: _showLogDialog,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.repository,
        builder: (context, _) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      if (kIsWeb) ...[
                        _buildWebNoticeCard(),
                        const SizedBox(height: 16),
                      ],

                      // Active Recording / Control Card
                      _buildRecordingCard(isRecording),
                      const SizedBox(height: 16),

                      // Live Mic Test Widget
                      _buildMicTestCard(),

                      // Battery Optimization Info Card (mobile only)
                      if (!kIsWeb && !_isBatteryOptIgnored) ...[
                        const SizedBox(height: 12),
                        _buildBatteryOptCard(),
                      ],
                      const SizedBox(height: 24),

                      // Section Title
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Deine Aufnahmen',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),

              // Sessions List
              if (widget.repository.isLoading)
                const SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(32.0),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                )
              else if (widget.repository.sessions.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Column(
                      children: [
                        Icon(Icons.nightlight_round, size: 48, color: AppTheme.textSecondary),
                        SizedBox(height: 12),
                        Text(
                          'Noch keine Schlafaufnahmen vorhanden.\nDrücke heute Nacht auf Aufnahme!',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final session = widget.repository.sessions[index];
                        return _buildSessionItem(session);
                      },
                      childCount: widget.repository.sessions.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRecordingCard(bool isRecording) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isRecording
              ? [const Color(0xFF7C3AED), const Color(0xFFC026D3)]
              : [AppTheme.surface, const Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isRecording ? AppTheme.primaryGlow : AppTheme.surfaceLight,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: isRecording ? AppTheme.primary.withValues(alpha: 0.3) : Colors.black26,
            blurRadius: 16,
            spreadRadius: 2,
          )
        ],
      ),
      child: Column(
        children: [
          Icon(
            isRecording ? Icons.mic_rounded : Icons.nightlight_round_sharp,
            size: 48,
            color: isRecording ? Colors.white : AppTheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            isRecording ? 'Schlafaufnahme läuft...' : 'Bereit für die Nacht',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isRecording
                ? 'Aufnahmedauer: ${_formatDuration(_recorderService.elapsedDuration)}'
                : 'Tippe auf den Button, wenn du schlafen gehst',
            style: TextStyle(
              color: isRecording ? Colors.white70 : AppTheme.textSecondary,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 20),

          // Start / Stop Button
          ElevatedButton.icon(
            onPressed: _toggleSleepRecording,
            style: ElevatedButton.styleFrom(
              backgroundColor: isRecording ? Colors.redAccent : AppTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            icon: Icon(isRecording ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 28),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                isRecording ? 'AUFNAHME STOPPEN' : 'SCHLAF AUFNEHMEN',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMicTestCard() {
    // Convert current dB (-60 to 0) to 0.0 .. 1.0 progress ratio
    final norm = ((_currentMicTestDb + 60) / 60).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
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
                    Icon(Icons.graphic_eq, color: AppTheme.primary, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Mikrofon-Check (Flüstern/Klatschen)',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _toggleMicTest,
                child: Text(_isMicTesting ? 'Stoppen' : 'Testen'),
              ),
            ],
          ),
          if (_isMicTesting) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: norm,
                minHeight: 10,
                backgroundColor: AppTheme.background,
                color: norm > 0.6 ? AppTheme.accent : AppTheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pegel: ${_currentMicTestDb.toStringAsFixed(1)} dB',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBatteryOptCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.battery_saver, color: AppTheme.warning, size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Android Akku-Optimierung für unterbrechungsfreie Nachtaufnahme deaktivieren',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: _requestIgnoreBatteryOptimizations,
            child: const Text('Einstellen', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionItem(RecordingSession session) {
    final peakCount = session.detectedEvents.length;
    final sizeMb = (session.fileSizeBytes / (1024 * 1024)).toStringAsFixed(1);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.multitrack_audio, color: AppTheme.primary),
        ),
        title: Text(
          session.title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text('Dauer: ${_formatDuration(session.duration)} • $sizeMb MB', style: const TextStyle(fontSize: 12)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: peakCount > 0 ? AppTheme.accent.withValues(alpha: 0.2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '⚡ $peakCount Geräusche',
                  style: TextStyle(
                    fontSize: 12,
                    color: peakCount > 0 ? AppTheme.primaryGlow : AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                session.isFavorite ? Icons.star : Icons.star_border,
                color: session.isFavorite ? Colors.amber : AppTheme.textSecondary,
              ),
              onPressed: () => widget.repository.toggleFavorite(session.id),
              tooltip: session.isFavorite ? 'Favorit (geschützt)' : 'Als Favorit markieren',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: () => _confirmDelete(session),
            ),
          ],
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (ctx) => RecordingDetailScreen(
                session: session,
                repository: widget.repository,
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(RecordingSession session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Aufnahme löschen?'),
        content: Text('Möchtest du "${session.title}" wirklich unwiderruflich löschen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.repository.deleteSession(session.id);
    }
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${h}h ${m}m ${s}s';
  }

  Widget _buildWebNoticeCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceLight.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryGlow.withValues(alpha: 0.3)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: AppTheme.primaryGlow, size: 22),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🌐 Web-Vorschau / Demo',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: AppTheme.textPrimary,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'So sieht die App ungefähr auf dem Handy aus! Du kannst die Funktionen, die Schlafanalyse und den Mikrofontest hier kurz ausprobieren – im Web-Browser ist das Ganze natürlich eingeschränkt und nicht so zuverlässig wie die echte App. Für die echte Nachtaufnahme mit Akku-Schutz lade dir einfach die fertige Android-APK auf GitHub herunter.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
