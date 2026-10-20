// Данные: список валют (из assets), курсы с kolobas58.club/api/rates, сохранение настроек и последнего курса.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const apiUrl = 'https://kolobas58.club/api/rates';
const siteUrl = 'https://kolobas58.club/rates';
const appVersion = '1.2.1';
const maxFavs = 8;

class Currency {
  final String code, sym, ru, en, grp, q;
  const Currency(this.code, this.sym, this.ru, this.en, this.grp, this.q);

  factory Currency.fromJson(Map<String, dynamic> j) => Currency(
        j['code'] as String,
        _safeSym(j['sym'] as String, j['code'] as String),
        j['ru'] as String,
        j['en'] as String,
        j['grp'] as String,
        (j['q'] as String? ?? '').replaceAll('ё', 'е'),
      );

  String name(bool ru) => ru ? this.ru : en;
}

/// Знак валюты — только если его точно нарисуют стандартные шрифты Windows/Linux/Android
/// (латиница, кириллица, блок знаков валют U+20A0–U+20CF и ¢£¥). Иначе показываем код: ֏, ៛, ریال и т. п. выходят «квадратиками».
String _safeSym(String sym, String code) {
  for (final r in sym.runes) {
    final ok = (r >= 0x20 && r <= 0x7E) || (r >= 0xA2 && r <= 0xA5) || (r >= 0x0400 && r <= 0x04FF) ||
        (r >= 0x20A0 && r <= 0x20CF) || r == 0x0E3F || r == 0x02BB;
    if (!ok) return code;
  }
  return sym;
}

class Rates {
  final Map<String, double> perUsd; // сколько единиц валюты за 1 доллар
  final int ts; // когда сайт получил курс (unix, сек)
  final List<String> src;
  const Rates(this.perUsd, this.ts, this.src);

  factory Rates.fromJson(Map<String, dynamic> j) {
    final p = <String, double>{};
    final raw = j['per_usd'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is num && v > 0) p[k.toString()] = v.toDouble();
      });
    }
    final src = (j['src'] is List) ? (j['src'] as List).map((e) => e.toString()).toList() : <String>[];
    return Rates(p, (j['ts'] is num) ? (j['ts'] as num).toInt() : 0, src);
  }

  Map<String, dynamic> toJson() => {'per_usd': perUsd, 'ts': ts, 'src': src};

  bool has(String c) => perUsd.containsKey(c);

  double conv(double v, String from, String to) => v / perUsd[from]! * perUsd[to]!;
}

Future<List<Currency>> loadCurrencies() async {
  final raw = await rootBundle.loadString('assets/currencies.json');
  return (jsonDecode(raw) as List).map((e) => Currency.fromJson(e as Map<String, dynamic>)).toList();
}

Future<Rates> fetchRates() async {
  final r = await http
      .get(Uri.parse(apiUrl), headers: {'User-Agent': 'kolobas58-rates-app/$appVersion', 'Accept': 'application/json'})
      .timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  final rates = Rates.fromJson(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
  if (!rates.has('THB') || !rates.has('USD')) throw Exception('empty');
  return rates;
}

/// Всё, что приложение помнит между запусками.
class Store {
  final SharedPreferences p;
  Store(this.p);

  static Future<Store> open() async => Store(await SharedPreferences.getInstance());

  Rates? get rates {
    final s = p.getString('rates');
    if (s == null) return null;
    try {
      final r = Rates.fromJson(jsonDecode(s) as Map<String, dynamic>);
      return r.has('THB') ? r : null;
    } catch (_) {
      return null;
    }
  }

  set rates(Rates? r) => r == null ? p.remove('rates') : p.setString('rates', jsonEncode(r.toJson()));

  /// Две основные валюты — крупные зелёные плитки (по умолчанию доллар и бат).
  List<String> get mains {
    final v = p.getStringList('mains');
    return (v != null && v.length == 2 && v[0] != v[1]) ? v : const ['USD', 'THB'];
  }

  set mains(List<String> v) => p.setStringList('mains', v);

  List<String> get favs => p.getStringList('favs') ?? const [];
  set favs(List<String> v) => p.setStringList('favs', v);

  double? get amount => p.getDouble('amount');
  set amount(double? v) => v == null ? p.remove('amount') : p.setDouble('amount', v);

  String? get base => p.getString('base');
  set base(String? v) => v == null ? p.remove('base') : p.setString('base', v);

  String? get from => p.getString('from');
  set from(String? v) => v == null ? p.remove('from') : p.setString('from', v);

  bool get worldOpen => p.getBool('world') ?? false;
  set worldOpen(bool v) => p.setBool('world', v);

  /// 'ru' | 'en' — по умолчанию русский (сайт и аудитория русскоязычные)
  String get lang => p.getString('lang') ?? 'ru';
  set lang(String v) => p.setString('lang', v);

  /// 'system' | 'light' | 'dark'
  String get theme => p.getString('theme') ?? 'system';
  set theme(String v) => p.setString('theme', v);
}

// ---------------------------------------------------------------- форматирование, как на сайте

String fmt(double v, {bool ru = true}) {
  final a = v.abs();
  final d = a >= 100 ? 0 : a >= 1 ? 2 : a >= 0.01 ? 4 : 6;
  var s = v.toStringAsFixed(d);
  if (d > 0) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  final parts = s.split('.');
  final neg = parts[0].startsWith('-');
  var int_ = neg ? parts[0].substring(1) : parts[0];
  final b = StringBuffer();
  for (var i = 0; i < int_.length; i++) {
    if (i > 0 && (int_.length - i) % 3 == 0) b.write(' ');
    b.write(int_[i]);
  }
  int_ = (neg ? '-' : '') + b.toString();
  return parts.length > 1 ? '$int_${ru ? ',' : '.'}${parts[1]}' : int_;
}

double parseAmount(String s) {
  final v = double.tryParse(s.replaceAll(RegExp(r'[\s ]'), '').replaceAll(',', '.'));
  return (v == null || v.isNaN || v.isInfinite || v < 0) ? 0 : v;
}
