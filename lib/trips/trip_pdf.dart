import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../widgets/link_text.dart';
import 'trip_models.dart';
import 'trip_schedule.dart';
import 'trip_zones.dart';

// The itinerary to print or send: black and white, so an icon says what each
// thing is, in the same shape as on screen, with the fuller details.

const _timeWidth = 78.0, _rail = 24.0;
const _dotY = 9.0;
const _gray = PdfColor.fromInt(0xFF555555);

/// The fonts have no thin space, which time formats use.
String _plain(String s) => s.replaceAll(' ', ' ').replaceAll(' ', ' ');

/// Saves it on a computer, or offers it to share on a phone.
Future<void> downloadTripPdf(Trip trip) async {
  final name = trip.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
  await Printing.sharePdf(bytes: await tripPdf(trip), filename: '${name.isEmpty ? 'Trip' : name} itinerary.pdf');
}

Future<Uint8List> tripPdf(Trip trip) async {
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
  final doc = pw.Document(title: trip.title);
  final schedule = tripSchedule(trip);
  final notes = trip.notes.trim();
  final links = [for (final l in trip.links) l.url, ...findLinks(notes).where((l) => !trip.links.any((x) => x.url == l))];
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.letter,
    margin: const pw.EdgeInsets.fromLTRB(44, 44, 44, 40),
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
    footer: (c) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: _gray)),
    ),
    build: (_) => [
      pw.Text(_plain(trip.title), style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 3),
      pw.Text(_subtitle(trip), style: const pw.TextStyle(fontSize: 10.5, color: _gray)),
      if (notes.isNotEmpty || links.isNotEmpty) ...[
        pw.SizedBox(height: 12),
        if (notes.isNotEmpty) pw.Text(_plain(notes), style: const pw.TextStyle(fontSize: 10, lineSpacing: 2)),
        for (final l in links) _link(l),
      ],
      for (final day in schedule)
        ...() {
          final rows = _rows(day);
          return [
            pw.SizedBox(height: 20),
            // A day's heading never gets left at the bottom of a page, away from its first entry.
            pw.Inseparable(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
                  pw.Text(DateFormat('EEEE, MMMM d').format(day.day), style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(width: 8),
                  pw.Text('Day ${day.number}', style: const pw.TextStyle(fontSize: 9.5, color: _gray)),
                ]),
                pw.SizedBox(height: 9),
                if (rows.isNotEmpty) rows.first,
              ]),
            ),
            ...rows.skip(1),
          ];
        }(),
      if (schedule.isEmpty) ...[pw.SizedBox(height: 20), pw.Text('Nothing planned yet.')],
    ],
  ));
  return doc.save();
}

String _subtitle(Trip trip) => [
      if (trip.firstDay == trip.lastDay)
        DateFormat('MMM d, y').format(trip.firstDay)
      else
        '${DateFormat('MMM d').format(trip.firstDay)} – ${DateFormat('MMM d, y').format(trip.lastDay)}',
      if (trip.destination.isNotEmpty) trip.destination,
    ].join(' · ');

pw.Widget _link(String link) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 1),
      child: pw.UrlLink(
        destination: linkUri(link).toString(),
        child: pw.Text(link, style: const pw.TextStyle(fontSize: 9, decoration: pw.TextDecoration.underline)),
      ),
    );

List<pw.Widget> _rows(ScheduleDay day) {
  final first = day.rows.indexWhere((r) => r.dot), last = day.rows.lastIndexWhere((r) => r.dot);
  return [
    for (final (m, r) in day.rows.indexed)
      _line(
        up: m > first && m <= last,
        down: m >= first && m < last,
        marker: switch (r) {
          ScheduleEvent(:final entry) => _iconDot(entry.item.kind),
          ScheduleStop() => _stopDot(),
          ScheduleZoneChange() => null,
        },
        entry: r is ScheduleEvent ? r.entry : null,
        body: switch (r) {
          ScheduleEvent(:final entry) => _event(entry),
          ScheduleStop(:final stop, :final last) => _stop(stop, last),
          ScheduleZoneChange() => pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 10),
              child: pw.Text(r.text, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            ),
        },
      ),
  ];
}

/// One row: its time, its place on the line, and what it is.
pw.Widget _line({required bool up, required bool down, pw.Widget? marker, TripEntry? entry, required pw.Widget body}) {
  final x = _timeWidth + _rail / 2;
  return pw.Stack(overflow: pw.Overflow.visible, children: [
    if (up) pw.Positioned(left: x, top: 0, child: pw.Container(width: 0.7, height: _dotY, color: PdfColors.black)),
    if (down) pw.Positioned(left: x, top: _dotY, bottom: 0, child: pw.Container(width: 0.7, color: PdfColors.black)),
    if (marker != null) pw.Positioned(left: x - 8, top: _dotY - 8, child: marker),
    pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.SizedBox(
        width: _timeWidth - 4,
        child: entry == null
            ? pw.SizedBox()
            : pw.Padding(
                padding: const pw.EdgeInsets.only(top: 2),
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
                  pw.Text(_plain(DateFormat.jm().format(inZone(entry.moment, entry.zone))),
                      style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                  pw.Text(zoneLabel(entry.moment, entry.zone), style: const pw.TextStyle(fontSize: 8, color: _gray)),
                ]),
              ),
      ),
      pw.SizedBox(width: _rail + 8),
      pw.Expanded(child: body),
    ]),
  ]);
}

/// Each type's icon, as a shape: the PDF has no color to tell them apart.
const _iconPaths = {
  TripItemKind.flight: 'M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z',
  TripItemKind.commute:
      'M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.66 0-1.21.42-1.42 1.01L3 12v8c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-1h12v1c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-8l-2.08-5.99zM6.5 16c-.83 0-1.5-.67-1.5-1.5S5.67 13 6.5 13s1.5.67 1.5 1.5S7.33 16 6.5 16zm11 0c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zM5 11l1.5-4.5h11L19 11H5z',
  TripItemKind.travel:
      'M12 2c-4 0-8 .5-8 4v9.5C4 17.43 5.57 19 7.5 19L6 20.5v.5h2.23l2-2H14l2 2h2v-.5L16.5 19c1.93 0 3.5-1.57 3.5-3.5V6c0-3.5-3.58-4-8-4zM7.5 17c-.83 0-1.5-.67-1.5-1.5S6.67 14 7.5 14s1.5.67 1.5 1.5S8.33 17 7.5 17zm3.5-7H6V6h5v4zm2 0V6h5v4h-5zm3.5 7c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5z',
  TripItemKind.stay: 'M7 13c1.66 0 3-1.34 3-3S8.66 7 7 7s-3 1.34-3 3 1.34 3 3 3zm12-6h-8v7H3V5H1v15h2v-3h18v3h2v-9c0-2.21-1.79-4-4-4z',
  // A key, for a car that isn't yours.
  TripItemKind.rental:
      'M12.65 10C11.83 7.67 9.61 6 7 6c-3.31 0-6 2.69-6 6s2.69 6 6 6c2.61 0 4.83-1.67 5.65-4H17v4h4v-4h2v-4H12.65zM7 14c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z',
  TripItemKind.food:
      'M11 9H9V2H7v7H5V2H3v7c0 2.12 1.66 3.84 3.75 3.97V22h2.5v-9.03C11.34 12.84 13 11.12 13 9V2h-2v7zm5-3v8h2.5v8H21V2c-2.76 0-5 2.24-5 4z',
  TripItemKind.activity:
      'M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z',
};

pw.Widget _iconDot(TripItemKind kind) => pw.Container(
      width: 16,
      height: 16,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(color: PdfColors.white, shape: pw.BoxShape.circle, border: pw.Border.all(color: PdfColors.black, width: 0.7)),
      child: pw.SvgImage(
          svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#000" d="${_iconPaths[kind]}"/></svg>',
          width: 10,
          height: 10),
    );

pw.Widget _stopDot() => pw.Padding(
      padding: const pw.EdgeInsets.all(5),
      child: pw.Container(
        width: 6,
        height: 6,
        decoration: pw.BoxDecoration(color: PdfColors.white, shape: pw.BoxShape.circle, border: pw.Border.all(color: PdfColors.black, width: 0.7)),
      ),
    );

const _detail = pw.TextStyle(fontSize: 9, color: _gray, lineSpacing: 1.5);

pw.Widget _event(TripEntry e) {
  final i = e.item, f = i.flight ?? const {};
  final isFlight = i.kind == TripItemKind.flight, full = e.part == TripPart.whole || e.part == TripPart.begins;
  final dep = i.departure, arr = i.arrival;
  final c = i.commute ?? const {};
  final lines = <String>[
    _plain(e.when),
    if (e.fullPlaces.isNotEmpty) _plain(e.fullPlaces.join(' to ')),
    if (e.duration != null) e.duration!,
    if (isFlight) ...[
      [if ('${f['airline'] ?? ''}'.isNotEmpty) '${f['airline']}', if ('${f['aircraft'] ?? ''}'.isNotEmpty) '${f['aircraft']}'].join(' · '),
      if (dep.name.isNotEmpty || arr.name.isNotEmpty) [dep.name, arr.name].where((n) => n.isNotEmpty).join(' to '),
      [
        if (dep.terminal.isNotEmpty) 'Terminal ${dep.terminal}',
        if (dep.gate.isNotEmpty) 'Gate ${dep.gate}',
        if (arr.baggageBelt.isNotEmpty) 'Bags at belt ${arr.baggageBelt}'
      ].join(' · '),
    ],
    if (i.kind == TripItemKind.commute && e.part == TripPart.whole) ...[
      if ('${c['route'] ?? ''}'.isNotEmpty) 'Via ${c['route']}',
      if (c['meters'] is num && (c['meters'] as num) > 0) '${((c['meters'] as num) / 1609.34).toStringAsFixed(0)} miles',
    ],
    if (full && '${c['car'] ?? ''}'.isNotEmpty) 'Car: ${c['car']}',
    if (full && i.confirmation.isNotEmpty) 'Confirmation: ${i.confirmation}',
  ].where((l) => l.isNotEmpty).toList();
  return pw.Padding(
    padding: pw.EdgeInsets.only(bottom: e.part == TripPart.whole && i.stops.isNotEmpty ? 6 : 13),
    child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text(_plain(e.title), style: pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold)),
      for (final l in lines) pw.Text(l, style: _detail),
      if (full && i.notes.trim().isNotEmpty) ...[
        pw.SizedBox(height: 2),
        pw.Text(_plain(i.notes.trim()), style: const pw.TextStyle(fontSize: 9, lineSpacing: 1.5)),
      ],
      if (full)
        for (final l in findLinks(i.notes).toSet()) _link(l),
    ]),
  );
}

pw.Widget _stop(DriveStop s, bool last) => pw.Padding(
      padding: pw.EdgeInsets.only(bottom: last ? 13 : 5),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('${_plain(s.name)}  ·  ${tripMinutes(s.minutes)} stop', style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
        if (s.place.isNotEmpty && s.place != s.name) pw.Text(_plain(s.place), style: _detail),
      ]),
    );
