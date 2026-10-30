import 'package:flutter_test/flutter_test.dart';
import 'package:rates/data.dart';

void main() {
  test('fmt — как на сайте', () {
    expect(fmt(1000), '1 000');
    expect(fmt(30.86), '30,86');
    expect(fmt(0.0309), '0,0309');
    expect(fmt(2.5, ru: false), '2.5');
    expect(parseAmount('10 000,5'), 10000.5);
  });

  group('источники курсов', () {
    const now = 1793300000;
    SourceRates src(Map<String, double> m, int ts) => SourceRates({...m, 'USD': 1.0}, ts);

    test('медиана гасит ошибку одного источника', () {
      final r = combine({
        'a': src({'THB': 33.7, 'RUB': 80.5}, now),
        'b': src({'THB': 33.8, 'RUB': 80.4}, now),
        'c': src({'THB': 99.0, 'RUB': 80.6}, now), // ошибся
      }, now: now);
      expect(r.perUsd['THB'], 33.8);
      expect(r.perUsd['RUB'], 80.5);
      expect(r.perUsd['USD'], 1.0);
      expect(r.src.length, 3);
    });

    test('застрявший источник отбрасывается', () {
      final r = combine({
        'site': src({'THB': 36.0}, now - 10 * 86400), // сайт завис 10 дней назад
        'fresh': src({'THB': 33.7}, now),
      }, now: now);
      expect(r.perUsd['THB'], 33.7);
      expect(r.src, ['fresh']);
      expect(r.dataTs, now);
      expect(r.ts, now);
    });

    test('валюты объединяются из всех источников', () {
      final r = combine({
        'a': src({'THB': 33.7, 'GEL': 2.7}, now),
        'b': src({'THB': 33.7, 'VND': 26000}, now),
      }, now: now);
      expect(r.has('GEL') && r.has('VND'), true);
    });

    test('никто не ответил — ошибка, а не пустой курс', () {
      expect(() => combine({}), throwsException);
    });

    test('разбор ответов', () {
      final er = sources.firstWhere((s) => s.name == 'ExchangeRate-API').parse(
          {'result': 'success', 'time_last_update_unix': now, 'rates': {'USD': 1, 'THB': 33.77, 'RUB': 80.5}})!;
      expect(er.perUsd['THB'], 33.77);
      expect(er.ts, now);

      final fw = sources.firstWhere((s) => s.name == 'Currency API').parse(
          {'date': '2026-10-29', 'usd': {'thb': 33.74, 'rub': 80.49, '1inch': 5.0}})!;
      expect(fw.perUsd['THB'], 33.74);
      expect(fw.perUsd.containsKey('1INCH'), false);
      expect(fw.ts > 0, true);

      final cbr = sources.firstWhere((s) => s.name == 'ЦБ РФ').parse(
          {'date': '2026-10-30', 'timestamp': now, 'base': 'RUB', 'rates': {'USD': 0.0125, 'THB': 0.42}})!;
      expect(cbr.perUsd['RUB'], closeTo(80.0, 1e-9));
      expect(cbr.perUsd['THB'], closeTo(33.6, 1e-9));

      final fr = sources.firstWhere((s) => s.name == 'FloatRates').parse({
        'thb': {'code': 'THB', 'rate': 33.7, 'date': 'Thu, 29 Oct 2026 23:55:01 GMT'},
        'rub': {'code': 'RUB', 'rate': 80.4, 'date': 'Thu, 29 Oct 2026 23:55:01 GMT'},
      })!;
      expect(fr.perUsd['RUB'], 80.4);
      expect(fr.ts > 0, true);

      final ecb = sources.firstWhere((s) => s.name == 'ЕЦБ').parse({'base': 'USD', 'date': '2026-10-29', 'rates': {'THB': 33.7}})!;
      expect(ecb.perUsd['THB'], 33.7);
    });
  });
}
