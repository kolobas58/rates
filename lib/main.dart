// Курс валют by kolobas58 — бат, доллар, СНГ и весь мир. Windows · Linux · Android.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'data.dart';
import 'home.dart';
import 'updater.dart';

const brand = Color(0xFF128C7E);
const brandDark = Color(0xFF1FB59F);
final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (desktop) {
    // окно без системной рамки — своя полоска заголовка (как у Speedtest)
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(520, 860),
        minimumSize: Size(380, 520),
        center: true,
        title: 'Курс валют',
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  final store = await Store.open();
  final currencies = await loadCurrencies();
  final updater = Updater()..start();
  if (desktop) await windowManager.setPreventClose(true); // закрытие ловит HomePage: сначала подменить файлы, если обновление скачано
  runApp(RatesApp(store: store, currencies: currencies, updater: updater));
}

class RatesApp extends StatefulWidget {
  final Store store;
  final List<Currency> currencies;
  final Updater updater;
  const RatesApp({super.key, required this.store, required this.currencies, required this.updater});

  @override
  State<RatesApp> createState() => _RatesAppState();
}

class _RatesAppState extends State<RatesApp> {
  late String theme = widget.store.theme;

  ThemeData _theme(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: brand, brightness: b).copyWith(
      primary: dark ? brandDark : brand,
      surface: dark ? const Color(0xFF1E2221) : Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? const Color(0xFF121615) : const Color(0xFFF2F5F4),
      fontFamilyFallback: const ['Segoe UI', 'Roboto', 'Noto Sans', 'DejaVu Sans'],
    );
  }

  void _cycleTheme() {
    final next = {'system': 'dark', 'dark': 'light', 'light': 'system'}[theme]!;
    setState(() => theme = next);
    widget.store.theme = next;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Курс валют',
      debugShowCheckedModeBanner: false,
      // на Linux у окна без рамки края не тянутся сами — даём тянуть за край
      builder: (context, child) => Platform.isLinux ? DragToResizeArea(resizeEdgeSize: 6, child: child!) : child!,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: {'light': ThemeMode.light, 'dark': ThemeMode.dark}[theme] ?? ThemeMode.system,
      home: HomePage(store: widget.store, currencies: widget.currencies, theme: theme, onTheme: _cycleTheme, desktop: desktop, updater: widget.updater),
    );
  }
}
