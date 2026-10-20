// Автообновление.
// Windows / Linux — тихо: при запуске (и раз в 6 часов) смотрим последний релиз на GitHub, если он новее —
// качаем архив в фоне и распаковываем во временную папку. Дальше два пути:
//   · человек нажал «Перезапустить» в полоске — подменяем файлы и запускаем новую версию;
//   · не нажал — подменяем файлы при закрытии окна, новая версия откроется в следующий раз.
// Подмена делает маленький скрипт уже после выхода программы (свои файлы, пока она запущена, Windows менять не даёт).
// Android — система не даёт ставить молча: качаем APK и открываем установщик, человек жмёт «Обновить».
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:path_provider/path_provider.dart';

import 'data.dart';

const _api = 'https://api.github.com/repos/kolobas58/rates/releases/latest';
// для проверки обновления в CI: RATES_TEST_VERSION=1.0.0 — программа считает себя старой версией
final _current = Platform.environment['RATES_TEST_VERSION'] ?? appVersion;

/// Короткий журнал обновления: <временная папка>/rates_update.log (для разбора, если что-то пошло не так).
void _log(String m) {
  try {
    final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}rates_update.log');
    f.writeAsStringSync('${DateTime.now().toIso8601String()} $m\n', mode: FileMode.append);
  } catch (_) {}
  if (Platform.environment.containsKey('RATES_TEST_VERSION')) stderr.writeln('[update] $m');
}

enum UpState { idle, downloading, ready, installing, failed }

class Updater extends ChangeNotifier {
  UpState state = UpState.idle;
  String? version; // новая версия, например 1.2.0
  double progress = 0; // 0..1
  String? _assetUrl;
  Directory? _staged; // распакованная новая версия (Windows/Linux)
  Timer? _timer;

  bool get available => version != null;

  void start() {
    unawaited(check());
    _timer = Timer.periodic(const Duration(hours: 6), (_) => check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String get _assetName => Platform.isWindows
      ? 'Rates-Windows-x64.zip'
      : Platform.isLinux
          ? 'Rates-Linux-x64.tar.gz'
          : 'Rates-Android.apk';

  static bool newer(String a, String b) {
    List<int> p(String s) => s.replaceFirst('v', '').split('.').map((x) => int.tryParse(x) ?? 0).toList()..addAll([0, 0, 0]);
    final x = p(a), y = p(b);
    for (var i = 0; i < 3; i++) {
      if (x[i] != y[i]) return x[i] > y[i];
    }
    return false;
  }

  Future<void> check() async {
    if (state == UpState.downloading || state == UpState.ready || state == UpState.installing) return;
    try {
      final r = await http.get(Uri.parse(_api), headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'kolobas58-rates/$appVersion'})
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        _log('check: HTTP ${r.statusCode}');
        return;
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final tag = (j['tag_name'] ?? '').toString();
      _log('check: latest $tag, current $_current');
      if (!newer(tag, _current)) return;
      final asset = (j['assets'] as List? ?? []).cast<Map<String, dynamic>>().where((a) => a['name'] == _assetName).toList();
      if (asset.isEmpty) return;
      version = tag.replaceFirst('v', '');
      _assetUrl = asset.first['browser_download_url'] as String;
      state = UpState.idle;
      notifyListeners();
      if (!Platform.isAndroid) await _download();
    } catch (e) {
      _log('check: $e'); // нет сети — проверим позже
    }
  }

  // ------------------------------------------------------------------ Windows / Linux
  Directory get _appDir => File(Platform.resolvedExecutable).parent;

  bool _writable() {
    try {
      final f = File('${_appDir.path}${Platform.pathSeparator}.rates_write_test');
      f.writeAsStringSync('ok');
      f.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _download() async {
    if (!_writable()) {
      _log('download: папка программы только для чтения — ${_appDir.path}');
      return;
    }
    // программа лежит там, куда писать нельзя (например, Program Files) — не трогаем
    state = UpState.downloading;
    progress = 0;
    notifyListeners();
    try {
      final tmp = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}rates_update_$version');
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      tmp.createSync(recursive: true);
      final file = File('${tmp.path}${Platform.pathSeparator}$_assetName');
      final req = await http.Client().send(http.Request('GET', Uri.parse(_assetUrl!)));
      final total = req.contentLength ?? 0;
      var got = 0;
      final sink = file.openWrite();
      await for (final chunk in req.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          progress = got / total;
          notifyListeners();
        }
      }
      await sink.close();
      final out = Directory('${tmp.path}${Platform.pathSeparator}x')..createSync();
      final bytes = file.readAsBytesSync();
      final arc = Platform.isWindows ? ZipDecoder().decodeBytes(bytes) : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
      extractArchiveToDisk(arc, out.path);
      // в архиве одна папка верхнего уровня (Rates/ или rates/) — берём её содержимое
      final top = out.listSync().whereType<Directory>().toList();
      _staged = top.length == 1 ? top.first : out;
      final exe = File('${_staged!.path}${Platform.pathSeparator}${Platform.isWindows ? 'rates.exe' : 'rates'}');
      if (!exe.existsSync()) throw Exception('в архиве нет программы');
      if (Platform.isLinux) await Process.run('chmod', ['+x', exe.path]);
      state = UpState.ready;
      _log('download: готово ${_staged!.path}');
    } catch (e) {
      _log('download: $e');
      state = UpState.failed;
    }
    notifyListeners();
  }

  /// Подменить файлы после выхода. restart — сразу запустить новую версию.
  Future<void> apply({required bool restart}) async {
    if (state != UpState.ready || _staged == null) return;
    _log('apply: restart=$restart');
    final src = _staged!.path, dst = _appDir.path;
    if (Platform.isWindows) {
      final ps1 = File('${_staged!.parent.parent.path}\\apply.ps1');
      ps1.writeAsStringSync(r'''
param([int]$Id, [string]$Src, [string]$Dst, [string]$Restart)
try { Wait-Process -Id $Id -Timeout 20 -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 400
for ($i = 0; $i -lt 10; $i++) {
  try { Copy-Item -Path (Join-Path $Src '*') -Destination $Dst -Recurse -Force -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 500 }
}
if ($Restart -eq '1') { Start-Process -FilePath (Join-Path $Dst 'rates.exe') -WorkingDirectory $Dst }
''');
      await Process.start('powershell', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ps1.path,
        '-Id', '$pid', '-Src', src, '-Dst', dst, '-Restart', restart ? '1' : '0',
      ], mode: ProcessStartMode.detached);
    } else {
      final sh = File('${_staged!.parent.parent.path}/apply.sh');
      sh.writeAsStringSync('''#!/bin/sh
while kill -0 $pid 2>/dev/null; do sleep 0.2; done
cp -rf "$src/." "$dst/" && chmod +x "$dst/rates"
${restart ? '(cd "$dst" && nohup ./rates >/dev/null 2>&1 &)' : ''}
''');
      await Process.start('sh', [sh.path], mode: ProcessStartMode.detached);
    }
    state = UpState.installing;
    notifyListeners();
  }

  // ------------------------------------------------------------------ Android
  Future<void> installAndroid() async {
    if (_assetUrl == null || state == UpState.downloading) return;
    state = UpState.downloading;
    progress = 0;
    notifyListeners();
    try {
      OtaUpdate().execute(_assetUrl!, destinationFilename: 'Rates-$version.apk').listen((e) {
        final st = e.status.toString();
        if (st.contains('ERROR')) {
          state = UpState.failed;
        } else if (st.contains('DOWNLOADING')) {
          progress = (double.tryParse(e.value ?? '') ?? 0) / 100;
        } else {
          state = UpState.idle; // установщик открыт — дальше решает человек
        }
        notifyListeners();
      }, onError: (_) {
        state = UpState.failed;
        notifyListeners();
      });
    } catch (_) {
      state = UpState.failed;
      notifyListeners();
    }
  }
}
