import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../../data/repositories/recording_repository.dart';
import '../../../data/services/native_file_picker_service.dart';
import '../../../data/services/notification_service.dart';
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
  final NotificationService _notificationService = NotificationService();
  bool _isMicTesting = false;
  double _currentMicTestDb = -60.0;
  StreamSubscription<double>? _amplitudeSub;
  Timer? _uiRecordingTimer;
  bool _isBatteryOptIgnored = false;

  int _startDelayMinutes = 10;
  bool _isDelayedStartActive = false;
  int _remainingDelaySeconds = 0;
  DateTime? _targetDelayedStartTime;
  Timer? _delayCountdownTimer;

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
    _delayCountdownTimer?.cancel();
    _amplitudeSub?.cancel();
    _recorderService.dispose();
    super.dispose();
  }

  Future<void> _startDelayedRecording() async {
    final now = DateTime.now();
    final targetTime = now.add(Duration(minutes: _startDelayMinutes));
    final targetTimeFormatted = DateFormat('HH:mm').format(targetTime);

    setState(() {
      _isDelayedStartActive = true;
      _targetDelayedStartTime = targetTime;
      _remainingDelaySeconds = _startDelayMinutes * 60;
    });

    // 1. Keep CPU awake even if phone screen is locked/sleeping
    if (!kIsWeb) {
      await WakelockPlus.enable();
    }

    // 2. Start Foreground Service so Android 14 Doze mode never pauses the timer
    await _notificationService.showDelayedTimerNotification(
      timeRemainingText: '$_startDelayMinutes Min',
      targetStartTime: targetTimeFormatted,
    );

    _delayCountdownTimer?.cancel();
    _delayCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentTime = DateTime.now();
      if (_targetDelayedStartTime == null ||
          currentTime.isAfter(_targetDelayedStartTime!) ||
          currentTime.isAtSameMomentAs(_targetDelayedStartTime!)) {
        timer.cancel();
        setState(() {
          _isDelayedStartActive = false;
          _targetDelayedStartTime = null;
          _remainingDelaySeconds = 0;
        });
        await _toggleSleepRecording();
      } else {
        final diffSeconds = _targetDelayedStartTime!.difference(currentTime).inSeconds;
        setState(() {
          _remainingDelaySeconds = diffSeconds > 0 ? diffSeconds : 0;
        });

        // Update notification every 30 seconds
        if (diffSeconds > 0 && diffSeconds % 30 == 0) {
          final remMins = (diffSeconds / 60).ceil();
          final remText = remMins > 1 ? '$remMins Min' : '$diffSeconds Sek';
          await _notificationService.showDelayedTimerNotification(
            timeRemainingText: remText,
            targetStartTime: targetTimeFormatted,
          );
        }
      }
    });
  }

  Future<void> _cancelDelayedRecording() async {
    _delayCountdownTimer?.cancel();
    setState(() {
      _isDelayedStartActive = false;
      _targetDelayedStartTime = null;
      _remainingDelaySeconds = 0;
    });
    if (!kIsWeb) {
      await WakelockPlus.disable();
    }
    await _notificationService.cancelRecordingNotification();
  }

  Future<void> _startImmediatelyFromDelayed() async {
    _delayCountdownTimer?.cancel();
    setState(() {
      _isDelayedStartActive = false;
      _targetDelayedStartTime = null;
      _remainingDelaySeconds = 0;
    });
    await _toggleSleepRecording();
  }

  void _showDelayPickerModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
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
                          child: const Icon(Icons.timer_outlined, color: Color(0xFF38BDF8)),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Startverzögerung einstellen',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              Text(
                                'Gib dir Zeit zum Einschlafen, bevor die Aufnahme startet',
                                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    Center(
                      child: Text(
                        '$_startDelayMinutes Minuten',
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
                      ),
                    ),
                    const SizedBox(height: 10),

                    Slider(
                      value: _startDelayMinutes.toDouble(),
                      min: 1.0,
                      max: 30.0,
                      divisions: 29,
                      activeColor: const Color(0xFF38BDF8),
                      label: '$_startDelayMinutes Min',
                      onChanged: (v) {
                        setModalState(() {
                          _startDelayMinutes = v.round();
                        });
                        setState(() {
                          _startDelayMinutes = v.round();
                        });
                      },
                    ),
                    const SizedBox(height: 8),

                    // Quick Selection Chips
                    Wrap(
                      spacing: 8,
                      children: [1, 5, 10, 15, 20, 30].map((mins) {
                        final isSel = _startDelayMinutes == mins;
                        return ChoiceChip(
                          label: Text('$mins Min'),
                          selected: isSel,
                          selectedColor: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                          onSelected: (_) {
                            setModalState(() => _startDelayMinutes = mins);
                            setState(() => _startDelayMinutes = mins);
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _startDelayedRecording();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF38BDF8),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.play_arrow),
                        label: Text('In $_startDelayMinutes Minuten starten', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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

  bool _isSavingSession = false;

  Future<void> _toggleSleepRecording() async {
    if (_recorderService.state == RecordingState.recordingSleep) {
      if (_isSavingSession) return;
      setState(() {
        _isSavingSession = true;
      });

      try {
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
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Fehler beim Stoppen: $e')),
          );
        }
      } finally {
        if (mounted) {
          setState(() {
            _isSavingSession = false;
          });
        }
      }
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

  Future<void> _showBackupRestoreDialog() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.cloud_sync, color: AppTheme.primary),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Backup, Export & Import',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Sichere deine Schlafaufnahmen oder importiere Audio',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Option 1: Export / Share All Recordings as ZIP Archive
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.archive_outlined, color: Color(0xFF38BDF8)),
                  ),
                  title: const Text('Komplettes Backup erstellen (.zip)', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Packt alle Original-WAV-Audios & Analysen in eine handliche ZIP-Datei zum Sichern'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: AppTheme.textSecondary),
                  onTap: () async {
                    Navigator.pop(ctx);

                    double currentProgress = 0.05;
                    String currentStatus = 'Vorbereiten der Dateien...';
                    StateSetter? dialogSetState;

                    // Show sleek real-time progress dialog
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
                                  Icon(Icons.archive, color: AppTheme.primary),
                                  SizedBox(width: 10),
                                  Text('Backup wird erstellt', style: TextStyle(fontSize: 18)),
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
                                      color: AppTheme.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      '$percent %',
                                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.primary),
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
                      final zipPath = await widget.repository.createBackupZip(
                        onProgress: (ratio, text) {
                          currentProgress = ratio;
                          currentStatus = text;
                          final pct = (ratio * 100).toInt().clamp(0, 100);
                          _notificationService.showBackupProgressNotification(
                            progress: pct,
                            maxProgress: 100,
                            statusText: text,
                          );
                          dialogSetState?.call(() {});
                        },
                      );

                      if (mounted) {
                        Navigator.of(context, rootNavigator: true).pop(); // Close progress dialog
                      }
                      await _notificationService.cancelBackupNotification();

                      if (zipPath == null) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Keine Aufnahmen zum Sichern vorhanden.')),
                          );
                        }
                        return;
                      }

                      await Share.shareXFiles(
                        [XFile(zipPath, mimeType: 'application/zip')],
                        text: 'SleepSpeak Komplettes Schlafaufnahmen-Backup (.zip)',
                      );
                    } catch (e) {
                      if (mounted) {
                        Navigator.of(context, rootNavigator: true).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Fehler beim Erstellen des Backups: $e')),
                        );
                      }
                      await _notificationService.cancelBackupNotification();
                    }
                  },
                ),

                const Divider(height: 24, color: AppTheme.surfaceLight),

                // Option 2: Import ZIP Backup or Audio File
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.unarchive_outlined, color: Color(0xFF34D399)),
                  ),
                  title: const Text('Backup wiederherstellen / Audio importieren', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Liest ein .zip Backup oder eine .wav Datei ein und stellt alle Nächte wieder her'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: AppTheme.textSecondary),
                  onTap: () async {
                    Navigator.pop(ctx);
                    try {
                      final path = await NativeFilePickerService.pickAudioFile();
                      if (path != null && path.isNotEmpty) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('⏳ Daten werden wiederhergestellt & analysiert...')),
                          );
                        }
                        final session = await widget.repository.importRecording(path);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('✅ Backup / Aufnahme erfolgreich eingelesen!'),
                              backgroundColor: Colors.green,
                            ),
                          );
                          if (session != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (c) => RecordingDetailScreen(
                                  session: session,
                                  repository: widget.repository,
                                ),
                              ),
                            );
                          }
                        }
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Fehler beim Wiederherstellen: $e')),
                        );
                      }
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
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
            icon: const Icon(Icons.cloud_sync_outlined, color: AppTheme.primary),
            tooltip: 'Backup & Export / Import',
            onPressed: _showBackupRestoreDialog,
          ),
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
    if (_isDelayedStartActive) {
      final totalSec = _startDelayMinutes * 60;
      final progress = totalSec > 0 ? (1.0 - (_remainingDelaySeconds / totalSec)).clamp(0.0, 1.0) : 0.0;
      final mins = _remainingDelaySeconds ~/ 60;
      final secs = (_remainingDelaySeconds % 60).toString().padLeft(2, '0');
      final targetFormatted = _targetDelayedStartTime != null ? DateFormat('HH:mm').format(_targetDelayedStartTime!) : '';

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0F172A), Color(0xFF0369A1)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF38BDF8), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0284C7).withValues(alpha: 0.3),
              blurRadius: 16,
              spreadRadius: 2,
            )
          ],
        ),
        child: Column(
          children: [
            const Icon(Icons.hourglass_top_rounded, size: 48, color: Color(0xFF38BDF8)),
            const SizedBox(height: 12),
            const Text(
              'Einschlaf-Timer aktiv',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              targetFormatted.isNotEmpty
                  ? 'Startet um $targetFormatted Uhr (in $mins:$secs Min)'
                  : 'Aufnahme startet automatisch in $mins:$secs Min',
              style: const TextStyle(color: Color(0xFFE0F2FE), fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: Colors.white24,
                color: const Color(0xFF38BDF8),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _startImmediatelyFromDelayed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: const Text('Sofort starten', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _cancelDelayedRecording,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white30),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Abbrechen'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

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
            onPressed: _isSavingSession ? null : _toggleSleepRecording,
            style: ElevatedButton.styleFrom(
              backgroundColor: isRecording ? Colors.redAccent : AppTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            icon: _isSavingSession
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : Icon(isRecording ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 28),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _isSavingSession
                    ? 'WIRD GESPEICHERT...'
                    : (isRecording ? 'AUFNAHME STOPPEN' : 'SCHLAF AUFNEHMEN'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
            ),
          ),

          // Delayed Start Button (Shown when idle)
          if (!isRecording) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _startDelayedRecording,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF38BDF8),
                      side: const BorderSide(color: Color(0xFF0284C7)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.timer_outlined, size: 18),
                    label: Text(
                      'Schlaf in $_startDelayMinutes Minuten aufnehmen',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _showDelayPickerModal,
                  icon: const Icon(Icons.tune, color: Color(0xFF38BDF8)),
                  tooltip: 'Startverzögerung anpassen (1-30 Min)',
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.surfaceLight,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ],
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
