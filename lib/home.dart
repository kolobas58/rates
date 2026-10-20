// Главный экран — как страница kolobas58.club/rates:
// сумма → доллар и бат → избранное (★) → свёрнутый «Остальной мир» (поиск, СНГ, все страны).
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';

const _star = Color(0xFFF5A524);

class HomePage extends StatefulWidget {
  final Store store;
  final List<Currency> currencies;
  final String theme;
  final VoidCallback onTheme;
  const HomePage({super.key, required this.store, required this.currencies, required this.theme, required this.onTheme});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final Map<String, Currency> byCode = {for (final c in widget.currencies) c.code: c};
  late final bool ru = const {'ru', 'uk', 'be', 'kk', 'ky', 'uz', 'tg', 'hy', 'az'}
      .contains(ui.PlatformDispatcher.instance.locale.languageCode);
  final amountCtl = TextEditingController();
  final searchCtl = TextEditingController();
  final amountFocus = FocusNode();

  Rates? rates;
  bool loading = false;
  String? error; // последняя ошибка загрузки (если показываем сохранённый курс)
  String from = 'THB';
  String baseCode = 'THB';
  double baseV = 1000;
  List<String> favs = [];
  bool worldOpen = false;
  String query = '';
  Timer? timer;

  String t(String r, String e) => ru ? r : e;
  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    rates = store.rates;
    favs = store.favs.where((c) => byCode.containsKey(c) && c != 'USD' && c != 'THB').take(maxFavs).toList();
    worldOpen = store.worldOpen;
    final a = store.amount, b = store.base, f = store.from;
    if (a != null && a > 0 && b != null && byCode.containsKey(b)) {
      baseV = a;
      baseCode = b;
    }
    from = (f != null && byCode.containsKey(f)) ? f : baseCode;
    _syncInput();
    amountFocus.addListener(() {
      setState(() {});
      if (amountFocus.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          amountCtl.selection = TextSelection(baseOffset: 0, extentOffset: amountCtl.text.length);
        });
      } else {
        _syncInput();
      }
    });
    _refresh();
    timer = Timer.periodic(const Duration(minutes: 5), (_) => _refresh(quiet: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh(quiet: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    amountCtl.dispose();
    searchCtl.dispose();
    amountFocus.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool quiet = false}) async {
    if (loading) return;
    if (rates != null && quiet && DateTime.now().millisecondsSinceEpoch / 1000 - rates!.ts < 240) return;
    setState(() => loading = true);
    try {
      final r = await fetchRates();
      store.rates = r;
      if (!mounted) return;
      setState(() {
        rates = r;
        error = null;
        if (!r.has(from)) from = 'THB';
        if (!r.has(baseCode)) {
          baseCode = 'THB';
          baseV = 1000;
        }
      });
      _syncInput();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ---------------------------------------------------------------- счёт от введённой суммы (без накопления округлений)
  bool has(String c) => rates?.has(c) ?? false;
  double get amount => (baseCode == from || rates == null) ? baseV : rates!.conv(baseV, baseCode, from);
  double conv(double v, String a, String b) => rates!.conv(v, a, b);
  String f(double v) => fmt(v, ru: ru);

  void _syncInput() {
    final s = baseV > 0 ? f(amount) : '0';
    amountCtl.value = TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));
  }

  void _onType(String s) {
    setState(() {
      baseV = parseAmount(s);
      baseCode = from;
    });
    store.amount = baseV;
    store.base = baseCode;
  }

  void _setFrom(String c) {
    if (!has(c)) return;
    setState(() => from = c);
    store.from = c;
    _syncInput();
  }

  void _toggleFav(String c) {
    setState(() {
      if (favs.contains(c)) {
        favs.remove(c);
      } else if (favs.length < maxFavs) {
        favs.add(c);
      } else {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(t('В избранном уже $maxFavs валют — уберите одну.', 'Favourites are full ($maxFavs).'))));
      }
    });
    store.favs = favs;
  }

  List<Currency> _group(String g) {
    final list = widget.currencies.where((c) => c.grp == g && has(c.code)).toList();
    list.sort((a, b) => rates!.perUsd[a.code]!.compareTo(rates!.perUsd[b.code]!)); // дорогие сверху, «лесенкой»
    return list;
  }

  bool _match(Currency c) {
    if (query.isEmpty) return true;
    final hay = c.q;
    return query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  String unit(String c) {
    final ref = c == 'THB' ? 'USD' : 'THB';
    final rs = byCode[ref]!.sym;
    return '1 $c = ${f(conv(1, c, ref))} $rs  ·  1 $rs = ${f(conv(1, ref, c))} $c';
  }

  String _updated() {
    final r = rates!;
    final d = DateTime.fromMillisecondsSinceEpoch(r.ts * 1000);
    String two(int x) => x.toString().padLeft(2, '0');
    final when = '${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
    final src = r.src.map((s) => s == 'ЦБ РФ' && !ru ? 'Bank of Russia' : s).join(', ');
    return '${t('Обновлено', 'Updated')} $when${src.isNotEmpty ? '  ·  ${t('Источник', 'Source')}: $src' : ''}';
  }

  // ---------------------------------------------------------------- экран
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 640;
            final pad = wide ? 24.0 : 14.0;
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(pad, pad, pad, pad + 8),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _header(cs),
                    const SizedBox(height: 14),
                    if (rates == null) _empty(cs) else ..._body(cs, wide, box.maxWidth - pad * 2),
                  ]),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _header(ColorScheme cs) {
    final themeIcon = {'dark': Icons.dark_mode_outlined, 'light': Icons.light_mode_outlined}[widget.theme] ?? Icons.brightness_auto_outlined;
    return Row(children: [
      Expanded(
        child: Text(t('Курс валют', 'Exchange rates'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
      ),
      if (loading) const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      if (!loading)
        IconButton(tooltip: t('Обновить курс', 'Refresh'), onPressed: _refresh, icon: const Icon(Icons.refresh)),
      IconButton(tooltip: t('Тема', 'Theme'), onPressed: widget.onTheme, icon: Icon(themeIcon)),
    ]);
  }

  Widget _empty(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(children: [
        if (loading) const CircularProgressIndicator() else Icon(Icons.cloud_off, size: 40, color: cs.outline),
        const SizedBox(height: 14),
        Text(
          loading ? t('Загружаю курс…', 'Loading rates…') : t('Нет связи с сервером курсов. Проверьте интернет.', 'Can’t reach the rates server. Check your connection.'),
          textAlign: TextAlign.center,
        ),
        if (!loading) ...[
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _refresh, icon: const Icon(Icons.refresh), label: Text(t('Повторить', 'Retry'))),
        ],
      ]),
    );
  }

  List<Widget> _body(ColorScheme cs, bool wide, double width) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final soft = cs.primary.withOpacity(dark ? .16 : .10);
    final grey = (dark ? Colors.white : Colors.black).withOpacity(.05);
    final shownFavs = favs.where(has).toList();
    return [
      _amountField(cs, soft),
      const SizedBox(height: 12),
      _cards(['USD', 'THB'], soft, cs, wide),
      if (shownFavs.isNotEmpty) ...[const SizedBox(height: 12), _cards(shownFavs, grey, cs, wide)],
      if (shownFavs.isEmpty) ...[
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.star_border, size: 16, color: _star),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              t('Нужна другая валюта под рукой? Откройте «Остальной мир» и нажмите на звёздочку — она встанет сюда.',
                  'Need another currency at hand? Open “Rest of the world” and tap the star — it will be pinned here.'),
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
        ]),
      ],
      const SizedBox(height: 12),
      _world(cs, soft, width),
      const SizedBox(height: 12),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(Icons.cloud_off, size: 15, color: cs.error),
            const SizedBox(width: 6),
            Expanded(child: Text(t('Нет связи — показан последний сохранённый курс.', 'Offline — showing the last saved rates.'), style: TextStyle(fontSize: 12.5, color: cs.error))),
          ]),
        ),
      Text(_updated(), style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: grey, borderRadius: BorderRadius.circular(12)),
        child: Text(
          t('Курс справочный: в обменниках Паттайи он обычно отличается на 1–3%. Нажмите на любую валюту — сумма станет в ней.',
              'Reference rates: exchange offices in Pattaya usually differ by 1–3%. Tap any currency to enter the amount in it.'),
          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
        ),
      ),
      const SizedBox(height: 10),
      Center(child: Text('kolobas58.club  ·  v$appVersion', style: TextStyle(fontSize: 11.5, color: cs.outline))),
    ];
  }

  Widget _amountField(ColorScheme cs, Color soft) {
    final c = byCode[from]!;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 4, 6, 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: amountFocus.hasFocus ? cs.primary : cs.outlineVariant),
      ),
      child: Row(children: [
        Expanded(
          child: TextField(
              controller: amountCtl,
              focusNode: amountFocus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s .,]'))],
              onChanged: _onType,
              style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w300, fontFeatures: [ui.FontFeature.tabularFigures()]),
              decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)),
          ),
        ),
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(13)),
          alignment: Alignment.center,
          child: Text('${c.sym} ${c.code}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: cs.primary)),
        ),
      ]),
    );
  }

  /// Крупные плитки: доллар и бат (зелёные), избранное (серые). На широком экране — по две в ряд.
  Widget _cards(List<String> codes, Color bg, ColorScheme cs, bool wide) {
    final tiles = codes.map((c) => _bigTile(c, bg, cs, wide)).toList();
    if (!wide) {
      return Column(children: [for (var i = 0; i < tiles.length; i++) ...[if (i > 0) const SizedBox(height: 10), tiles[i]]]);
    }
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: 12));
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: tiles[i]),
          const SizedBox(width: 12),
          Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox()),
        ]),
      ));
    }
    return Column(children: rows);
  }

  Widget _bigTile(String code, Color bg, ColorScheme cs, bool wide) {
    final c = byCode[code]!;
    final on = code == from;
    final v = conv(amount, from, code);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _setFrom(code),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: wide ? 18 : 14, vertical: wide ? 14 : 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: on ? cs.primary : Colors.transparent, width: 2),
          ),
          child: Row(children: [
            _symCircle(c.sym, wide ? 52 : 42, cs, bg: Theme.of(context).colorScheme.surface),
            const SizedBox(width: 14),
            Expanded(
              flex: 5,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.name(ru), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(unit(code), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(width: 10),
            Flexible(
              flex: 6,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text('${f(v)} ${c.sym}',
                    style: TextStyle(fontSize: wide ? 34 : 26, fontWeight: FontWeight.w300, fontFeatures: const [ui.FontFeature.tabularFigures()])),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _symCircle(String sym, double size, ColorScheme cs, {Color? bg}) {
    final long = sym.length > 1;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: bg ?? cs.primary.withOpacity(.12)),
      child: Text(sym,
          maxLines: 1,
          style: TextStyle(fontSize: size * (long ? .3 : .46), fontWeight: FontWeight.w700, color: cs.primary, letterSpacing: long ? -.3 : 0)),
    );
  }

  // ---------------------------------------------------------------- «Остальной мир»
  Widget _world(ColorScheme cs, Color soft, double width) {
    final cis = _group('cis'), rest = _group('world');
    final total = cis.length + rest.length;
    final fc = cis.where(_match).toList(), fr = rest.where(_match).toList();
    final cols = (width / 320).floor().clamp(1, 3);
    return Container(
      decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () {
            setState(() => worldOpen = !worldOpen);
            store.worldOpen = worldOpen;
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(children: [
              Icon(Icons.public, size: 20, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(t('Остальной мир', 'Rest of the world'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
              Text('$total ${t('валют', 'currencies')}', style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              AnimatedRotation(turns: worldOpen ? .5 : 0, duration: const Duration(milliseconds: 180), child: Icon(Icons.expand_more, color: cs.onSurfaceVariant)),
            ]),
          ),
        ),
        if (worldOpen) ...[
          Divider(height: 1, color: cs.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: TextField(
              controller: searchCtl,
              onChanged: (s) => setState(() => query = s.toLowerCase().replaceAll('ё', 'е').trim()),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: t('Страна или валюта: Грузия, лари, GEL', 'Country or currency: Georgia, lari, GEL'),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          searchCtl.clear();
                          setState(() => query = '');
                        }),
              ),
            ),
          ),
          if (fc.isNotEmpty) ...[_groupTitle(t('СНГ', 'CIS'), cs), _columns(fc, cols, cs, soft)],
          if (fr.isNotEmpty) ...[_groupTitle(t('Все страны', 'All countries'), cs), _columns(fr, cols, cs, soft)],
          if (fc.isEmpty && fr.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
              child: Text(t('Ничего не нашли. Попробуйте название страны или код валюты из трёх букв.', 'Nothing found. Try a country name or a three-letter code.'),
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            ),
          const SizedBox(height: 8),
        ],
      ]),
    );
  }

  Widget _groupTitle(String s, ColorScheme cs) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
        child: Text(s.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: .8, color: cs.onSurfaceVariant)),
      );

  /// Колонки читаются сверху вниз — «лесенка» сохраняется.
  Widget _columns(List<Currency> list, int cols, ColorScheme cs, Color soft) {
    final per = (list.length / cols).ceil();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var k = 0; k < cols; k++)
          Expanded(
            child: Column(children: [
              for (final c in list.skip(k * per).take(per)) _row(c, cs, soft),
            ]),
          ),
      ]),
    );
  }

  Widget _row(Currency c, ColorScheme cs, Color soft) {
    final on = c.code == from;
    final fav = favs.contains(c.code);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Tooltip(
        message: '${c.name(ru)}\n${unit(c.code)}',
        waitDuration: const Duration(milliseconds: 600),
        child: Material(
          color: on ? soft : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _setFrom(c.code),
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: on ? cs.primary : Colors.transparent, width: 2),
              ),
              child: Row(children: [
                _symCircle(c.sym, 34, cs),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.code, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    Text(c.name(ru), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  ]),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text('${f(conv(amount, from, c.code))} ${c.sym}',
                        style: const TextStyle(fontSize: 16.5, fontFeatures: [ui.FontFeature.tabularFigures()])),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: fav ? t('Убрать из избранного', 'Remove from favourites') : t('В избранное', 'Add to favourites'),
                  onPressed: () => _toggleFav(c.code),
                  icon: Icon(fav ? Icons.star_rounded : Icons.star_border_rounded, color: fav ? _star : cs.outline, size: 22),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
