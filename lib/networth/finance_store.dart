import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../util/fields.dart';
import '../util/dispose_safe.dart';

class NetWorthPoint {
  NetWorthPoint({
    required this.id,
    required this.date,
    required this.total,
    this.assets,
    this.liabilities,
    this.note,
    this.encrypted,
  });

  final String id;
  final DateTime date;
  final double total;
  final double? assets;
  final double? liabilities;
  final String? note;

  /// Asset Track's encrypted per-account and per-stock values, if any.
  final ({String data, String iv})? encrypted;

  static bool isEncryptedOnly(Map<String, dynamic> d) =>
      d[AxisSchema.writeNetWorth] == null && d['encryptedData'] is String && d['iv'] is String;

  static NetWorthPoint? fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc, encrypt.Encrypter? key) {
    var d = doc.data();
    if (isEncryptedOnly(d)) {
      if (key == null) return null;
      final plain = _decrypt(key, d['encryptedData'] as String, d['iv'] as String);
      if (plain == null) return null;
      d = {...d, ...plain};
    }
    final dateKey = firstKey(d, AxisSchema.dateFields);
    final date = dateKey == null ? null : asDate(d[dateKey]);
    if (date == null) return null;
    final aKey = firstKey(d, AxisSchema.assetsFields);
    final lKey = firstKey(d, AxisSchema.liabilitiesFields);
    final tKey = firstKey(d, AxisSchema.netWorthTotalFields);
    final assets = aKey == null ? null : asDouble(d[aKey]);
    final liabilities = lKey == null ? null : asDouble(d[lKey]);
    double? total = tKey == null ? null : asDouble(d[tKey]);
    total ??= (assets != null || liabilities != null) ? (assets ?? 0) - (liabilities ?? 0).abs() : null;
    if (total == null) return null;
    return NetWorthPoint(
      id: doc.id,
      date: date,
      total: total,
      assets: assets,
      liabilities: liabilities,
      note: d['note'] as String?,
      encrypted: d['encryptedData'] is String && d['iv'] is String
          ? (data: d['encryptedData'] as String, iv: d['iv'] as String)
          : null,
    );
  }
}

Map<String, dynamic>? _decrypt(encrypt.Encrypter key, String data, String iv) {
  try {
    return jsonDecode(key.decrypt64(data, iv: encrypt.IV.fromBase64(iv))) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// What a snapshot was made of: each account's balance and each stock's value.
class Breakdown {
  const Breakdown(this.accounts, this.stocks);
  final Map<String, double> accounts;
  final Map<String, double> stocks;

  static Map<String, double> _numbers(dynamic m) => {
        if (m is Map)
          for (final e in m.entries)
            if (asDouble(e.value) != null) '${e.key}': asDouble(e.value)!,
      };
}

/// A bank or card transaction from Asset Track (via Plaid), with Asset
/// Track's own categorizing applied.
class Txn {
  Txn(this.id, this.data);

  final String id;
  final Map<String, dynamic> data;

  late final String name = '${data['customTitle'] ?? data['merchant_name'] ?? data['name'] ?? 'Unknown'}';
  late final DateTime? date = data['date'] is String ? DateTime.tryParse(data['date'] as String) : asDate(data['date']);

  /// Plaid's sign: positive is money out, negative is money in.
  late final double amount = asDouble(data['amount']) ?? 0;
  bool get isIncome => amount < 0;
  double get size => amount.abs();

  String? category;
  bool ignored = false;
  bool transfer = false;

  String get transactionId => '${data['transaction_id'] ?? id.replaceFirst('tx_', '')}';
  // Asset Track saves a blank field as 0, so 0 means not filled in.
  double? get gasMiles => _positive(data['gasMileage']);
  double? get gasGallons => _positive(data['gasGallons']);
  static double? _positive(Object? v) {
    final d = asDouble(v);
    return d != null && d > 0 ? d : null;
  }
  bool get pending => data['pending'] == true;
}

/// One stock or fund you hold, from Asset Track's hourly snapshots.
class Holding {
  Holding({required this.ticker, required this.value, this.quantity, this.dayAgo, this.weekAgo, this.history = const []});

  final String ticker;
  final double value;
  final double? quantity;
  final double? dayAgo;
  final double? weekAgo;

  /// Value over the last 30 days, oldest first.
  final List<double> history;

  double? get price => quantity == null || quantity == 0 ? null : value / quantity!;
  double? get dayChange => dayAgo == null ? null : value - dayAgo!;
  double? get dayPct => dayAgo == null || dayAgo == 0 ? null : (value - dayAgo!) / dayAgo! * 100;
}

/// A gas fill-up, with how far you've come since the last one that has an
/// odometer reading.
class GasFill {
  GasFill(this.txn, {this.miles, this.gallonsUsed});
  final Txn txn;

  /// Miles since the last odometer reading, if this one has a reading too.
  final double? miles;

  /// The gas those miles took: every fill since that reading, this one included.
  /// Null if any of them doesn't say how much it was.
  final double? gallonsUsed;

  double? get mpg => miles == null || gallonsUsed == null ? null : miles! / gallonsUsed!;
  double? get pricePerGallon => (txn.gasGallons ?? 0) > 0 ? txn.size / txn.gasGallons! : null;
}

const accountGroups = ['liabilities', 'cash', 'investments', 'retirement'];

String accountGroupOf(Map a) {
  if (a['group'] is String && accountGroups.contains(a['group'])) return a['group'] as String;
  final type = '${a['type'] ?? ''}'.toLowerCase();
  final subtype = '${a['subtype'] ?? ''}'.toLowerCase();
  if (type == 'credit' || type == 'loan') return 'liabilities';
  if (['401k', 'ira', 'retirement', 'roth'].any(subtype.contains)) return 'retirement';
  if (type == 'investment' || type == 'brokerage') return 'investments';
  return 'cash';
}

double accountBalance(Map a) => asDouble((a['balances'] as Map?)?['current']) ?? 0;

/// Everything Asset Track keeps in assetTrack/{uid}/assetData, live: net
/// worth snapshots, transactions, investment activity and cached holdings;
/// plus account balances from its fetchBalances function. Shared by the Net
/// worth page and the dashboard.
class FinanceStore extends ChangeNotifier with DisposeSafe {
  FinanceStore(this.uid) {
    _subs = [
      _col.where('docType', isEqualTo: AxisSchema.netWorthDocType).snapshots().listen(_onSnapshots, onError: _onError),
      _col.where('docType', isEqualTo: 'transaction').snapshots().listen((s) {
        _rawTxns = s.docs;
        _processTxns();
      }, onError: _onError),
      _col.where('docType', isEqualTo: 'transactionCategory').snapshots().listen((s) {
        _merchantCategories = {
          for (final d in s.docs)
            if (d.data()['merchantName'] is String && d.data()['category'] is String)
              d.data()['merchantName'] as String: d.data()['category'] as String,
        };
        _processTxns();
      }, onError: _onError),
      _col.where('docType', isEqualTo: 'investmentTransaction').snapshots().listen((s) {
        investmentTxns = s.docs.map((d) => d.data()).toList()
          ..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
        notifyListeners();
      }, onError: _onError),
      _col.doc('cachedData_plaid').snapshots().listen((s) {
        _cached = s.data();
        _holdings = null;
        notifyListeners();
      }, onError: _onError),
    ];
  }

  /// For previews and tests: no Firestore; fill in the public fields.
  @visibleForTesting
  FinanceStore.offline(this.uid, {encrypt.Encrypter? key})
      : _subs = const [],
        _key = key,
        snapshotsLoaded = true;

  final String uid;

  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection(AxisSchema.netWorthPath(uid));

  late final List<StreamSubscription> _subs;

  /// Sets transactions as Firestore would hand them over, then categorizes them.
  @visibleForTesting
  void setTransactions(List<(String, Map<String, dynamic>)> docs, {Map<String, String> merchantCategories = const {}}) {
    _testTxns = docs;
    _merchantCategories = merchantCategories;
    _processTxns();
  }

  List<(String, Map<String, dynamic>)>? _testTxns;

  Object? error;
  bool snapshotsLoaded = false;
  List<NetWorthPoint> points = [];
  int skippedSnapshots = 0;
  List<Txn> transactions = [];
  List<Map<String, dynamic>> investmentTxns = [];

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _rawSnapshots = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _rawTxns = [];
  Map<String, String> _merchantCategories = {};
  Map<String, dynamic>? _cached;

  // Asset Track's snapshot key, from its getEncryptionKey Cloud Function.
  encrypt.Encrypter? _key;

  @visibleForTesting
  set cachedPlaid(Map<String, dynamic> data) => _cached = data;
  Object? keyError;
  bool _keyRequested = false;
  bool get waitingForKey => _keyRequested && _key == null && keyError == null;

  void _onError(Object e) {
    error = e;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- snapshots

  void _onSnapshots(QuerySnapshot<Map<String, dynamic>> snap) {
    _rawSnapshots = snap.docs;
    snapshotsLoaded = true;
    if (_key == null && snap.docs.any((d) => d.data()['encryptedData'] is String)) _loadKey();
    _buildPoints();
  }

  void _loadKey() {
    if (_keyRequested) return;
    _keyRequested = true;
    FirebaseFunctions.instance.httpsCallable('getEncryptionKey').call().then((r) {
      _key = encrypt.Encrypter(encrypt.AES(encrypt.Key.fromBase64(r.data['key'] as String), mode: encrypt.AESMode.cbc));
      _breakdowns.clear();
      _holdings = null;
      _buildPoints();
    }, onError: (Object e) {
      keyError = e;
      notifyListeners();
    });
  }

  void _buildPoints() {
    points = _rawSnapshots.map((d) => NetWorthPoint.fromDoc(d, _key)).whereType<NetWorthPoint>().toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    skippedSnapshots = _rawSnapshots.length - points.length;
    _holdings = null;
    notifyListeners();
  }

  final _breakdowns = <String, Breakdown?>{};

  /// The accounts and stocks inside a snapshot (decrypted on first ask).
  Breakdown? breakdown(NetWorthPoint p) {
    final enc = p.encrypted;
    if (enc == null || _key == null) return null;
    return _breakdowns.putIfAbsent(p.id, () {
      final m = _decrypt(_key!, enc.data, enc.iv);
      return m == null ? null : Breakdown(Breakdown._numbers(m['accounts']), Breakdown._numbers(m['stocks']));
    });
  }

  /// The last snapshot of each day, oldest first.
  List<NetWorthPoint> get daily {
    final byDay = <DateTime, NetWorthPoint>{};
    for (final p in points) {
      byDay[dayStart(p.date)] = p;
    }
    return byDay.values.toList();
  }

  NetWorthPoint? before(Duration ago) {
    if (points.isEmpty) return null;
    final cutoff = points.last.date.subtract(ago);
    for (var i = points.length - 1; i >= 0; i--) {
      if (!points[i].date.isAfter(cutoff)) return points[i];
    }
    return null;
  }

  Future<void> deleteSnapshot(NetWorthPoint p) => _col.doc(p.id).delete();

  Future<void> addSnapshot({required DateTime date, required double total, double? assets, double? liabilities, String? note}) {
    // Same plaintext fields Asset Track's sync writes on each snapshot.
    return _col.add({
      'docType': AxisSchema.netWorthDocType,
      'timestamp': Timestamp.fromDate(date),
      AxisSchema.writeNetWorth: total,
      if (assets != null) AxisSchema.writeAssets: assets,
      if (liabilities != null) AxisSchema.writeLiabilities: liabilities,
      if (note != null && note.isNotEmpty) 'note': note,
      'source': 'optimizer',
    });
  }

  // ---------------------------------------------------------------- holdings

  List<Holding>? _holdings;

  /// Your stocks, valued from the latest snapshot, with quantities from
  /// Asset Track's cached Plaid holdings.
  List<Holding> get holdings {
    if (_holdings != null) return _holdings!;
    final withStocks = [for (final p in points) if (p.encrypted != null) p];
    if (withStocks.isEmpty || _key == null) return const [];
    final latest = withStocks.last;
    final now = breakdown(latest)?.stocks ?? const {};
    NetWorthPoint? at(Duration ago) {
      final cutoff = latest.date.subtract(ago);
      for (var i = withStocks.length - 1; i >= 0; i--) {
        if (!withStocks[i].date.isAfter(cutoff)) return withStocks[i];
      }
      return null;
    }

    final day = at(const Duration(hours: 23));
    final week = at(const Duration(days: 7));
    final dayStocks = day == null ? null : breakdown(day)?.stocks;
    final weekStocks = week == null ? null : breakdown(week)?.stocks;

    // One value per day for the last 30 days, for the sparklines.
    final byDay = <DateTime, NetWorthPoint>{};
    for (final p in withStocks.where((p) => !p.date.isBefore(latest.date.subtract(const Duration(days: 30))))) {
      byDay[dayStart(p.date)] = p;
    }
    final days = byDay.values.map(breakdown).whereType<Breakdown>().toList();

    final quantities = <String, double>{};
    for (final h in (_cached?['holdings'] as List? ?? const [])) {
      if (h is Map && h['ticker'] is String) {
        quantities[h['ticker'] as String] = (quantities[h['ticker']] ?? 0) + (asDouble(h['quantity']) ?? 0);
      }
    }

    _holdings = [
      for (final e in now.entries)
        if (e.value > 0)
          Holding(
            ticker: e.key,
            value: e.value,
            quantity: quantities[e.key],
            dayAgo: dayStocks?[e.key],
            weekAgo: weekStocks?[e.key],
            history: [for (final b in days) b.stocks[e.key] ?? 0],
          ),
    ]..sort((a, b) => b.value.compareTo(a.value));
    return _holdings!;
  }

  // ---------------------------------------------------------------- accounts

  List<Map>? accounts;
  Object? accountsError;
  bool accountsLoading = false;

  /// Live balances from Asset Track's fetchBalances (asks Plaid, so only on demand).
  Future<void> loadAccounts({bool force = false}) async {
    if (accountsLoading || (!force && accounts != null)) return;
    accountsLoading = true;
    accountsError = null;
    notifyListeners();
    try {
      final r = await FirebaseFunctions.instance.httpsCallable('fetchBalances').call();
      accounts = ((r.data as Map)['accounts'] as List? ?? const []).whereType<Map>().toList();
    } catch (e) {
      accountsError = e;
    } finally {
      accountsLoading = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- transactions

  /// Asset Track's rules: matching in/out amounts within 5 days are transfers
  /// (or card payments); your own category wins, per transaction or per
  /// merchant; transfers, payments and "Excluded" are left out of insights.
  void _processTxns() {
    final list = [for (final d in _testTxns ?? [for (final d in _rawTxns) (d.id, d.data())]) Txn(d.$1, d.$2)]
      ..sort((a, b) => (b.date ?? DateTime(1970)).compareTo(a.date ?? DateTime(1970)));
    final matched = <int>{};
    for (var i = 0; i < list.length; i++) {
      if (matched.contains(i) || list[i].amount == 0 || list[i].date == null) continue;
      for (var j = i + 1; j < list.length; j++) {
        if (matched.contains(j) || list[j].amount == 0 || list[j].date == null) continue;
        final gap = list[i].date!.difference(list[j].date!).inDays.abs();
        if ((list[i].amount + list[j].amount).abs() < 0.01 && gap <= 5) {
          matched.addAll([i, j]);
          final payment = list[i].name.toLowerCase().contains('payment') || list[j].name.toLowerCase().contains('payment');
          for (final t in [list[i], list[j]]) {
            t.transfer = true;
            t.category = payment ? 'Payment' : 'Transfer';
          }
          break;
        }
        if (gap > 5) break;
      }
    }
    for (final t in list) {
      final mine = t.data['customCategory'] as String? ?? _merchantCategories[t.name];
      if (mine != null) t.category = mine;
      final c = t.category?.toLowerCase();
      t.ignored = t.data['isIgnored'] == true ||
          (c != null && (c.contains('transfer') || c.contains('payment') || c == 'excluded'));
    }
    transactions = list;
    notifyListeners();
  }

  /// Transactions that count toward spending and income.
  Iterable<Txn> get counted => transactions.where((t) => !t.ignored && !t.name.toLowerCase().contains('payment'));

  ({double income, double expense}) cashFlow(DateTime month) {
    var income = 0.0, expense = 0.0;
    for (final t in counted) {
      final d = t.date;
      if (d == null || d.year != month.year || d.month != month.month) continue;
      t.isIncome ? income += t.size : expense += t.size;
    }
    return (income: income, expense: expense);
  }

  Map<String, double> spendingByCategory(DateTime month) {
    final out = <String, double>{};
    for (final t in counted) {
      final d = t.date;
      if (t.isIncome || d == null || d.year != month.year || d.month != month.month) continue;
      final c = t.category ?? 'Uncategorized';
      out[c] = (out[c] ?? 0) + t.size;
    }
    return out;
  }

  // ---------------------------------------------------------------- gas

  /// Fill-ups (transactions you put in the Gas category), newest first.
  List<GasFill> get gasFills {
    final gas = transactions.where((t) => t.category?.toLowerCase() == 'gas').toList()
      ..sort((a, b) => (a.date ?? DateTime(1970)).compareTo(b.date ?? DateTime(1970)));
    final out = <GasFill>[];
    Txn? lastWithMiles;
    double? gallonsSince = 0;
    for (final t in gas) {
      final gallons = t.gasGallons ?? 0;
      if (lastWithMiles != null) gallonsSince = gallons > 0 && gallonsSince != null ? gallonsSince + gallons : null;
      double? miles, used;
      if ((t.gasMiles ?? 0) > 0) {
        if (lastWithMiles != null && t.gasMiles! > lastWithMiles.gasMiles!) {
          miles = t.gasMiles! - lastWithMiles.gasMiles!;
          used = gallonsSince;
        }
        lastWithMiles = t;
        gallonsSince = 0;
      }
      out.add(GasFill(t, miles: miles, gallonsUsed: used));
    }
    return out.reversed.toList();
  }

  /// Saves odometer and gallons on a gas transaction, where Asset Track keeps
  /// them. Either can be left out, which clears it.
  Future<void> saveGas(Txn t, {double? miles, double? gallons}) => _col.doc('tx_${t.transactionId}').set({
        'gasMileage': miles ?? FieldValue.delete(),
        'gasGallons': gallons ?? FieldValue.delete(),
      }, SetOptions(merge: true));
}

final moneyFormat = NumberFormat.simpleCurrency();
