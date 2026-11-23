import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/dispose_safe.dart';

/// Premium beta: early features for accounts switched on in Axis Optic.
/// That's every page but To-dos (and Settings): Home, Calendar (and linking
/// Google Calendar), Trips, Journal, Net worth, the assistant and People.
///
/// The switch is the sign-in claim `optimizerPremiumBeta`, which only
/// Optimizer's server sets (Optic → functions/optic.js), so it can't be
/// turned on from the app. Sign-ins are shared with Asset Track and Axis
/// Journal, hence the app's name in the claim.
///
/// The server also writes `optimizer/{uid}.premiumBeta` as a copy; when that
/// copy changes the sign-in is refreshed, so the switch takes effect right
/// away instead of within the hour. The claim is what counts, never the copy,
/// and the assistant's server checks the claim too.
class PremiumBeta extends ChangeNotifier with DisposeSafe {
  PremiumBeta(this.user) {
    _start();
  }

  /// For tests and previews: fixed, no Firebase.
  PremiumBeta.fixed(bool on)
      : user = null,
        _on = on;

  final User? user;
  bool _on = false;
  StreamSubscription? _sub;

  /// Whether this account has premium beta. False until it's known, except
  /// that the last answer on this device is used meanwhile, so the side bar
  /// doesn't change under you every time the app opens.
  bool get on => _on;

  String get _cacheKey => 'optimizer.${user!.uid}.premiumBeta';

  void _set(bool v) {
    if (v == _on) return;
    _on = v;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool(_cacheKey, v), onError: (_) => false);
  }

  Future<bool> _claim({required bool refresh}) async {
    try {
      final r = await user!.getIdTokenResult(refresh);
      return r.claims?['optimizerPremiumBeta'] == true;
    } catch (_) {
      return _on;
    }
  }

  Future<void> _start() async {
    try {
      final cached = (await SharedPreferences.getInstance()).getBool(_cacheKey);
      if (cached != null && !disposed && cached != _on) {
        _on = cached;
        notifyListeners();
      }
    } catch (_) {}
    if (disposed) return;
    _set(await _claim(refresh: false));
    if (disposed) return;

    bool? lastCopy;
    _sub = FirebaseFirestore.instance.collection('optimizer').doc(user!.uid).snapshots().listen((doc) async {
      final copy = doc.data()?['premiumBeta'] == true;
      // Only when the copy changes (and disagrees), not on every save to this doc.
      if (copy == lastCopy) return;
      lastCopy = copy;
      if (copy == _on) return;
      final fresh = await _claim(refresh: true);
      if (!disposed) _set(fresh);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// The small "Premium beta" note under your account in Settings.
class PremiumBetaBadge extends StatelessWidget {
  const PremiumBetaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    const faint = Color(0x73FFFFFF);
    return const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.auto_awesome, size: 12, color: faint),
      SizedBox(width: 5),
      Text('Premium beta', style: TextStyle(color: faint, fontSize: 12, fontWeight: FontWeight.w600)),
    ]);
  }
}
