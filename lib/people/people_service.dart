import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../util/dispose_safe.dart';
import 'invites.dart';

/// A group you own or belong to.
class PeopleGroup {
  PeopleGroup(this.id, Map<String, dynamic> d)
      : name = '${d['name'] ?? 'Group'}',
        ownerName = '${d['ownerName'] ?? ''}',
        mine = d['role'] == 'owner',
        members = guestsFrom(d['members']);

  final String id;
  final String name;
  final String ownerName;

  /// You made it (and can invite, remove, rename and delete).
  final bool mine;
  final List<Guest> members;

  /// Everyone in it who said yes, and its owner: who an event invite to the
  /// group goes to.
  List<String> get emails => [for (final m in members) if (m.status == 'accepted' || m.status == 'owner') m.email];
}

/// Your groups and your place on Optimizer's list of people (functions/people.js
/// keeps optimizer/{uid}/groups up to date).
class PeopleService extends ChangeNotifier with DisposeSafe {
  PeopleService(this.uid) {
    _sub = FirebaseFirestore.instance.collection('optimizer').doc(uid).collection('groups').snapshots().listen((s) {
      groups = [for (final d in s.docs) PeopleGroup(d.id, d.data())]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      loaded = true;
      notifyListeners();
    }, onError: (Object e) {
      error = '$e';
      notifyListeners();
    });
  }

  /// For previews and tests: groups given, nothing read.
  @visibleForTesting
  PeopleService.preview(this.uid, this.groups) : loaded = true;

  final String uid;
  StreamSubscription? _sub;
  List<PeopleGroup> groups = [];
  bool loaded = false;
  String? error;

  Future<Object?> _call(String name, Map<String, dynamic> data) async {
    try {
      return (await FirebaseFunctions.instance
              .httpsCallable(name, options: HttpsCallableOptions(timeout: const Duration(minutes: 2)))
              .call(data))
          .data;
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? e.code);
    }
  }

  /// Puts you on the list of people others can invite, and picks up
  /// invitations already sent to your email.
  Future<void> registerMe(String? name) => _call('registerMe', {if (name != null) 'name': name});

  /// After signing up from an invitation link: that invitation becomes yours.
  Future<void> claimInvite(String token) => _call('claimInvite', {'token': token});

  Future<String> saveGroup(String name, {PeopleGroup? group}) async {
    final r = await _call('saveGroup', {'name': name, if (group != null) 'groupId': group.id});
    return '${(r as Map?)?['groupId'] ?? ''}';
  }

  /// Returns links for people not on Optimizer yet, to send them.
  Future<InviteLinks> inviteToGroup(String groupId, List<String> emails) async =>
      inviteLinksFrom(await _call('inviteToGroup', {'groupId': groupId, 'emails': emails}));

  /// Removes [email] from your group, or (no email) takes you out of it.
  Future<void> removeFromGroup(PeopleGroup g, {String? email}) => _call('removeFromGroup', {'groupId': g.id, if (email != null) 'email': email});

  Future<void> deleteGroup(PeopleGroup g) => _call('deleteGroup', {'groupId': g.id});

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
