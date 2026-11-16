import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../theme.dart';
import '../util/fields.dart';
import '../widgets/tiles.dart';
import 'finance_store.dart';

/// The chart's time ranges, as in Asset Track.
const _intervals = {
  '1W': (days: 7, label: 'Past week'),
  '1M': (days: 30, label: 'Past month'),
  '3M': (days: 90, label: 'Past 3 months'),
  '1Y': (days: 365, label: 'Past year'),
  'All': (days: 0, label: 'All time'),
};

enum _Tab { overview, spending, investing, gas, history }

/// Everything in Asset Track, in tiles: net worth and accounts, spending,
/// investments, gas and the full snapshot history.
class NetWorthPage extends StatefulWidget {
  const NetWorthPage({super.key, required this.store, this.active = true});

  final FinanceStore store;

  /// Whether this tab is showing; account balances are only fetched once it is.
  final bool active;

  @override
  State<NetWorthPage> createState() => _NetWorthPageState();
}

/// Whether amounts are masked, shared by the page and the dashboard.
final hideAmounts = ValueNotifier<bool>(false);
const _hiddenKey = 'optimizer.hideAmounts';

Future<void> loadHideAmounts() async {
  try {
    hideAmounts.value = (await SharedPreferences.getInstance()).getBool(_hiddenKey) ?? false;
  } catch (_) {}
}

String money(num v) => hideAmounts.value ? r'$•••••' : moneyFormat.format(v);
String signedMoney(num v) => hideAmounts.value ? '•••••' : '${v >= 0 ? '+' : '−'}${moneyFormat.format(v.abs())}';
Color changeColor(num v) => v > 0 ? AppColors.positive : (v < 0 ? AppColors.danger : AppColors.secondaryText);

class _NetWorthPageState extends State<NetWorthPage> {
  FinanceStore get store => widget.store;
  _Tab _tab = _Tab.overview;
  String _interval = '1M';
  int? _hover;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  int _txnsShown = 40;
  final _expanded = <String>{};
  final _historyScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    hideAmounts.addListener(_changed);
    if (widget.active) store.loadAccounts();
  }

  @override
  void didUpdateWidget(NetWorthPage old) {
    super.didUpdateWidget(old);
    if (widget.active) store.loadAccounts();
  }

  @override
  void dispose() {
    store.removeListener(_changed);
    hideAmounts.removeListener(_changed);
    _historyScroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _toggleHidden() {
    hideAmounts.value = !hideAmounts.value;
    SharedPreferences.getInstance().then((p) => p.setBool(_hiddenKey, hideAmounts.value), onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    if (store.error != null && store.points.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            'Couldn’t read ${AxisSchema.netWorthPath(store.uid)}\n${store.error}\n\nCheck your Firestore rules.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (!store.snapshotsLoaded || (store.waitingForKey && store.points.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }

    final bar = PageTabsHeader<_Tab>(
      items: const [
        (_Tab.overview, 'Overview'),
        (_Tab.spending, 'Spending'),
        (_Tab.investing, 'Investing'),
        (_Tab.gas, 'Gas'),
        (_Tab.history, 'History'),
      ],
      selected: _tab,
      onSelected: (t) => setState(() => _tab = t),
      actions: [
        IconButton(
          tooltip: hideAmounts.value ? 'Show amounts' : 'Hide amounts',
          icon: Icon(hideAmounts.value ? Icons.visibility_off_outlined : Icons.visibility_outlined),
          onPressed: _toggleHidden,
        ),
      ],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      bar,
      if (store.keyError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Tile(
            child: SelectableText(
              'Some snapshots are encrypted and couldn’t be unlocked (getEncryptionKey failed: ${store.keyError}). '
              'Older history, stock values and account breakdowns may be missing.',
              style: const TextStyle(color: AppColors.secondaryText),
            ),
          ),
        ),
      Expanded(
        child: switch (_tab) {
          _Tab.overview => _overview(),
          _Tab.spending => _spending(),
          _Tab.investing => _investing(),
          _Tab.gas => _gas(),
          _Tab.history => _history(),
        },
      ),
    ]);
  }

  Widget _page(List<Widget> children) => ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 28), children: children);

  Widget _empty(String text) => Tile(
        padding: const EdgeInsets.all(24),
        child: Text(text, style: const TextStyle(color: AppColors.secondaryText)),
      );

  // ---------------------------------------------------------------- overview

  Widget _overview() {
    final points = store.points;
    if (points.isEmpty) {
      return _page([
        _empty(store.skippedSnapshots > 0
            ? 'Found ${store.skippedSnapshots} snapshots but couldn’t read a date and amount from them.'
            : 'No net worth history yet. Asset Track adds a snapshot every hour once accounts are linked.'),
        const SizedBox(height: 12),
        _accounts(),
      ]);
    }
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 1100;
      final stats = _statGrid(points, columns: wide ? 2 : 3);
      return _page([
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: NetWorthHero(store: store, interval: _interval, hover: _hover, onInterval: _setInterval, onHover: _setHover)),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: stats),
          ])
        else ...[
          NetWorthHero(store: store, interval: _interval, hover: _hover, onInterval: _setInterval, onHover: _setHover),
          const SizedBox(height: 10),
          stats,
        ],
        const SizedBox(height: 22),
        _accounts(),
      ]);
    });
  }

  void _setInterval(String i) => setState(() {
        _interval = i;
        _hover = null;
      });

  void _setHover(int? i) => setState(() => _hover = i);

  Widget _statGrid(List<NetWorthPoint> points, {required int columns}) {
    final latest = points.last;
    final daily = store.daily;
    final last30 = daily.length > 30 ? daily.sublist(daily.length - 30) : daily;
    final high = points.reduce((a, b) => b.total > a.total ? b : a);
    final prevDay = store.before(const Duration(hours: 23));
    final m30 = store.before(const Duration(days: 30));
    final y1 = store.before(const Duration(days: 365));
    final moves = [for (var i = 1; i < last30.length; i++) last30[i].total - last30[i - 1].total];

    String change(NetWorthPoint? from) => from == null ? '—' : signedMoney(latest.total - from.total);
    String since(NetWorthPoint? from) => from == null ? 'Not enough history' : 'Since ${DateFormat.yMMMd().format(from.date)}';

    return TileGrid(minTileWidth: 180, maxColumns: columns, tiles: [
      StatTile(
          icon: Icons.today_outlined,
          label: 'Today',
          value: change(prevDay),
          note: since(prevDay),
          chart: TileBars([for (final d in moves.reversed.take(14).toList().reversed) d.abs()])),
      StatTile(
          icon: Icons.calendar_month_outlined,
          label: '30 days',
          value: change(m30),
          note: since(m30),
          chart: TileLine([for (final p in last30) p.total])),
      StatTile(icon: Icons.date_range_outlined, label: '1 year', value: change(y1), note: since(y1)),
      StatTile(
        icon: Icons.emoji_events_outlined,
        label: 'All-time high',
        value: money(high.total),
        note: identical(high, latest) ? 'That’s now' : '${signedMoney(latest.total - high.total)} from ${DateFormat.yMMMd().format(high.date)}',
      ),
      if (latest.assets != null && latest.liabilities != null && latest.assets! > 0)
        StatTile(
          icon: Icons.balance_outlined,
          label: 'Debt to assets',
          value: '${(latest.liabilities!.abs() / latest.assets! * 100).toStringAsFixed(1)}%',
          note: '${money(latest.liabilities!.abs())} owed',
          chart: TileMeter(latest.liabilities!.abs() / latest.assets!),
        ),
      StatTile(
        icon: Icons.trending_up,
        label: 'Up days · 30',
        value: '${moves.where((d) => d > 0).length}',
        unit: 'of ${moves.length}',
        note: 'Days your net worth rose',
        chart: TileDots([for (final d in moves) d > 0]),
      ),
    ]);
  }

  Widget _accounts() {
    final accounts = store.accounts;
    final refresh = IconButton(
      tooltip: 'Refresh balances',
      icon: store.accountsLoading
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh, size: 20),
      onPressed: store.accountsLoading ? null : () => store.loadAccounts(force: true),
    );
    Widget body;
    if (store.accountsError != null) {
      body = Tile(
        child: SelectableText('Couldn’t load your accounts from Asset Track.\n${store.accountsError}',
            style: const TextStyle(color: AppColors.secondaryText)),
      );
    } else if (accounts == null) {
      body = const Tile(child: SizedBox(height: 40, child: Center(child: CircularProgressIndicator(strokeWidth: 2))));
    } else if (accounts.isEmpty) {
      body = _empty('No accounts linked. Link them in Asset Track.');
    } else {
      body = TileGrid(minTileWidth: 260, maxColumns: 4, tiles: [
        for (final g in accountGroups)
          AccountGroupTile(
            name: '${g[0].toUpperCase()}${g.substring(1)}',
            liabilities: g == 'liabilities',
            accounts: accounts.where((a) => accountGroupOf(a) == g).toList()
              ..sort((a, b) => accountBalance(b).abs().compareTo(accountBalance(a).abs())),
          ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
        icon: Icons.account_balance_outlined,
        title: 'Accounts',
        subtitle: accounts == null ? null : '${accounts.length} linked',
        trailing: refresh,
      ),
      body,
    ]);
  }

  // ---------------------------------------------------------------- spending

  Widget _spending() {
    if (store.transactions.isEmpty) return _page([_empty('No transactions yet. Asset Track pulls them in from Plaid.')]);
    final flow = store.cashFlow(_month);
    final prev = store.cashFlow(DateTime(_month.year, _month.month - 1));
    final cats = store.spendingByCategory(_month).entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final months = [for (var i = 11; i >= 0; i--) DateTime(_month.year, _month.month - i)];
    final flows = [for (final m in months) store.cashFlow(m)];
    final txns = store.transactions.where((t) => t.date != null && t.date!.year == _month.year && t.date!.month == _month.month).toList();
    final spentDelta = prev.expense == 0 ? null : (flow.expense - prev.expense) / prev.expense * 100;

    return _page([
      Row(children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1))),
        Flexible(
          child: Text(DateFormat.yMMMM().format(_month),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.primaryText, fontSize: 20, fontWeight: FontWeight.w700)),
        ),
        IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1))),
      ]),
      const SizedBox(height: 6),
      TileGrid(minTileWidth: 200, maxColumns: 4, tiles: [
        StatTile(
          icon: Icons.south_east,
          label: 'Spent',
          value: money(flow.expense),
          note: spentDelta == null
              ? null
              : '${spentDelta >= 0 ? '+' : '−'}${spentDelta.abs().toStringAsFixed(0)}% vs ${DateFormat.MMMM().format(DateTime(_month.year, _month.month - 1))}',
          chart: TileBars([for (final f in flows) f.expense]),
        ),
        StatTile(icon: Icons.north_east, label: 'Income', value: money(flow.income), chart: TileBars([for (final f in flows) f.income])),
        StatTile(
          icon: Icons.savings_outlined,
          label: 'Saved',
          value: signedMoney(flow.income - flow.expense),
          note: flow.income > 0 ? '${((flow.income - flow.expense) / flow.income * 100).toStringAsFixed(0)}% of income' : null,
          chart: TileLine([for (final f in flows) f.income - f.expense]),
        ),
        StatTile(icon: Icons.receipt_long_outlined, label: 'Transactions', value: '${txns.length}', note: 'This month'),
      ]),
      const SizedBox(height: 10),
      LayoutBuilder(builder: (context, c) {
        final chart = Tile(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const StatLabel('Cash flow · 12 months'),
            const SizedBox(height: 12),
            SizedBox(
              height: 200,
              child: CustomPaint(painter: _FlowPainter(months: months, flows: flows, selected: _month)),
            ),
            const SizedBox(height: 8),
            const Row(children: [
              _Legend(color: AppColors.primaryText, label: 'In'),
              SizedBox(width: 14),
              _Legend(color: Color(0x59FFFFFF), label: 'Out'),
            ]),
          ]),
        );
        final total = cats.fold<double>(0, (s, e) => s + e.value);
        final byCat = Tile(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const StatLabel('Where it went'),
            const SizedBox(height: 10),
            if (cats.isEmpty) const Text('Nothing spent.', style: TextStyle(color: AppColors.secondaryText)),
            for (final e in cats.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: Text(e.key, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500))),
                    Text(money(e.value), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : e.value / total,
                      minHeight: 6,
                      backgroundColor: AppColors.faint,
                      color: e.key == 'Uncategorized' ? const Color(0x59FFFFFF) : AppColors.primaryText,
                    ),
                  ),
                ]),
              ),
          ]),
        );
        if (c.maxWidth < 900) return Column(children: [chart, const SizedBox(height: 10), byCat]);
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(flex: 3, child: chart),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: byCat),
          ]),
        );
      }),
      const SizedBox(height: 22),
      SectionHeader(icon: Icons.receipt_long_outlined, title: 'Transactions', subtitle: DateFormat.yMMMM().format(_month)),
      Tile(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          if (txns.isEmpty) const Padding(padding: EdgeInsets.all(18), child: Text('No transactions this month.')),
          for (var i = 0; i < math.min(_txnsShown, txns.length); i++) ...[
            if (i > 0) const Divider(indent: 16, endIndent: 16),
            _txnRow(txns[i]),
          ],
          if (txns.length > _txnsShown)
            TextButton(
              onPressed: () => setState(() => _txnsShown += 60),
              child: Text('Show more (${txns.length - _txnsShown})'),
            ),
        ]),
      ),
    ]);
  }

  Widget _txnRow(Txn t) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: AppColors.faint,
        child: Text(t.name.isEmpty ? '?' : t.name.characters.first.toUpperCase(),
            style: const TextStyle(color: AppColors.primaryText, fontWeight: FontWeight.w700, fontSize: 13)),
      ),
      title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(
        [
          if (t.date != null) DateFormat.MMMd().format(t.date!),
          t.category ?? 'Uncategorized',
          if (t.pending) 'Pending',
          if (t.ignored) 'Not counted',
        ].join(' · '),
        style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
      ),
      trailing: Text(
        t.isIncome ? '+${money(t.size)}' : money(t.size),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: t.ignored ? AppColors.secondaryText : (t.isIncome ? AppColors.positive : AppColors.primaryText),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- investing

  Widget _investing() {
    final holdings = store.holdings;
    if (holdings.isEmpty) {
      return _page([
        _empty(store.keyError != null
            ? 'Stock values are inside encrypted snapshots, which couldn’t be unlocked.'
            : 'No stocks found in your recent snapshots. Link a brokerage in Asset Track.'),
      ]);
    }
    final total = holdings.fold<double>(0, (s, h) => s + h.value);
    final dayAgo = holdings.where((h) => h.dayAgo != null).fold<double>(0, (s, h) => s + h.dayAgo!);
    final weekAgo = holdings.where((h) => h.weekAgo != null).fold<double>(0, (s, h) => s + h.weekAgo!);
    final dayKnown = holdings.where((h) => h.dayAgo != null).fold<double>(0, (s, h) => s + h.value);
    final weekKnown = holdings.where((h) => h.weekAgo != null).fold<double>(0, (s, h) => s + h.value);
    final series = <double>[];
    for (var i = 0; i < holdings.first.history.length; i++) {
      series.add(holdings.fold(0.0, (s, h) => s + (i < h.history.length ? h.history[i] : 0)));
    }
    final activity = store.investmentTxns;

    return _page([
      TileGrid(minTileWidth: 200, maxColumns: 4, tiles: [
        StatTile(
            icon: Icons.pie_chart_outline,
            label: 'Stocks & funds',
            value: money(total),
            note: '${holdings.length} holdings',
            chart: TileLine(series)),
        StatTile(
          icon: Icons.today_outlined,
          label: 'Today',
          value: dayAgo == 0 ? '—' : signedMoney(dayKnown - dayAgo),
          note: dayAgo == 0 ? null : '${((dayKnown - dayAgo) / dayAgo * 100).toStringAsFixed(2)}%',
        ),
        StatTile(
          icon: Icons.date_range_outlined,
          label: '7 days',
          value: weekAgo == 0 ? '—' : signedMoney(weekKnown - weekAgo),
          note: weekAgo == 0 ? null : '${((weekKnown - weekAgo) / weekAgo * 100).toStringAsFixed(2)}%',
        ),
        StatTile(
          icon: Icons.star_outline,
          label: 'Largest',
          value: holdings.first.ticker,
          note: '${(holdings.first.value / total * 100).toStringAsFixed(1)}% of your stocks',
          chart: TileMeter(holdings.first.value / total),
        ),
      ]),
      const SizedBox(height: 22),
      const SectionHeader(icon: Icons.show_chart, title: 'Holdings', subtitle: 'Values from Asset Track’s hourly snapshot'),
      TileGrid(minTileWidth: 210, maxColumns: 5, tiles: [
        for (final h in holdings)
          StatTile(
            icon: Icons.candlestick_chart_outlined,
            label: h.ticker,
            value: money(h.value),
            note: [
              if (h.dayPct != null) '${h.dayPct! >= 0 ? '+' : '−'}${h.dayPct!.abs().toStringAsFixed(2)}% today',
              if (h.quantity != null) '${_qty(h.quantity!)} sh',
              if (h.price != null && !hideAmounts.value) '@ ${moneyFormat.format(h.price)}',
            ].join(' · '),
            chart: TileLine(h.history),
          ),
      ]),
      if (activity.isNotEmpty) ...[
        const SizedBox(height: 22),
        SectionHeader(icon: Icons.swap_vert, title: 'Activity', subtitle: '${activity.length} trades and dividends'),
        Tile(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (var i = 0; i < math.min(30, activity.length); i++) ...[
              if (i > 0) const Divider(indent: 16, endIndent: 16),
              Builder(builder: (context) {
                final a = activity[i];
                final type = '${a['subtype'] ?? a['type'] ?? ''}';
                return ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: Text('${a['ticker_symbol'] ?? ''}  ${a['name'] ?? ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    [
                      '${a['date'] ?? ''}',
                      if (type.isNotEmpty) '${type[0].toUpperCase()}${type.substring(1)}',
                      if ((asDouble(a['quantity']) ?? 0) != 0) '${_qty(asDouble(a['quantity'])!.abs())} sh',
                    ].join(' · '),
                    style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
                  ),
                  trailing: Text(money((asDouble(a['amount']) ?? 0).abs()), style: const TextStyle(fontWeight: FontWeight.w600)),
                );
              }),
            ],
          ]),
        ),
      ],
    ]);
  }

  static String _qty(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(q < 1 ? 4 : 2);

  // ---------------------------------------------------------------- gas

  Widget _gas() {
    final fills = store.gasFills;
    if (fills.isEmpty) {
      return _page([_empty('No gas fill-ups yet. Put a transaction in the “Gas” category in Asset Track and it shows up here.')]);
    }
    final withMpg = fills.where((f) => f.mpg != null).toList();
    final withPrice = fills.where((f) => f.pricePerGallon != null).toList();
    final year = DateTime.now().year;
    final thisYear = fills.where((f) => f.txn.date?.year == year).fold<double>(0, (s, f) => s + f.txn.size);
    final gallons = fills.fold<double>(0, (s, f) => s + (f.txn.gasGallons ?? 0));
    final spentWithGallons = fills.where((f) => (f.txn.gasGallons ?? 0) > 0).fold<double>(0, (s, f) => s + f.txn.size);
    final mpgMiles = withMpg.fold<double>(0, (s, f) => s + f.miles!);
    final mpgGallons = withMpg.fold<double>(0, (s, f) => s + f.gallonsUsed!);
    final miles = fills.fold<double>(0, (s, f) => s + (f.miles ?? 0));

    return _page([
      TileGrid(minTileWidth: 200, maxColumns: 4, tiles: [
        StatTile(
          icon: Icons.speed,
          label: 'Average MPG',
          value: mpgGallons == 0 ? '—' : (mpgMiles / mpgGallons).toStringAsFixed(1),
          unit: 'mpg',
          note: withMpg.isEmpty ? 'Needs odometer readings and gallons' : 'Last fill ${withMpg.first.mpg!.toStringAsFixed(1)} mpg',
          chart: TileLine([for (final f in withMpg.reversed) f.mpg!]),
        ),
        StatTile(
          icon: Icons.local_gas_station_outlined,
          label: 'Price per gallon',
          value: gallons == 0 ? '—' : money(spentWithGallons / gallons),
          note: withPrice.isEmpty ? null : 'Last ${money(withPrice.first.pricePerGallon!)}',
          chart: TileLine([for (final f in withPrice.reversed) f.pricePerGallon!]),
        ),
        StatTile(
            icon: Icons.payments_outlined,
            label: 'Spent in $year',
            value: money(thisYear),
            note: '${fills.where((f) => f.txn.date?.year == year).length} fill-ups'),
        StatTile(
          icon: Icons.route_outlined,
          label: 'Miles tracked',
          value: NumberFormat.decimalPattern().format(miles.round()),
          note: gallons == 0 ? null : '${gallons.toStringAsFixed(1)} gallons',
        ),
      ]),
      const SizedBox(height: 22),
      const SectionHeader(icon: Icons.local_gas_station_outlined, title: 'Fill-ups', subtitle: 'Tap one to add miles or gallons'),
      Tile(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          for (var i = 0; i < fills.length; i++) ...[
            if (i > 0) const Divider(indent: 16, endIndent: 16),
            HoverMenu(
              top: 10,
              right: 10,
              actions: [
                MenuAction(label: 'Odometer & gallons', icon: Icons.edit_outlined, onSelected: () => _editGas(fills[i].txn)),
              ],
              child: ListTile(
                dense: true,
                onTap: () => _editGas(fills[i].txn),
                contentPadding: const EdgeInsets.only(left: 16, right: 52),
                title: Text(fills[i].txn.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  [
                    if (fills[i].txn.date != null) DateFormat.yMMMd().format(fills[i].txn.date!),
                    if (fills[i].txn.gasGallons != null) '${fills[i].txn.gasGallons!.toStringAsFixed(2)} gal',
                    if (fills[i].pricePerGallon != null) '${money(fills[i].pricePerGallon!)}/gal',
                    if (fills[i].txn.gasMiles != null) '${NumberFormat.decimalPattern().format(fills[i].txn.gasMiles!.round())} mi',
                    if (fills[i].mpg != null) '${fills[i].mpg!.toStringAsFixed(1)} mpg',
                  ].join(' · '),
                  style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
                ),
                trailing: Text(money(fills[i].txn.size), style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ]),
      ),
    ]);
  }

  /// Either one, or both. A field left blank has nothing saved for it.
  Future<void> _editGas(Txn t) async {
    final shownMiles = t.gasMiles?.toStringAsFixed(0) ?? '', shownGallons = t.gasGallons?.toString() ?? '';
    final miles = TextEditingController(text: shownMiles);
    final gallons = TextEditingController(text: shownGallons);
    String? error;
    var saving = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // Null: left blank. An untouched field keeps what it has exactly,
          // though it's shown rounded.
          ({double? value, bool ok}) read(TextEditingController c, String shown, double? was) {
            final text = c.text.trim();
            if (text.isEmpty) return (value: null, ok: true);
            if (text == shown) return (value: was, ok: true);
            final v = asDouble(text);
            return (value: v, ok: v != null && v > 0);
          }

          Future<void> save() async {
            final m = read(miles, shownMiles, t.gasMiles), g = read(gallons, shownGallons, t.gasGallons);
            if (!m.ok || !g.ok) {
              setLocal(() => error = '${!m.ok ? 'The odometer' : 'Gallons'} has to be a number above 0.');
              return;
            }
            if (m.value == t.gasMiles && g.value == t.gasGallons) {
              Navigator.pop(ctx);
              return;
            }
            setLocal(() {
              saving = true;
              error = null;
            });
            try {
              await store.saveGas(t, miles: m.value, gallons: g.value);
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              setLocal(() {
                saving = false;
                error = 'Couldn’t save that: $e';
              });
            }
          }

          return AlertDialog(
            title: Text(t.name),
            content: SizedBox(
              width: 340,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(
                  controller: miles,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Odometer (miles)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: gallons,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Gallons filled'),
                ),
                const SizedBox(height: 10),
                const Text('Fill in either one, or both. MPG needs odometer readings and the gallons in between.',
                    style: TextStyle(color: AppColors.secondaryText, fontSize: 12, height: 1.35)),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: saving ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: saving ? null : save, child: const Text('Save')),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- history

  Widget _history() {
    final days = store.daily.reversed.toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Row(children: [
          Expanded(
            child: Text(
              '${NumberFormat.decimalPattern().format(days.length)} days · ${NumberFormat.decimalPattern().format(store.points.length)} snapshots'
              '${days.isEmpty ? '' : ' since ${DateFormat.yMMMd().format(days.last.date)}'}',
              style: const TextStyle(color: AppColors.secondaryText, fontSize: 13),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _addSnapshot(store.points.lastOrNull),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add snapshot'),
          ),
        ]),
      ),
      Expanded(
        child: days.isEmpty
            ? Padding(padding: const EdgeInsets.all(16), child: _empty('No snapshots yet.'))
            : ListView.builder(
                controller: _historyScroll,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                itemCount: days.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _historyTile(days[i], i + 1 < days.length ? days[i + 1] : null),
                ),
              ),
      ),
    ]);
  }

  Widget _historyTile(NetWorthPoint p, NetWorthPoint? older) {
    final d = older == null ? null : p.total - older.total;
    final open = _expanded.contains(p.id);
    final b = open ? store.breakdown(p) : null;
    // A phone stacks the date over the amount: side by side there's no room,
    // and an amount wraps in the middle of its digits.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final when = Text(DateFormat('EEE, MMM d, y').format(p.date), style: const TextStyle(color: AppColors.secondaryText, fontSize: 13));
    final total = Text(money(p.total), maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15));
    return HoverMenu(
      top: 10,
      right: 10,
      actions: [
        MenuAction(
          label: 'Delete snapshot',
          icon: Icons.delete_outline,
          onSelected: () => store.deleteSnapshot(p),
          confirm: (
            'Delete this snapshot?',
            '${DateFormat.yMMMd().add_jm().format(p.date)} will be removed from your Asset Track history.',
            'Delete',
          ),
        ),
      ],
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: p.encrypted == null ? null : () => setState(() => open ? _expanded.remove(p.id) : _expanded.add(p.id)),
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, narrow ? 12 : 52, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                if (narrow)
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [when, const SizedBox(height: 2), total]))
                else ...[
                  SizedBox(width: 128, child: when),
                  Expanded(child: total),
                ],
                if (p.assets != null && MediaQuery.sizeOf(context).width > 900)
                  SizedBox(
                    width: 260,
                    child: Text(
                      'Assets ${money(p.assets!)}${p.liabilities != null ? ' · Debt ${money(p.liabilities!.abs())}' : ''}',
                      style: const TextStyle(color: AppColors.secondaryText, fontSize: 12),
                    ),
                  ),
                SizedBox(
                  width: 110,
                  child: Text(d == null ? '' : signedMoney(d),
                      textAlign: TextAlign.right,
                      style: TextStyle(color: d == null ? null : changeColor(d), fontWeight: FontWeight.w600, fontSize: 13)),
                ),
                if (p.encrypted != null) Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: AppColors.secondaryText),
              ]),
              if (open) ...[
                const SizedBox(height: 10),
                if (b == null)
                  const Text('Couldn’t unlock this snapshot’s details.', style: TextStyle(color: AppColors.secondaryText))
                else
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final e in (b.accounts.entries.toList()..sort((x, y) => y.value.abs().compareTo(x.value.abs()))))
                      Pill(icon: Icons.account_balance_outlined, text: '${e.key}  ${money(e.value)}'),
                    for (final e in (b.stocks.entries.toList()..sort((x, y) => y.value.compareTo(x.value))))
                      if (e.value > 0) Pill(icon: Icons.show_chart, text: '${e.key}  ${money(e.value)}'),
                  ]),
                if (p.note != null && p.note!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(p.note!, style: const TextStyle(color: AppColors.secondaryText)),
                ],
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _addSnapshot(NetWorthPoint? latest) async {
    final assets = TextEditingController(text: latest?.assets?.toStringAsFixed(2) ?? '');
    final liabilities = TextEditingController(text: latest?.liabilities?.abs().toStringAsFixed(2) ?? '');
    final total = TextEditingController();
    final note = TextEditingController();
    var date = DateTime.now();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add snapshot'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text(DateFormat.yMMMd().format(date)),
                  onPressed: () async {
                    final d = await showDatePicker(context: ctx, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime(2100));
                    if (d != null) setLocal(() => date = d);
                  },
                ),
              ),
              TextField(
                controller: assets,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Total assets'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: liabilities,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Total liabilities'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: total,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Or just the net worth', helperText: 'Leave blank to use assets − liabilities'),
              ),
              const SizedBox(height: 12),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final a = asDouble(assets.text);
                final l = asDouble(liabilities.text);
                final t = asDouble(total.text) ?? ((a != null || l != null) ? (a ?? 0) - (l ?? 0).abs() : null);
                if (t == null) return;
                await store.addSnapshot(date: date, total: t, assets: a, liabilities: l, note: note.text.trim());
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The big net worth number with its chart and range picker. Used on the
/// Net worth page and in the dashboard.
class NetWorthHero extends StatelessWidget {
  const NetWorthHero({
    super.key,
    required this.store,
    required this.interval,
    required this.hover,
    required this.onInterval,
    required this.onHover,
    this.chartHeight = 260,
    this.compact = false,
  });

  final FinanceStore store;
  final String interval;
  final int? hover;
  final ValueChanged<String> onInterval;
  final ValueChanged<int?> onHover;

  /// Null fills whatever height is left (in a dashboard panel).
  final double? chartHeight;

  /// For a dashboard panel: smaller, and no tile of its own (the panel is one).
  final bool compact;

  List<NetWorthPoint> _window(List<NetWorthPoint> points) {
    final days = _intervals[interval]!.days;
    var w = days == 0 ? points : points.where((p) => !p.date.isBefore(points.last.date.subtract(Duration(days: days)))).toList();
    if (w.length < 2 && points.length >= 2) w = points.sublist(points.length - 2);
    if (w.length > 400) {
      final step = w.length / 400;
      w = [for (var i = 0; i < 399; i++) w[(i * step).floor()], w.last];
    }
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final points = store.points;
    if (points.isEmpty) return const SizedBox.shrink();
    final window = _window(points);
    final h = hover != null && hover! < window.length ? hover : null;
    final focus = h == null ? points.last : window[h];
    final start = window.first;
    final diff = focus.total - start.total;
    final pct = start.total != 0 ? diff / start.total.abs() * 100 : 0.0;
    final label = h == null ? _intervals[interval]!.label : DateFormat.yMMMd().add_jm().format(focus.date);

    final body =
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: chartHeight == null ? MainAxisSize.max : MainAxisSize.min, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('NET WORTH', style: TextStyle(color: AppColors.secondaryText, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(money(focus.total),
                  style: TextStyle(color: AppColors.primaryText, fontSize: compact ? 30 : 42, fontWeight: FontWeight.w600, letterSpacing: -1)),
            ),
            Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: '${signedMoney(diff)} (${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%)',
                  style: TextStyle(color: changeColor(diff), fontWeight: FontWeight.w600),
                ),
                TextSpan(text: '  ·  $label'),
              ]),
              style: const TextStyle(color: AppColors.secondaryText, fontSize: 13),
            ),
          ]),
        ),
        if (!compact)
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (focus.assets != null) _item('Assets', money(focus.assets!)),
            if (focus.assets != null && focus.liabilities != null) const SizedBox(height: 10),
            if (focus.liabilities != null) _item('Liabilities', money(focus.liabilities!.abs())),
          ]),
      ]),
      SizedBox(height: compact ? 8 : 14),
      _sized(LayoutBuilder(builder: (context, c) {
        int indexAt(double x) {
          final t0 = window.first.date.millisecondsSinceEpoch;
          final t1 = math.max(t0 + 1, window.last.date.millisecondsSinceEpoch);
          final t = t0 + (x / c.maxWidth).clamp(0.0, 1.0) * (t1 - t0);
          var best = 0;
          for (var i = 1; i < window.length; i++) {
            if ((window[i].date.millisecondsSinceEpoch - t).abs() < (window[best].date.millisecondsSinceEpoch - t).abs()) best = i;
          }
          return best;
        }

        return MouseRegion(
          onHover: (e) => onHover(indexAt(e.localPosition.dx)),
          onExit: (_) => onHover(null),
          child: GestureDetector(
            onHorizontalDragUpdate: (d) => onHover(indexAt(d.localPosition.dx)),
            onHorizontalDragEnd: (_) => onHover(null),
            child: CustomPaint(size: Size.infinite, painter: _ChartPainter(points: window, focus: h)),
          ),
        );
      })),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.center,
        child: PillTabs<String>(
          dense: true,
          items: [for (final k in _intervals.keys) (k, k)],
          selected: interval,
          onSelected: onInterval,
        ),
      ),
    ]);
    return compact ? body : Tile(padding: const EdgeInsets.fromLTRB(22, 20, 22, 12), child: body);
  }

  Widget _sized(Widget chart) => chartHeight == null ? Expanded(child: chart) : SizedBox(height: chartHeight, child: chart);

  Widget _item(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(label, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(color: AppColors.primaryText, fontWeight: FontWeight.w600, fontSize: 16)),
      ]);
}

/// One of Asset Track's account groups: its total, and its accounts when opened.
class AccountGroupTile extends StatelessWidget {
  const AccountGroupTile({super.key, required this.name, required this.liabilities, required this.accounts});

  final String name;
  final bool liabilities;
  final List<Map> accounts;

  @override
  Widget build(BuildContext context) {
    final total = accounts.fold<double>(0, (s, a) => s + accountBalance(a));
    final totalText = liabilities ? '(${money(total)})' : money(total);
    return Container(
      decoration: tileDecoration(radius: 16),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          iconColor: AppColors.primaryText,
          collapsedIconColor: AppColors.secondaryText,
          tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
          title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          subtitle: Text('${accounts.length} ${accounts.length == 1 ? 'account' : 'accounts'}',
              style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
          trailing: Text(totalText, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          children: [
            if (accounts.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 0, 18, 14),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No accounts in this group', style: TextStyle(color: AppColors.secondaryText)),
                ),
              ),
            for (final a in accounts)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 18),
                title: Row(children: [
                  Flexible(
                    child: Text('${a['name'] ?? 'Account'}',
                        overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  ),
                  if (a['is_manual'] != true) ...[
                    const SizedBox(width: 6),
                    const Tooltip(message: 'Linked with Plaid', child: Icon(Icons.link, size: 14, color: AppColors.secondaryText)),
                  ],
                ]),
                subtitle: Text('${a['institution_name'] ?? ''}', style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
                trailing: Text(money(accountBalance(a)), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
      ]);
}

/// Money in and out per month, side by side; the chosen month is brightest.
class _FlowPainter extends CustomPainter {
  _FlowPainter({required this.months, required this.flows, required this.selected});

  final List<DateTime> months;
  final List<({double income, double expense})> flows;
  final DateTime selected;

  @override
  void paint(Canvas canvas, Size size) {
    const labelH = 18.0;
    final hi = flows.fold<double>(1, (m, f) => math.max(m, math.max(f.income, f.expense)));
    final slot = size.width / months.length;
    final barW = math.min(14.0, slot * 0.32);
    final chartH = size.height - labelH;
    for (var i = 0; i < months.length; i++) {
      final isSel = months[i].year == selected.year && months[i].month == selected.month;
      final cx = slot * i + slot / 2;
      void bar(double v, double x, Color c) {
        final h = math.max(2.0, v / hi * chartH);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, chartH - h, barW, h), const Radius.circular(3)),
          Paint()..color = c,
        );
      }

      bar(flows[i].income, cx - barW - 1, isSel ? AppColors.primaryText : const Color(0xB3FFFFFF));
      bar(flows[i].expense, cx + 1, isSel ? const Color(0x99FFFFFF) : const Color(0x40FFFFFF));
      final tp = TextPainter(
        text: TextSpan(
          text: DateFormat.MMM().format(months[i]).substring(0, 1),
          style: TextStyle(
              fontFamily: 'Roboto', color: isSel ? AppColors.primaryText : AppColors.secondaryText, fontSize: 11, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, size.height - tp.height));
    }
  }

  @override
  bool shouldRepaint(covariant _FlowPainter old) => old.flows != flows || old.selected != selected;
}

/// Asset Track's line: white where you're looking, fading out away from it.
class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.points, required this.focus});

  final List<NetWorthPoint> points;
  final int? focus;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    var lo = points.map((p) => p.total).reduce(math.min);
    var hi = points.map((p) => p.total).reduce(math.max);
    if (hi == lo) {
      hi += 100;
      lo -= 100;
    }
    final pad = (hi - lo) * 0.08;
    lo -= pad;
    hi += pad;
    final t0 = points.first.date.millisecondsSinceEpoch.toDouble();
    final t1 = math.max(t0 + 1, points.last.date.millisecondsSinceEpoch.toDouble());
    Offset at(NetWorthPoint p) => Offset(
          (p.date.millisecondsSinceEpoch - t0) / (t1 - t0) * size.width,
          size.height - (p.total - lo) / (hi - lo) * size.height,
        );

    final path = Path()..moveTo(at(points.first).dx, at(points.first).dy);
    for (final p in points.skip(1)) {
      path.lineTo(at(p).dx, at(p).dy);
    }
    final f = focus ?? points.length - 1;
    final fx = (at(points[f]).dx / size.width).clamp(0.0, 1.0);

    final fill = Path.from(path)
      ..lineTo(at(points.last).dx, size.height)
      ..lineTo(at(points.first).dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x1AFFFFFF), Color(0x00FFFFFF)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..shader = LinearGradient(
          colors: const [Color(0x40FFFFFF), Color(0x99FFFFFF), Colors.white, Color(0x99FFFFFF), Color(0x40FFFFFF)],
          stops: [
            (fx - 0.5).clamp(0.0, 1.0),
            (fx - 0.15).clamp(0.0, 1.0),
            fx,
            (fx + 0.15).clamp(0.0, 1.0),
            (fx + 0.5).clamp(0.0, 1.0),
          ],
        ).createShader(Offset.zero & size),
    );

    final p = at(points[f]);
    if (focus != null) {
      final dash = Paint()
        ..color = const Color(0x4DFFFFFF)
        ..strokeWidth = 1;
      for (var y = 0.0; y < size.height; y += 8) {
        canvas.drawLine(Offset(p.dx, y), Offset(p.dx, math.min(size.height, y + 4)), dash);
      }
    }
    canvas.drawCircle(p, 9, Paint()..color = const Color(0x33FFFFFF));
    canvas.drawCircle(p, 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => old.points != points || old.focus != focus;
}
