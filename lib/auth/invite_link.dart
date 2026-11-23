import 'package:flutter/foundation.dart';

/// The invitation in the address the site was opened at
/// (optimizer.axisoptic.com/?invite=…), from an email inviting someone who
/// isn't on Optimizer yet: the sign-in page says who invited you and starts
/// on making an account.
String? pendingInviteToken = kIsWeb ? Uri.base.queryParameters['invite'] : null;
