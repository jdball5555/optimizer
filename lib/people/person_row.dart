import 'package:flutter/material.dart';

import '../theme.dart';

/// The heading over the people on any entry.
class PeopleHeading extends StatelessWidget {
  const PeopleHeading({super.key, this.action});

  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          const Icon(Icons.group_outlined, size: 18, color: AppColors.secondaryText),
          const SizedBox(width: 8),
          const Expanded(child: Text('People', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
          if (action != null) action!,
        ]),
      );
}

/// One person on an entry, the same everywhere: who, and where they stand.
class PersonRow extends StatelessWidget {
  const PersonRow({super.key, required this.name, this.detail, this.trailing});

  final String name;
  final String? detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: AppColors.surfaceHigh,
            child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              if (detail != null && detail!.isNotEmpty)
                Text(detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.secondaryText, fontSize: 12)),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
      );
}
