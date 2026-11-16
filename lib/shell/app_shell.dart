import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../ai/ai_context.dart';
import '../ai/ai_service.dart';
import '../ai/assistant.dart';
import '../ai/assistant_panel.dart';
import '../ai/chat_page.dart';
import '../calendar/calendar_page.dart';
import '../calendar/calendar_service.dart';
import '../calendar/canvas_section.dart';
import '../dashboard/dashboard_page.dart';
import '../focus/focus_page.dart';
import '../focus/focus_store.dart';
import '../journal/journal_page.dart';
import '../journal/habit_store.dart';
import '../journal/journal_store.dart';
import '../networth/finance_store.dart';
import '../networth/net_worth_page.dart';
import '../notifications/notification_service.dart';
import '../premium/premium_beta.dart';
import '../settings/settings_page.dart';
import '../theme.dart';
import 'side_nav.dart';
import '../auth/invite_link.dart';
import '../people/people_page.dart';
import '../people/people_service.dart';
import '../trips/trip_store.dart';
import '../trips/trips_page.dart';
import '../util/analytics.dart';
import '../widgets/tiles.dart' show PageEnd;

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.user});

  final User user;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  /// The page last sent to Analytics.
  int? _loggedIndex;
  // One of each, shared by every page, so the dashboard and the pages show
  // the same live data without loading it twice.
  late final CalendarService _calendar = CalendarService(widget.user.uid)..init();
  late final JournalStore _journal = JournalStore(widget.user.uid);
  late final FinanceStore _finance = FinanceStore(widget.user.uid);
  late final NotificationService _notifications = NotificationService(widget.user.uid);
  late final HabitStore _habits = HabitStore(widget.user.uid);
  late final AiService _ai = AiService(widget.user.uid);
  // Net worth and the assistant are premium beta features (switched on in Optic).
  late final PremiumBeta _premium = PremiumBeta(widget.user);
  // The built-in assistant, beside every page (and full size on the Ask page).
  late final AssistantController _assistant = AssistantController(
    ai: _ai,
    calendar: _calendar,
    trips: _trips,
    context: () => buildAiContext(
      shared: _ai.shared,
      name: _firstName(widget.user),
      calendar: _calendar,
      journal: _journal,
      habits: _habits,
      finance: _finance,
    ),
    navigate: _openFromAssistant,
  );
  // One of it, so a page's title row only rebuilds when it comes or goes.
  late final Widget _assistantArrowRoom = AssistantArrowRoom(open: _assistant.panelOpen);
  late final Widget _assistantPanel = AssistantChat(
    controller: _assistant,
    onOpenSettings: _openSettingsFromPanel,
    onClose: () => _assistant.panelOpen.value = false,
  );
  late final FocusStore _focus = FocusStore(widget.user.uid);
  bool _focusOpen = false;
  late final PeopleService _people = PeopleService(widget.user.uid);
  late final TripStore _trips = TripStore(widget.user.uid);

  @override
  void initState() {
    super.initState();
    loadHideAmounts();
    loadCalendarLayout();
    _calendar.addListener(_askAboutPast);
    _calendar.people = _people;
    _trips
      ..people = _people
      ..myEmail = widget.user.email?.toLowerCase();
    _calendar.onOpenTrip = (id) {
      _trips.open(id);
      setState(() => _index = _tripsPage);
    };
    _trips.addListener(_tripsChanged);
    _joinPeople();
    _finishGoogleConnect();
    _notifications.foreground.addListener(_showForeground);
    _startNotifications();
    _premium.addListener(_premiumChanged);
  }

  /// Premium beta switched on or off (in Optic) while the app is open.
  void _premiumChanged() {
    if (!mounted) return;
    if (!_premium.on) _assistant.panelOpen.value = false;
    setState(() {});
  }

  /// Back from Google after Connect or Reconnect: link the account and say how it went.
  Future<void> _finishGoogleConnect() async {
    String message;
    try {
      final email = await _calendar.finishConnect();
      if (email == null) return;
      message = 'Connected $email. Its calendars are syncing.';
    } catch (e) {
      message = 'Couldn’t connect Google Calendar: ${'$e'.replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() => _index = _calendarPage);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: SelectableText(message),
      duration: const Duration(seconds: 10),
      showCloseIcon: true,
    ));
  }

  /// The first time the app opens, offer notifications for Canvas assignments.
  Future<void> _startNotifications() async {
    await _notifications.init();
    if (!mounted || !await _notifications.shouldAsk() || !mounted) return;
    await offerNotifications(context, _notifications);
  }

  /// A notification that arrives while Optimizer is open shows as a banner.
  void _showForeground() {
    final n = _notifications.foreground.value;
    if (n == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      showCloseIcon: true,
      content: Row(children: [
        const Icon(Icons.notifications_active_outlined, color: AppColors.primaryText),
        const SizedBox(width: 12),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (n.title != null) Text(n.title!, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (n.body != null) Text(n.body!),
          ]),
        ),
      ]),
    ));
  }

  static const _destinations = [
    (icon: Icons.dashboard_outlined, selected: Icons.dashboard, label: 'Home'),
    (icon: Icons.calendar_view_week_outlined, selected: Icons.calendar_view_week, label: 'Calendar'),
    (icon: Icons.flight_takeoff_outlined, selected: Icons.flight_takeoff, label: 'Trips'),
    (icon: Icons.menu_book_outlined, selected: Icons.menu_book, label: 'Journal'),
    (icon: Icons.show_chart_outlined, selected: Icons.show_chart, label: 'Net worth'),
    (icon: Icons.auto_awesome_outlined, selected: Icons.auto_awesome, label: 'Ask'),
    (icon: Icons.people_outline, selected: Icons.people, label: 'People'),
    // In the website's side bar only; on a phone it's under your picture.
    (icon: Icons.settings_outlined, selected: Icons.settings, label: 'Settings'),
  ];
  static const _calendarPage = 1;
  static const _tripsPage = 2;
  static const _netWorthPage = 4;
  static const _askPage = 5;
  static const _peoplePage = 6;
  static const _settingsPage = 7;

  /// Premium beta's pages: without it they're left out of the bars.
  static const _premiumPages = {_netWorthPage, _askPage};

  bool _shown(int page) => _premium.on || !_premiumPages.contains(page);

  /// The side bar's pages.
  List<int> get _sideBar => [
        for (var i = 0; i < _destinations.length; i++)
          if (_shown(i)) i
      ];

  // A phone's bar holds six at most, so Trips opens from the calendar instead.
  List<int> get _phoneBar => [
        for (final i in const [0, _calendarPage, 3, _netWorthPage, _askPage, _peoplePage])
          if (_shown(i)) i
      ];

  @override
  void dispose() {
    _calendar.removeListener(_askAboutPast);
    _calendar.dispose();
    _journal.dispose();
    _finance.dispose();
    _notifications.foreground.removeListener(_showForeground);
    _notifications.dispose();
    _habits.dispose();
    _assistant.dispose();
    _ai.dispose();
    _premium.removeListener(_premiumChanged);
    _premium.dispose();
    _focus.dispose();
    _people.dispose();
    _trips.removeListener(_tripsChanged);
    _trips.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final windowWidth = MediaQuery.sizeOf(context).width;
    final wide = windowWidth >= 720;
    final premium = _premium.on;
    final pushes = wide && AssistantSplit.fits(windowWidth);
    final pages = [
      DashboardPage(
        // On a phone there's no side rail, so your picture sits on the first page.
        account: wide ? null : _accountMenu(),
        focus: FocusButton(onOpen: () => setState(() => _focusOpen = true)),
        name: _firstName(widget.user),
        uid: widget.user.uid,
        calendar: _calendar,
        journal: _journal,
        finance: _finance,
        money: premium,
        onNavigate: (i) => setState(() => _index = i),
      ),
      CalendarPage(service: _calendar, notifications: _notifications, onOpenTrips: () => setState(() => _index = _tripsPage)),
      TripsPage(store: _trips, active: _index == _tripsPage, onBack: wide ? null : () => setState(() => _index = _calendarPage)),
      JournalPage(store: _journal, habits: _habits),
      premium ? NetWorthPage(store: _finance, active: _index == _netWorthPage) : const SizedBox.shrink(),
      premium ? ChatPage(controller: _assistant, onOpenSettings: _openSettings) : const SizedBox.shrink(),
      PeoplePage(people: _people, calendar: _calendar, myEmail: widget.user.email ?? ''),
      SettingsPage(user: widget.user, notifications: _notifications, calendar: _calendar, ai: _ai, premium: _premium, embedded: true),
    ];
    // A phone has no Settings page in its bar: back to Home if it was open.
    if (!wide && _index == _settingsPage) _index = 0;
    // A premium page with premium beta switched off: back to Home.
    if (!_shown(_index)) _index = 0;
    if (_index != _loggedIndex) {
      _loggedIndex = _index;
      logPage(_destinations[_index].label);
    }
    // The Ask page already is the assistant: no arrow or panel there. Without
    // premium beta there's no assistant at all.
    final onAsk = _index == _askPage;
    final assistant = premium && !onAsk;
    final body = PageEnd(
      end: assistant ? _assistantArrowRoom : null,
      child: IndexedStack(index: _index, children: pages),
    );

    final shell = wide
        ? _wideShell(AssistantSplit(open: _assistant.panelOpen, enabled: pushes && assistant, panel: _assistantPanel, child: body))
        : _phoneShell(body);
    // During a session the app stays on the focus page, on every device.
    return FocusGate(
      store: _focus,
      open: _focusOpen,
      onClose: () => setState(() => _focusOpen = false),
      child: AssistantOverlay(open: _assistant.panelOpen, enabled: !pushes && assistant, arrow: assistant, panel: _assistantPanel, child: shell),
    );
  }

  // No title bar: each page starts right under the status bar.
  Widget _phoneShell(Widget body) {
    final bar = _phoneBar;
    return Scaffold(
      body: SafeArea(bottom: false, child: body),
      bottomNavigationBar: NavigationBar(
        height: 64,
        // On Trips, which isn't in the bar, the calendar it opens from stays lit.
        selectedIndex: bar.indexOf(_index == _tripsPage ? _calendarPage : _index),
        onDestinationSelected: (i) => setState(() => _index = bar[i]),
        destinations: [
          for (final i in bar)
            NavigationDestination(icon: Icon(_destinations[i].icon), selectedIcon: Icon(_destinations[i].selected), label: _destinations[i].label),
        ],
      ),
    );
  }

  Widget _wideShell(Widget body) {
    final side = _sideBar;
    return Scaffold(
      body: Row(
        children: [
          SideNav(
            items: [for (final i in side) _destinations[i]],
            selected: side.indexOf(_index),
            onSelected: (i) => setState(() => _index = side[i]),
            account: (expanded) => SideNavAccount(
              name: (widget.user.displayName?.isNotEmpty ?? false) ? widget.user.displayName! : (widget.user.email ?? ''),
              email: widget.user.email ?? '',
              expanded: expanded,
              onSettings: _openSettings,
              onSignOut: () => FirebaseAuth.instance.signOut(),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  void _tripsChanged() => _calendar.setTrips(_trips.trips);

  /// Settings would sit under a panel that's on top of the page: close it first.
  void _openSettingsFromPanel() {
    if (!AssistantSplit.fits(MediaQuery.sizeOf(context).width)) _assistant.panelOpen.value = false;
    _openSettings();
  }

  /// The assistant opening a page for you. On a phone the panel covers the
  /// page, so it closes to show it.
  void _openFromAssistant(String page) {
    if (!mounted) return;
    if (page == 'settings') {
      _openSettings();
      return;
    }
    final i = switch (page) {
      'calendar' => _calendarPage,
      'trips' => _tripsPage,
      'journal' => 3,
      'net_worth' => _netWorthPage,
      'people' => _peoplePage,
      _ => 0,
    };
    setState(() => _index = _shown(i) ? i : 0);
    if (MediaQuery.sizeOf(context).width < 720) _assistant.panelOpen.value = false;
  }

  /// On Optimizer's list of people (so others can invite you), and, after
  /// signing up from an emailed invitation, that invitation becomes yours.
  Future<void> _joinPeople() async {
    try {
      await _people.registerMe(FirebaseAuth.instance.currentUser?.displayName ?? widget.user.displayName);
      final token = pendingInviteToken;
      if (token != null) {
        pendingInviteToken = null;
        await _people.claimInvite(token);
        if (mounted) setState(() => _index = _peoplePage);
      }
    } catch (_) {
      // Tried again next time the app opens.
    }
  }

  final _askedPast = <String>{};

  /// Keeping past events, a newly added calendar's past waits for a yes or
  /// no: asked once, wherever you are in the app.
  Future<void> _askAboutPast() async {
    if (!_calendar.keepPast || !mounted) return;
    for (final key in [..._calendar.pastPending]) {
      final cal = _calendar.pendingCalendar(key);
      if (cal == null || !_askedPast.add(key)) continue;
      if (!mounted) return;
      final keep = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text('Save past events from “${cal.name}”?'),
          content: Text(
            '${cal.name} (${cal.accountEmail}) is new in Optimizer. Save its events from the past year too? '
            'If not, Optimizer keeps only what’s still to come from it.',
            style: const TextStyle(color: AppColors.secondaryText, height: 1.4),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Don’t save')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save past events')),
          ],
        ),
      );
      if (keep == null || !mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        final saved = await _calendar.resolvePast(key, keep: keep);
        if (keep) messenger.showSnackBar(SnackBar(content: Text('Saved $saved past events from ${cal.name}')));
      } catch (e) {
        _askedPast.remove(key);
        messenger.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
      }
    }
  }

  /// The Settings page in the side bar on a wide screen; on a phone, opened over the app.
  void _openSettings() {
    if (MediaQuery.sizeOf(context).width >= 720) {
      setState(() => _index = _settingsPage);
      return;
    }
    SettingsPage.open(context, user: widget.user, notifications: _notifications, calendar: _calendar, ai: _ai, premium: _premium);
  }

  /// "Alex" from the account's name, or else from its email address.
  static String? _firstName(User u) {
    final from = (u.displayName?.trim().isNotEmpty ?? false) ? u.displayName!.trim() : (u.email ?? '').split('@').first;
    final first = from.split(RegExp(r'[\s._\-0-9]+')).firstWhere((w) => w.isNotEmpty, orElse: () => '');
    if (first.isEmpty) return null;
    return '${first[0].toUpperCase()}${first.substring(1).toLowerCase()}';
  }

  Widget _accountMenu() {
    final u = widget.user;
    final name = (u.displayName?.isNotEmpty ?? false) ? u.displayName! : (u.email ?? '');
    final label = name.isEmpty ? 'Axis user' : name;
    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: (v) {
        if (v == 'settings') _openSettings();
        if (v == 'out') FirebaseAuth.instance.signOut();
      },
      itemBuilder: (_) => [
        PopupMenuItem(enabled: false, child: Text(u.email ?? label)),
        const PopupMenuItem(
          value: 'settings',
          child: Row(children: [Icon(Icons.settings_outlined, size: 18), SizedBox(width: 10), Text('Settings')]),
        ),
        const PopupMenuItem(value: 'out', child: Text('Sign out')),
      ],
      child: CircleAvatar(
        radius: 16,
        child: Text(label.characters.first.toUpperCase()),
      ),
    );
  }
}
