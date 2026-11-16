import '../util/fields.dart';

/// Someone on a guest list or in a group, and where they stand: 'pending',
/// 'accepted', 'declined', or 'organizer' / 'owner'.
class Guest {
  Guest(Map d)
      : email = '${d['email'] ?? ''}',
        name = '${d['name'] ?? ''}',
        status = '${d['status'] ?? 'pending'}';

  final String email;
  final String name;
  final String status;

  String get shown => name.isEmpty ? email : name;
}

List<Guest> guestsFrom(Object? list) => [for (final g in (list as List? ?? const [])) if (g is Map) Guest(g)];

/// An invitation to you, to an event or a group (optimizer/{uid}/invites,
/// kept up to date by the server).
class Invite {
  Invite(this.id, Map<String, dynamic> d)
      : kind = '${d['kind'] ?? 'event'}',
        status = '${d['status'] ?? 'pending'}',
        fromName = '${d['fromName'] ?? ''}',
        fromEmail = '${d['fromEmail'] ?? ''}',
        groupId = d['groupId'] as String?,
        groupName = '${(d['group'] as Map?)?['name'] ?? ''}',
        event = d['event'] is Map ? Map<String, dynamic>.from(d['event'] as Map) : null,
        guests = d['guests'] == null ? null : guestsFrom(d['guests']),
        createdAt = asDate(d['createdAt']);

  final String id;

  /// 'event' or 'group'.
  final String kind;
  final String status;
  final String fromName;
  final String fromEmail;
  final String? groupId;
  final String groupName;
  final Map<String, dynamic>? event;

  /// The event's guests, if the organizer lets guests see them.
  final List<Guest>? guests;
  final DateTime? createdAt;

  bool get pending => status == 'pending';
  bool get isEvent => kind == 'event' && event != null;

  String get title => isEvent ? '${event!['title'] ?? 'Event'}' : groupName;
  DateTime? get start => isEvent ? DateTime.fromMillisecondsSinceEpoch((event!['start'] as num?)?.toInt() ?? 0) : null;
  DateTime? get end => isEvent ? DateTime.fromMillisecondsSinceEpoch((event!['end'] as num?)?.toInt() ?? 0) : null;
  bool get allDay => event?['allDay'] == true;
}

/// The guests of one of your events (optimizer/{uid}/sentEvents), by its key.
class EventGuests {
  EventGuests(Map<String, dynamic> d)
      : eventKey = '${d['eventKey'] ?? ''}',
        guestsCanSeeList = d['guestsCanSeeList'] != false,
        guests = guestsFrom(d['guests']);

  final String eventKey;
  final bool guestsCanSeeList;
  final List<Guest> guests;
}

/// Links for the people you invited who aren't on Optimizer yet, for you
/// to send them (each lets that person make an account and answer).
typedef InviteLinks = List<({String email, String link})>;

InviteLinks inviteLinksFrom(Object? r) => [
      for (final x in ((r is Map ? r['links'] : null) as List? ?? const []))
        if (x is Map) (email: '${x['email']}', link: '${x['link']}'),
    ];
