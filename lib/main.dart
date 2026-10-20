// Курс валют by kolobas58 — бат, доллар, СНГ и весь мир. Windows · Linux · Android.
import 'package:flutter/material.dart';

import 'data.dart';
import 'home.dart';

const brand = Color(0xFF128C7E);
const brandDark = Color(0xFF1FB59F);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.open();
  final currencies = await loadCurrencies();
  runApp(RatesApp(store: store, currencies: currencies));
}

class RatesApp extends StatefulWidget {
  final Store store;
  final List<Currency> currencies;
  const RatesApp({super.key, required this.store, required this.currencies});

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
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: {'light': ThemeMode.light, 'dark': ThemeMode.dark}[theme] ?? ThemeMode.system,
      home: HomePage(store: widget.store, currencies: widget.currencies, theme: theme, onTheme: _cycleTheme),
    );
  }
}
