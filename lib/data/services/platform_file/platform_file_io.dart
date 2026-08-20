import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

class AppFile {
  final io.File _file;
  AppFile(String path) : _file = io.File(path);
  AppFile.fromIo(this._file);

  String get path => _file.path;
  Future<bool> exists() => _file.exists();
  bool existsSync() => _file.existsSync();
  Future<int> length() => _file.length();
  int lengthSync() => _file.lengthSync();
  Future<String> readAsString() => _file.readAsString();
  Future<void> writeAsString(String contents, {bool flush = false, bool append = false}) =>
      _file.writeAsString(contents, mode: append ? io.FileMode.append : io.FileMode.write, flush: flush);
  Future<void> delete() => _file.delete();
  Future<AppFile> copy(String newPath) async {
    final copied = await _file.copy(newPath);
    return AppFile.fromIo(copied);
  }
  Future<Uint8List> readAsBytes() => _file.readAsBytes();
  Future<void> writeAsBytes(List<int> bytes) => _file.writeAsBytes(bytes);
  Future<Uint8List> readRange(int start, int length) async {
    final raf = await _file.open(mode: io.FileMode.read);
    try {
      await raf.setPosition(start);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }
}

class AppDirectory {
  final io.Directory _dir;
  AppDirectory(String path) : _dir = io.Directory(path);

  String get path => _dir.path;
  Future<bool> exists() => _dir.exists();
  Future<AppDirectory> create({bool recursive = false}) async {
    final d = await _dir.create(recursive: recursive);
    return AppDirectory(d.path);
  }
  List<AppFile> listJsonFiles() {
    if (!_dir.existsSync()) return [];
    return _dir
        .listSync()
        .whereType<io.File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => AppFile.fromIo(f))
        .toList();
  }
}

String getSystemTempPath() => io.Directory.systemTemp.path;

List<double> parseWavNative(String filePath) {
  final List<double> history = [];
  final file = io.File(filePath);

  if (!file.existsSync()) return history;

  final fileSize = file.lengthSync();
  if (fileSize <= 44) return history;

  final io.RandomAccessFile raf = file.openSync(mode: io.FileMode.read);
  try {
    raf.setPositionSync(44);

    const int bytesPerChunk = 6400; // 200ms of 16kHz 16-bit mono
    final int dataSize = fileSize - 44;
    final int totalChunks = dataSize ~/ bytesPerChunk;

    final Uint8List buffer = Uint8List(bytesPerChunk);

    for (int i = 0; i < totalChunks; i++) {
      final bytesRead = raf.readIntoSync(buffer);
      if (bytesRead < 2) break;

      final Int16List samples = buffer.buffer.asInt16List(0, bytesRead ~/ 2);

      double sumSquare = 0.0;
      for (int j = 0; j < samples.length; j++) {
        final sample = samples[j];
        sumSquare += sample * sample;
      }

      final rms = sqrt(sumSquare / samples.length);

      double db = -60.0;
      if (rms > 1.0) {
        db = 20.0 * (log(rms / 32768.0) / ln10);
      }
      history.add(db.clamp(-60.0, 0.0));
    }
  } finally {
    raf.closeSync();
  }

  return history;
}
