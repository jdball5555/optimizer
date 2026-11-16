import 'package:firebase_analytics/firebase_analytics.dart';

/// Records a page view for Google Analytics (shown in Axis Optic →
/// Optimizer → Traffic). Never throws.
void logPage(String name) {
  try {
    FirebaseAnalytics.instance.logScreenView(screenName: name, screenClass: name).catchError((Object _) {});
  } catch (_) {}
}
