import 'package:flutter/foundation.dart';

/// For the app's data stores: Firestore streams, Google and Cloud Function
/// calls can finish after the store has been closed (signing out, switching
/// accounts). Their late results are dropped instead of hitting a disposed
/// ChangeNotifier, which Flutter treats as an error.
mixin DisposeSafe on ChangeNotifier {
  bool _disposed = false;

  bool get disposed => _disposed;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
