// Данные: список валют (из assets), курсы из нескольких независимых источников, сохранение настроек и последнего курса.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const apiUrl = 'https://kolobas58.club/api/rates';
const siteUrl = 'https://kolobas58.club/rates';
const appVersion = '1.3.0';
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
  final int ts; // когда приложение получило курс (unix, сек)
  final int dataTs; // насколько свежие данные у источников (самый свежий из использованных)
  final List<String> src;
  const Rates(this.perUsd, this.ts, this.src, [int? dataTs]) : dataTs = dataTs ?? ts;

  factory Rates.fromJson(Map<String, dynamic> j) {
    final p = <String, double>{};
    final raw = j['per_usd'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is num && v > 0) p[k.toString()] = v.toDouble();
      });
    }
    final src = (j['src'] is List) ? (j['src'] as List).map((e) => e.toString()).toList() : <String>[];
    final ts = (j['ts'] is num) ? (j['ts'] as num).toInt() : 0;
    return Rates(p, ts, src, (j['data_ts'] is num) ? (j['data_ts'] as num).toInt() : ts);
  }

  Map<String, dynamic> toJson() => {'per_usd': perUsd, 'ts': ts, 'data_ts': dataTs, 'src': src};

  bool has(String c) => perUsd.containsKey(c);

  double conv(double v, String from, String to) => v / perUsd[from]! * perUsd[to]!;
}

Future<List<Currency>> loadCurrencies() async {
  final raw = await rootBundle.loadString('assets/currencies.json');
  return (jsonDecode(raw) as List).map((e) => Currency.fromJson(e as Map<String, dynamic>)).toList();
}

// ================================================================ источники курсов
// Опрашиваем все сразу. Каждый может упасть, отдать старьё или ошибиться — поэтому:
//  • берём только тех, чьи данные не старше самого свежего источника на [maxLag];
//  • по каждой валюте — медиана всех источников (одна ошибка не сдвинет курс).

const maxLag = Duration(hours: 48);
const _timeout = Duration(seconds: 12);

/// Ответ одного источника, приведённый к виду «сколько единиц валюты за 1 доллар».
class SourceRates {
  final Map<String, double> perUsd;
  final int ts; // свежесть данных источника (unix, сек)
  const SourceRates(this.perUsd, this.ts);
}

class RateSource {
  final String name;
  final List<String> urls; // зеркала — по очереди, до первого удачного
  final SourceRates? Function(dynamic json) parse;
  const RateSource(this.name, this.urls, this.parse);
}

final _code = RegExp(r'^[A-Z]{3}$');
int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// «2026-10-29» → unix (полдень UTC того дня — честная середина для дневных курсов)
int _day(Object? d) {
  if (d is! String) return 0;
  final t = DateTime.tryParse('${d.trim()}T12:00:00Z');
  return t == null ? 0 : t.millisecondsSinceEpoch ~/ 1000;
}

Map<String, double> _clean(Map raw, {bool upper = false}) {
  final out = <String, double>{};
  raw.forEach((k, v) {
    final c = upper ? k.toString().toUpperCase() : k.toString();
    if (v is num && v > 0 && v.isFinite && _code.hasMatch(c)) out[c] = v.toDouble();
  });
  out['USD'] = 1.0;
  return out;
}

final sources = <RateSource>[
  // свой сайт
  RateSource('kolobas58.club', [apiUrl], (j) {
    final r = Rates.fromJson(j as Map<String, dynamic>);
    return r.perUsd.isEmpty ? null : SourceRates(_clean(r.perUsd), r.ts);
  }),
  // ExchangeRate-API (открытый, без ключа), ~166 валют, раз в сутки
  RateSource('ExchangeRate-API', ['https://open.er-api.com/v6/latest/USD'], (j) {
    if (j is! Map || j['result'] != 'success' || j['rates'] is! Map) return null;
    return SourceRates(_clean(j['rates'] as Map), (j['time_last_update_unix'] as num?)?.toInt() ?? 0);
  }),
  // Currency API (fawazahmed0), ~400 валют, раз в сутки, два зеркала
  RateSource('Currency API', [
    'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json',
    'https://latest.currency-api.pages.dev/v1/currencies/usd.json',
  ], (j) {
    if (j is! Map || j['usd'] is! Map) return null;
    return SourceRates(_clean(j['usd'] as Map, upper: true), _day(j['date']));
  }),
  // FloatRates, ~150 валют, дважды в сутки
  RateSource('FloatRates', ['https://www.floatrates.com/daily/usd.json'], (j) {
    if (j is! Map) return null;
    final m = <String, double>{};
    var ts = 0;
    for (final e in j.values) {
      if (e is! Map) continue;
      final c = e['code']?.toString().toUpperCase() ?? '', r = e['rate'];
      if (r is num && r > 0) m[c] = r.toDouble();
      if (ts == 0 && e['date'] is String) {
        try {
          ts = HttpDate.parse(e['date'] as String).millisecondsSinceEpoch ~/ 1000;
        } catch (_) {}
      }
    }
    return m.isEmpty ? null : SourceRates(_clean(m), ts);
  }),
  // Frankfurter — официальные курсы ЕЦБ, ~30 валют
  RateSource('ЕЦБ', ['https://api.frankfurter.app/latest?from=USD'], (j) {
    if (j is! Map || j['rates'] is! Map) return null;
    return SourceRates(_clean(j['rates'] as Map), _day(j['date']));
  }),
  // ЦБ РФ — официальный курс рубля (база — рубль: сколько валюты за 1 ₽)
  RateSource('ЦБ РФ', ['https://www.cbr-xml-daily.ru/latest.js'], (j) {
    if (j is! Map || j['rates'] is! Map) return null;
    final perRub = j['rates'] as Map;
    final usd = perRub['USD'];
    if (usd is! num || usd <= 0) return null;
    final m = <String, double>{'RUB': 1 / usd};
    perRub.forEach((k, v) {
      if (v is num && v > 0) m[k.toString()] = v / usd;
    });
    final ts = (j['timestamp'] as num?)?.toInt() ?? _day(j['date']);
    return SourceRates(_clean(m), ts > _nowSec() ? _nowSec() : ts); // ЦБ ставит курс «на завтра»
  }),
];

double _median(List<double> v) {
  v.sort();
  final n = v.length;
  return n.isOdd ? v[n ~/ 2] : (v[n ~/ 2 - 1] + v[n ~/ 2]) / 2;
}

/// Сводит ответы источников в один курс. Чистая функция — проверяется тестами.
Rates combine(Map<String, SourceRates> got, {int? now}) {
  final live = Map.of(got)..removeWhere((_, r) => r.ts <= 0 || !r.perUsd.containsKey('THB'));
  if (live.isEmpty) throw Exception('нет данных ни от одного источника');
  final newest = live.values.map((r) => r.ts).reduce((a, b) => a > b ? a : b);
  live.removeWhere((_, r) => newest - r.ts > maxLag.inSeconds); // застрявший источник не тянет курс в прошлое
  final codes = <String>{for (final r in live.values) ...r.perUsd.keys};
  final per = <String, double>{};
  for (final c in codes) {
    final vals = [for (final r in live.values) if (r.perUsd[c] != null) r.perUsd[c]!];
    if (vals.isNotEmpty) per[c] = _median(vals);
  }
  per['USD'] = 1.0;
  return Rates(per, now ?? _nowSec(), live.keys.toList(), newest);
}

Future<SourceRates?> _fetchOne(RateSource s) async {
  for (final url in s.urls) {
    try {
      final r = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'kolobas58-rates-app/$appVersion',
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
      }).timeout(_timeout);
      if (r.statusCode != 200) continue;
      final res = s.parse(jsonDecode(utf8.decode(r.bodyBytes)));
      if (res != null && res.perUsd.length > 1) return res;
    } catch (_) {}
  }
  return null;
}

/// Все источники параллельно; курс — если ответил хотя бы один.
Future<Rates> fetchRates() async {
  final res = await Future.wait(sources.map(_fetchOne));
  final got = <String, SourceRates>{
    for (var i = 0; i < sources.length; i++)
      if (res[i] != null) sources[i].name: res[i]!,
  };
  final rates = combine(got);
  if (!rates.has('THB')) throw Exception('empty');
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
