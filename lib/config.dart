/// Everything you may need to adjust so Optimizer lines up with your
/// existing Axis apps lives in this one file.
class AppConfig {
  /// OAuth 2.0 *Web* client ID from Google Cloud Console → APIs & Services →
  /// Credentials, in the same Google Cloud project as your Axis Firebase
  /// project. Firebase creates one automatically, named
  /// "Web client (auto created by Google Service)".
  /// Its Authorized JavaScript origins must include the address the site
  /// runs at (http://localhost:5050 when run locally).
  static const googleWebClientId = '290026173104-m5ck0iih0mpphjoqipv3ttv81vrvetft.apps.googleusercontent.com';

  /// Full read/write access so you can create, edit and delete events.
  static const googleCalendarScope = 'https://www.googleapis.com/auth/calendar';
}

/// Where your Axis data lives in Firestore, matching what the Axis Journal
/// (my_journal_app) and Asset Track apps already read and write.
class AxisSchema {
  /// Axis Journal keeps every user's entries in one top-level collection,
  /// tagged with the owner's uid.
  static const journalCollection = 'axis_journal_entries';
  static const journalUserField = 'userId';

  /// Asset Track keeps net worth snapshots in the same subcollection as
  /// transactions, Plaid items etc.; `docType` tells them apart.
  static String netWorthPath(String uid) => 'assetTrack/$uid/assetData';
  static const netWorthDocType = 'netWorthSnapshot';

  // Fields tried, in order, when reading existing documents.
  static const journalTitleFields = ['header', 'title', 'subject', 'heading', 'name'];
  static const journalBodyFields = ['content', 'body', 'text', 'entry', 'note', 'notes'];
  // appearsAsDate is the Journal's "yyyy-MM-dd" display date; timestamp is
  // what Asset Track snapshots use.
  static const dateFields = ['appearsAsDate', 'timestamp', 'date', 'createdAt', 'created', 'day', 'updatedAt'];
  static const netWorthTotalFields = ['netWorth', 'total', 'value', 'amount', 'balance'];
  static const assetsFields = ['assets', 'totalAssets'];
  static const liabilitiesFields = ['liabilities', 'debts', 'totalLiabilities', 'debt'];

  // Field names used when Optimizer creates a NEW document. When it edits an
  // existing one, it writes back to whichever field that document already uses.
  static const writeTitle = 'header';
  static const writeBody = 'content';
  static const writeNetWorth = 'netWorth';
  static const writeAssets = 'assets';
  static const writeLiabilities = 'liabilities';
}
