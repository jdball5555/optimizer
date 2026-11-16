import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'auth/auth_gate.dart';
import 'calendar/google_token.dart';
import 'firebase_options.dart';
import 'theme.dart';
import 'trips/trip_zones.dart';
import 'widgets/calm_scrollbar.dart';

Future<void> main() async {
  // Coming back from linking Google Calendar: take the result from the
  // address before anything changes it.
  captureGoogleReturn();
  WidgetsFlutterBinding.ensureInitialized();
  loadDeviceZone();
  Object? initError;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    // Keep Firestore data on the device (the phone does by default; the
    // browser doesn't), so pages open from it at once and update after.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
  } catch (e) {
    initError = e;
  }
  runApp(OptimizerApp(initError: initError));
}

class OptimizerApp extends StatelessWidget {
  const OptimizerApp({super.key, this.initError});

  final Object? initError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Optimizer',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      scrollBehavior: const CalmScrollBehavior(),
      home: initError == null ? const AuthGate() : _SetupError(error: initError!),
    );
  }
}

class _SetupError extends StatelessWidget {
  const _SetupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Optimizer isn’t connected to Firebase yet', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                SelectableText('$error'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
