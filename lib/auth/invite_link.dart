import 'package:flutter/foundation.dart';

/// The invitation in the address the site was opened at
/// (optimizer.axisoptic.com/?invite=…), from an email inviting someone who
/// isn't on Optimizer yet. Only with one can a new account be made.
String? pendingInviteToken = kIsWeb ? Uri.base.queryParameters['invite'] : null;
