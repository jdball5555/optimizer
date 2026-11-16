import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'origin.dart';
import '../util/dispose_safe.dart';

/// Push notifications for new Canvas assignments (sent by Optimizer's Cloud
/// Functions). Each phone or browser that turns them on is saved as
/// axisCalendar/{uid}/devices/{id} with its push token and time zone, so due
/// dates are written in your local time.
///
/// Optimizer keeps its own device list rather than users/{uid}.fcmToken,
/// which your other Axis apps already use for their own notifications.
class NotificationService extends ChangeNotifier with DisposeSafe {
  NotificationService(this.uid);

  final String uid;

  /// Android and the web for now; iPhone/Mac need APNs set up first.
  static bool get supported => kIsWeb || defaultTargetPlatform == TargetPlatform.android;

  AuthorizationStatus? status;
  bool registered = false;
  String? error;

  /// The latest notification that came in while the app was open.
  final foreground = ValueNotifier<RemoteNotification?>(null);

  final List<StreamSubscription> _subs = [];
  String? _deviceId;

  static const _askedKey = 'optimizer.notifications.asked';

  bool get enabled => registered && status == AuthorizationStatus.authorized;

  CollectionReference<Map<String, dynamic>> get _devices =>
      FirebaseFirestore.instance.collection('axisCalendar').doc(uid).collection('devices');

  // Android shows pushes in the tray only while Optimizer is closed; while
  // it's open this puts them there too, on the same channel.
  static final _local = FlutterLocalNotificationsPlugin();
  static const _channel = AndroidNotificationChannel(
    'canvas_alerts',
    'Canvas alerts',
    description: 'New assignments and changed due dates',
    importance: Importance.high,
  );
  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _setUpAndroid() async {
    await _local.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    await _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(_channel);
  }

  void _onForeground(RemoteMessage m) {
    foreground.value = m.notification;
    final n = m.notification;
    if (!_android || n == null) return;
    _local.show(
      id: m.hashCode,
      title: n.title,
      body: n.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(_channel.id, _channel.name,
            channelDescription: _channel.description, importance: Importance.high, priority: Priority.high),
      ),
    );
  }

  /// Checks where things stand; registers again if already allowed (tokens change).
  Future<void> init() async {
    if (!supported) return;
    try {
      if (_android) await _setUpAndroid();
      status = (await FirebaseMessaging.instance.getNotificationSettings()).authorizationStatus;
      if (status == AuthorizationStatus.authorized) await _register();
      _subs.add(FirebaseMessaging.onMessage.listen(_onForeground));
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  /// Whether to show the "turn on notifications?" prompt: not on, and never
  /// asked. (Android reports "denied" until it has been asked even once, so
  /// "denied" alone doesn't mean you said no.)
  Future<bool> shouldAsk() async {
    if (!supported || status == AuthorizationStatus.authorized) return false;
    try {
      return !((await SharedPreferences.getInstance()).getBool(_askedKey) ?? false);
    } catch (_) {
      return false;
    }
  }

  Future<void> markAsked() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_askedKey, true);
    } catch (_) {}
  }

  /// Asks the system for permission and registers this device. True if on.
  Future<bool> enable() async {
    await markAsked();
    try {
      final s = await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
      status = s.authorizationStatus;
      if (status == AuthorizationStatus.authorized) await _register();
      error = null;
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
    return enabled;
  }

  /// Stops notifications on this device (others keep theirs).
  Future<void> disable() async {
    final id = await _id();
    try {
      await _devices.doc(id).delete();
      registered = false;
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  /// Sends a test notification to every device you've turned them on for,
  /// [delaySeconds] from now (so you can leave the app and see it arrive).
  Future<int> sendTest({int delaySeconds = 0}) async {
    final r = await FirebaseFunctions.instance.httpsCallable('sendTestNotification').call({'delaySeconds': delaySeconds});
    return ((r.data as Map)['sent'] as num?)?.toInt() ?? 0;
  }

  Future<void> _register() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return;
    await _save(token);
    _subs.add(FirebaseMessaging.instance.onTokenRefresh.listen(_save));
  }

  Future<void> _save(String token) async {
    String zone;
    try {
      zone = (await FlutterTimezone.getLocalTimezone()).identifier;
    } catch (_) {
      zone = 'UTC';
    }
    await _devices.doc(await _id()).set({
      'token': token,
      'timeZone': zone,
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      if (appOrigin != null) 'origin': appOrigin,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    registered = true;
    error = null;
    notifyListeners();
  }

  /// A random id for this install, so each device has its own entry.
  Future<String> _id() async {
    if (_deviceId != null) return _deviceId!;
    const key = 'optimizer.deviceId';
    try {
      final p = await SharedPreferences.getInstance();
      _deviceId = p.getString(key);
      if (_deviceId == null) {
        final r = Random.secure();
        _deviceId = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        await p.setString(key, _deviceId!);
      }
    } catch (_) {
      _deviceId ??= 'device-${DateTime.now().millisecondsSinceEpoch}';
    }
    return _deviceId!;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    foreground.dispose();
    super.dispose();
  }
}
