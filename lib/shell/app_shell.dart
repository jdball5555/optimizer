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
import '../settings/feedback_page.dart';
import '../settings/settings_page.dart';
import '../theme.dart';
import '../todos/todos_page.dart';
import 'side_nav.dart';
import '../auth/invite_link.dart';
import '../auth/profile.dart';
import '../people/people_page.dart';
import '../people/people_service.dart';
import '../trips/trip_store.dart';
import '../trips/trips_page.dart';
import '../util/analytics.dart';
import '../widgets/tiles.dart' show PageEnd, PageMenu;

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.user});

  final User user;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = _todosPage;

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
  // Every page but To-dos (and Settings) is a premium beta feature (switched on in Optic).
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

  /// On a small screen, the side bar slides in over the app from this
  /// scaffold, opened by the ☰ at the start of each page's top row.
  final _shellKey = GlobalKey<ScaffoldState>();
  void _openMenu() => _shellKey.currentState?.openDrawer();
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
  @override
  void didUpdateWidget(AppShell old) {
    super.didUpdateWidget(old);
    // A new name (from Settings, or just after making the account): People
    // shows it to others too.
    final name = widget.user.displayName;
    if (name != null && name.isNotEmpty && name != old.user.displayName) {
      _people.registerMe(name).catchError((Object _) {});
    }
  }

  void _premiumChanged() {
    if (!mounted) return;
    if (!_premium.on) _assistant.panelOpen.value = false;
    setState(() {
      if (!_premium.on) _focusOpen = false;
    });
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
    (icon: Icons.settings_outlined, selected: Icons.settings, label: 'Settings'),
    // Last here so the pages before keep their numbers; first in the bars.
    (icon: Icons.check_circle_outline, selected: Icons.check_circle, label: 'To-dos'),
  ];
  static const _homePage = 0;
  static const _calendarPage = 1;
  static const _tripsPage = 2;
  static const _netWorthPage = 4;
  static const _askPage = 5;
  static const _peoplePage = 6;
  static const _settingsPage = 7;
  static const _todosPage = 8;

  /// Everyone's pages: To-dos and Settings. The rest are premium beta's and
  /// left out of the bars without it.
  static const _everyonePages = {_todosPage, _settingsPage};

  /// Premium beta's pages, in the side bar's order, under a line (as Axis Team sets its extra pages apart).
  static const _premiumPages = [_homePage, _calendarPage, _tripsPage, 3, _netWorthPage, _askPage, _peoplePage];

  bool _shown(int page) => _premium.on || _everyonePages.contains(page);

  /// The side bar's pages.
  List<int> get _sideBar => [_todosPage, _settingsPage, if (_premium.on) ..._premiumPages];

  /// Where the side bar's lines go: around premium beta's pages.
  Set<int> get _sideBarLines => _premium.on ? {_everyonePages.length, _sideBar.length} : const {};

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
      premium
          ? DashboardPage(
              focus: FocusButton(onOpen: () => setState(() => _focusOpen = true)),
              name: _firstName(widget.user),
              uid: widget.user.uid,
              calendar: _calendar,
              journal: _journal,
              finance: _finance,
              money: premium,
              onNavigate: (i) => setState(() => _index = i),
            )
          : const SizedBox.shrink(),
      premium
          ? CalendarPage(service: _calendar, notifications: _notifications, onOpenTrips: () => setState(() => _index = _tripsPage))
          : const SizedBox.shrink(),
      premium
          ? TripsPage(store: _trips, active: _index == _tripsPage, onBack: wide ? null : () => setState(() => _index = _calendarPage))
          : const SizedBox.shrink(),
      premium ? JournalPage(store: _journal, habits: _habits) : const SizedBox.shrink(),
      premium ? NetWorthPage(store: _finance, active: _index == _netWorthPage) : const SizedBox.shrink(),
      premium ? ChatPage(controller: _assistant, onOpenSettings: _openSettings) : const SizedBox.shrink(),
      premium ? PeoplePage(people: _people, calendar: _calendar, myEmail: widget.user.email ?? '') : const SizedBox.shrink(),
      SettingsPage(user: widget.user, notifications: _notifications, calendar: _calendar, ai: _ai, premium: _premium, embedded: true),
      TodosPage(service: _calendar, notifications: _notifications, premium: premium),
    ];
    // A premium page with premium beta switched off: back to To-dos.
    if (!_shown(_index)) _index = _todosPage;
    if (_index != _loggedIndex) {
      _loggedIndex = _index;
      logPage(_destinations[_index].label);
    }
    // The Ask page already is the assistant: no arrow or panel there. Without
    // premium beta there's no assistant at all.
    final onAsk = _index == _askPage;
    final assistant = premium && !onAsk;
    // First in every page's top row on a small screen, the ☰ for the side
    // bar; last, room for the assistant's arrow in the corner.
    final body = PageMenu(
      open: wide ? null : _openMenu,
      child: PageEnd(
        end: assistant ? _assistantArrowRoom : null,
        child: IndexedStack(index: _index, children: pages),
      ),
    );

    final shell = wide
        ? _wideShell(AssistantSplit(open: _assistant.panelOpen, enabled: pushes && assistant, panel: _assistantPanel, child: body))
        : _phoneShell(body);
    // During a session the app stays on the focus page, on every device.
    return FocusGate(
      store: _focus,
      enabled: premium,
      open: _focusOpen,
      onClose: () => setState(() => _focusOpen = false),
      child: AssistantOverlay(open: _assistant.panelOpen, enabled: !pushes && assistant, arrow: assistant, panel: _assistantPanel, child: shell),
    );
  }

  // No title bar or bottom bar: each page starts right under the status bar,
  // and its ☰ slides the website's side bar in over the app.
  Widget _phoneShell(Widget body) {
    void go(VoidCallback f) {
      _shellKey.currentState?.closeDrawer();
      f();
    }

    return Scaffold(
      key: _shellKey,
      drawer: Drawer(
        width: SideNav.expandedWidth,
        backgroundColor: AppColors.background,
        shape: const Border(right: BorderSide(color: AppColors.border)),
        child: SafeArea(child: _sideNav(inDrawer: true, go: go)),
      ),
      body: SafeArea(child: body),
    );
  }

  /// The side bar, on the website's left or (with [inDrawer]) over the app.
  /// [go] runs what you picked (closing the drawer first).
  Widget _sideNav({bool inDrawer = false, void Function(VoidCallback) go = _now}) {
    final side = _sideBar;
    return SideNav(
      inDrawer: inDrawer,
      items: [for (final i in side) _destinations[i]],
      linesBefore: _sideBarLines,
      selected: side.indexOf(_index),
      onSelected: (i) => go(() => setState(() => _index = side[i])),
      onFeedback: () => go(() => FeedbackPage.open(context, premium: _premium)),
      account: (expanded) => SideNavAccount(
        name: (widget.user.displayName?.isNotEmpty ?? false) ? widget.user.displayName! : (widget.user.email ?? ''),
        email: widget.user.email ?? '',
        expanded: expanded,
        onSettings: () => go(_openSettings),
        onSignOut: () => go(() => FirebaseAuth.instance.signOut()),
      ),
    );
  }

  static void _now(VoidCallback f) => f();

  Widget _wideShell(Widget body) => Scaffold(body: Row(children: [_sideNav(), Expanded(child: body)]));

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
      'todos' => _todosPage,
      _ => _homePage,
    };
    setState(() => _index = _shown(i) ? i : _todosPage);
    if (MediaQuery.sizeOf(context).width < 720) _assistant.panelOpen.value = false;
  }

  /// On Optimizer's list of people (so others can invite you), and, after
  /// signing up from an emailed invitation, that invitation becomes yours.
  ///
  /// Both need a verified email (the server matches invitations by it): an
  /// account just verified gets a fresh sign-in first, so the server sees it.
  /// Until then registerMe does nothing, and an invitation waits for your
  /// email to be verified (registerMe picks it up then).
  Future<void> _joinPeople() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && !user.emailVerified) {
        await user.reload();
        if (FirebaseAuth.instance.currentUser?.emailVerified == true) {
          await FirebaseAuth.instance.currentUser!.getIdToken(true);
          profileChanged.value++;
        }
      }
      await _people.registerMe(FirebaseAuth.instance.currentUser?.displayName ?? widget.user.displayName);
      final token = pendingInviteToken;
      if (token != null && FirebaseAuth.instance.currentUser?.emailVerified == true) {
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

  /// The Settings page, in the side bar on every screen.
  void _openSettings() => setState(() => _index = _settingsPage);

  /// "Alex" from the account's name, or else from its email address.
  static String? _firstName(User u) {
    final from = (u.displayName?.trim().isNotEmpty ?? false) ? u.displayName!.trim() : (u.email ?? '').split('@').first;
    final first = from.split(RegExp(r'[\s._\-0-9]+')).firstWhere((w) => w.isNotEmpty, orElse: () => '');
    if (first.isEmpty) return null;
    return '${first[0].toUpperCase()}${first.substring(1).toLowerCase()}';
  }
}
