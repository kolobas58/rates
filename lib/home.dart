// Главный экран — как страница kolobas58.club/rates:
// сумма → две основные валюты (доллар и бат, меняются в «Остальном мире») → избранное (★) → «Остальной мир».
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'data.dart';

const _star = Color(0xFFF5A524);

class HomePage extends StatefulWidget {
  final Store store;
  final List<Currency> currencies;
  final String theme;
  final VoidCallback onTheme;
  final bool desktop; // Windows/Linux: своя полоска заголовка вместо рамки окна
  const HomePage({super.key, required this.store, required this.currencies, required this.theme, required this.onTheme, this.desktop = false});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final Map<String, Currency> byCode = {for (final c in widget.currencies) c.code: c};
  late bool ru = store.lang != 'en';
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
  List<String> mains = const ['USD', 'THB'];
  int? pickSlot; // меняем основную валюту № pickSlot — строки «Остального мира» становятся выбором
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
    mains = store.mains.every(byCode.containsKey) ? List.of(store.mains) : const ['USD', 'THB'];
    favs = store.favs.where((c) => byCode.containsKey(c) && !mains.contains(c)).take(maxFavs).toList();
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
        if (!r.has(from)) from = mains[1];
        if (!r.has(baseCode)) {
          baseCode = mains[1];
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

  /// Основная валюта № slot := code (если code — вторая основная, они меняются местами).
  void _setMain(int slot, String code) {
    setState(() {
      final m = List.of(mains);
      final other = 1 - slot;
      if (m[other] == code) m[other] = m[slot];
      m[slot] = code;
      mains = m;
      favs.removeWhere(mains.contains);
      pickSlot = null;
    });
    store.mains = mains;
    store.favs = favs;
  }

  void _resetMains() {
    setState(() {
      mains = const ['USD', 'THB'];
      favs.removeWhere(mains.contains);
      pickSlot = null;
    });
    store.mains = mains;
    store.favs = favs;
  }

  /// Группы «Остального мира»; основные валюты в списке не показываем (они и так наверху).
  List<Currency> _group(String g) {
    final list = widget.currencies
        .where((c) => (c.grp == g || (g == 'world' && c.grp == 'pin')) && has(c.code) && (pickSlot != null || !mains.contains(c.code)))
        .toList();
    list.sort((a, b) => rates!.perUsd[a.code]!.compareTo(rates!.perUsd[b.code]!)); // дорогие сверху, «лесенкой»
    return list;
  }

  bool _match(Currency c) {
    if (query.isEmpty) return true;
    final hay = c.q;
    return query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  String unit(String c) {
    final ref = c == mains[1] ? mains[0] : mains[1]; // всё меряем второй основной валютой, её саму — первой
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
    final content = RefreshIndicator(
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
                    if (!widget.desktop) ...[_header(cs), const SizedBox(height: 14)],
                    if (rates == null) _empty(cs) else ..._body(cs, wide, box.maxWidth - pad * 2),
                  ]),
                ),
              ),
            );
          }),
        );
    if (!widget.desktop) return Scaffold(body: SafeArea(child: content));
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant.withOpacity(.6))),
        child: Column(children: [_titleBar(cs), Expanded(child: content)]),
      ),
    );
  }

  /// Своя полоска заголовка (Windows/Linux): за неё окно таскается, справа — обновить, язык, тема, свернуть, закрыть.
  Widget _titleBar(ColorScheme cs) {
    final themeIcon = {'dark': Icons.dark_mode_outlined, 'light': Icons.light_mode_outlined}[widget.theme] ?? Icons.brightness_auto_outlined;
    Widget btn(IconData i, String tip, VoidCallback on, {bool danger = false}) => _BarButton(icon: i, tooltip: tip, onTap: on, danger: danger);
    return SizedBox(
      height: 40,
      child: Row(children: [
        Expanded(
          child: DragToMoveArea(
            child: Container(
              color: Colors.transparent,
              padding: const EdgeInsets.only(left: 16),
              alignment: Alignment.centerLeft,
              child: Text('฿  ${t('Курс валют', 'Exchange rates')}', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ),
          ),
        ),
        if (loading)
          const SizedBox(width: 40, child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))))
        else
          btn(Icons.refresh, t('Обновить курс', 'Refresh'), _refresh),
        _BarButton(
          label: ru ? 'RU' : 'EN',
          tooltip: t('Язык', 'Language'),
          onTap: () {
            setState(() => ru = !ru);
            store.lang = ru ? 'ru' : 'en';
            _syncInput();
          },
        ),
        btn(themeIcon, t('Тема', 'Theme'), widget.onTheme),
        btn(Icons.remove, t('Свернуть', 'Minimize'), () => windowManager.minimize()),
        btn(Icons.close, t('Закрыть', 'Close'), () => windowManager.close(), danger: true),
        const SizedBox(width: 4),
      ]),
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
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(44, 40), foregroundColor: cs.onSurfaceVariant),
        onPressed: () {
          setState(() => ru = !ru);
          store.lang = ru ? 'ru' : 'en';
          _syncInput();
        },
        child: Text(ru ? 'RU' : 'EN', style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
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
      _cards(mains, soft, cs, wide),
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
          t('Курс справочный: в банках и обменниках он обычно отличается на 1–3%. Нажмите на любую валюту — сумма станет в ней.',
              'Reference rates: banks and exchange offices usually differ by 1–3%. Tap any currency to enter the amount in it.'),
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

  /// Крупные плитки: основные валюты (зелёные), избранное (серые). На широком экране — по две в ряд.
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
              flex: 4,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.name(ru), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(unit(code), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(width: 10),
            Flexible(
              flex: 5,
              fit: FlexFit.tight,
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
            setState(() {
              worldOpen = !worldOpen;
              pickSlot = null;
            });
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
          _mainsBar(cs, soft),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
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

  /// «Основные: $ USD ✎  ฿ THB ✎» — смена крупных плиток. Нажал на валюту — строки ниже превращаются в выбор замены.
  Widget _mainsBar(ColorScheme cs, Color soft) {
    Widget chip(int i) {
      final c = byCode[mains[i]]!;
      final on = pickSlot == i;
      return Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 6),
        child: Material(
          color: on ? cs.primary : Theme.of(context).colorScheme.surface,
          shape: StadiumBorder(side: BorderSide(color: on ? cs.primary : cs.outlineVariant)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => setState(() => pickSlot = on ? null : i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${c.sym} ${c.code}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? cs.onPrimary : cs.onSurface)),
                const SizedBox(width: 6),
                Icon(Icons.edit_outlined, size: 14, color: on ? cs.onPrimary : cs.onSurfaceVariant),
              ]),
            ),
          ),
        ),
      );
    }

    final isDefault = mains[0] == 'USD' && mains[1] == 'THB';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Padding(
            padding: const EdgeInsets.only(right: 10, bottom: 6, left: 4),
            child: Text(t('ОСНОВНЫЕ:', 'MAIN:'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: .6, color: cs.onSurfaceVariant)),
          ),
          chip(0),
          chip(1),
        ]),
        if (pickSlot != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(10)),
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
              Text(t('Нажмите валюту, которая встанет вместо ${mains[pickSlot!]}.', 'Tap the currency to replace ${mains[pickSlot!]}.'),
                  style: TextStyle(fontSize: 12.5, color: cs.primary)),
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                onPressed: () => setState(() => pickSlot = null),
                child: Text(t('Отмена', 'Cancel')),
              ),
              if (!isDefault)
                TextButton(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                  onPressed: _resetMains,
                  child: Text(t('Вернуть доллар и бат', 'Back to dollar and baht')),
                ),
            ]),
          ),
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
          color: on && pickSlot == null ? soft : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => pickSlot != null ? _setMain(pickSlot!, c.code) : _setFrom(c.code),
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: on && pickSlot == null ? cs.primary : Colors.transparent, width: 2),
              ),
              child: Row(children: [
                _symCircle(c.sym, 34, cs),
                const SizedBox(width: 10),
                Expanded(
                  flex: 5,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.code, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    Text(c.name(ru), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  ]),
                ),
                const SizedBox(width: 6),
                Flexible(
                  flex: 4,
                  fit: FlexFit.tight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text('${f(conv(amount, from, c.code))} ${c.sym}',
                        style: const TextStyle(fontSize: 16.5, fontFeatures: [ui.FontFeature.tabularFigures()])),
                  ),
                ),
                if (pickSlot != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, right: 8),
                    child: mains[pickSlot!] == c.code
                        ? Text(t('сейчас', 'current'), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
                        : Text(t('выбрать', 'choose'), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: cs.primary)),
                  )
                else
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


class _BarButton extends StatefulWidget {
  final IconData? icon;
  final String? label;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;
  const _BarButton({this.icon, this.label, required this.tooltip, required this.onTap, this.danger = false});

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = !hover ? Colors.transparent : (widget.danger ? const Color(0xFFE5484D) : cs.onSurface.withOpacity(.08));
    final fg = hover && widget.danger ? Colors.white : cs.onSurfaceVariant;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 40,
            height: 30,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
            child: widget.icon != null
                ? Icon(widget.icon, size: 17, color: fg)
                : Text(widget.label!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: fg)),
          ),
        ),
      ),
    );
  }
}
