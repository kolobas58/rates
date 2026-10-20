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
}
