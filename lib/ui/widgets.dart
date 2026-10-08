import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/models/settings.dart';
import '../core/services/app_catalog.dart';
import '../l10n/strings.dart';
import 'theme.dart';

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : (value >= 10 ? 1 : 2);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatSpeed(int bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

String formatDuration(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours;
  return '${h > 0 ? '${two(h)}:' : ''}${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

String formatDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year}';
}

String formatDateTime(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${formatDate(d)} ${two(d.hour)}:${two(d.minute)}';
}

/// Constrains page content to a readable width on wide windows.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.maxWidth = 760});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
  }
}

/// A titled card grouping related settings.
class Section extends StatelessWidget {
  const Section({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(subtitle!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
            ...children,
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// Icon of an application: the real one when it can be loaded.
class AppIconView extends StatelessWidget {
  const AppIconView({super.key, this.processPath, this.packageName, this.size = 32});

  final String? processPath;
  final String? packageName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(Icons.apps_rounded,
        size: size * 0.8, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<ui.Image?>(
        future: AppCatalog.icon(processPath: processPath, packageName: packageName),
        builder: (context, snap) {
          final image = snap.data;
          if (image == null) return Center(child: fallback);
          return RawImage(image: image, filterQuality: FilterQuality.medium);
        },
      ),
    );
  }
}

/// Shows a measured delay, colour-graded.
class LatencyBadge extends StatelessWidget {
  const LatencyBadge(this.ms, {super.key, this.testing = false});

  final int? ms;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (ms == null) {
      if (!testing) return const SizedBox.shrink();
      return const SizedBox.square(
          dimension: 14, child: CircularProgressIndicator(strokeWidth: 2));
    }
    final failed = ms! < 0;
    final color = failed
        ? scheme.error
        : (ms! < 300 ? colors.good : (ms! < 800 ? colors.fair : colors.poor));
    return Text(
      failed ? S.of(context).latencyFailed : '$ms ms',
      style: TextStyle(
        color: color,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Three-way choice of what happens to matching traffic.
class ActionSelector extends StatelessWidget {
  const ActionSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  final RouteAction value;
  final ValueChanged<RouteAction> onChanged;

  /// Labels only, for narrow screens where icons would force a line break.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    Color selectedColor(RouteAction a) => switch (a) {
          RouteAction.direct => scheme.secondaryContainer,
          RouteAction.proxy => scheme.primaryContainer,
          RouteAction.block => scheme.errorContainer,
        };
    return SegmentedButton<RouteAction>(
      showSelectedIcon: false,
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? selectedColor(value) : null),
      ),
      segments: [
        for (final (action, icon, label) in [
          (RouteAction.direct, Icons.call_split_rounded, s.actionDirect),
          (RouteAction.proxy, Icons.shield_outlined, s.actionVpn),
          (RouteAction.block, Icons.block_rounded, s.actionBlock),
        ])
          ButtonSegment(
            value: action,
            icon: compact ? null : Icon(icon, size: 16),
            label: Text(label, softWrap: false, overflow: TextOverflow.fade),
          ),
      ],
      selected: {value},
      onSelectionChanged: (v) => onChanged(v.first),
    );
  }
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirm(BuildContext context, String title, {String? action}) async {
  final s = S.of(context);
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false), child: Text(s.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(action ?? s.delete)),
          ],
        ),
      ) ??
      false;
}

Future<String?> promptText(BuildContext context,
    {required String title, String initial = '', String? hint, String? label}) {
  final controller = TextEditingController(text: initial);
  final s = S.of(context);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label, helperText: hint, helperMaxLines: 3),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(s.save)),
      ],
    ),
  );
}
