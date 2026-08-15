import 'dart:typed_data';

class AppFile {
  final String path;
  AppFile(this.path);

  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<int> length() async => 0;
  int lengthSync() => 0;
  Future<String> readAsString() async => '';
  Future<void> writeAsString(String contents, {bool flush = false, bool append = false}) async {}
  Future<void> delete() async {}
  Future<Uint8List> readAsBytes() async => Uint8List(0);
  Future<void> writeAsBytes(List<int> bytes) async {}
}

class AppDirectory {
  final String path;
  AppDirectory(this.path);

  Future<bool> exists() async => true;
  Future<AppDirectory> create({bool recursive = false}) async => this;
  List<AppFile> listJsonFiles() => [];
}

String getSystemTempPath() => '';

List<double> parseWavNative(String filePath) => [];
