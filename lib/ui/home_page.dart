import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/settings.dart';
import '../core/services/core_controller.dart';
import '../l10n/strings.dart';
import '../platform/windows/elevation.dart';
import '../platform/windows/win32.dart' as win32;
import '../state/app_state.dart';
import 'config_list.dart';
import 'flags.dart';
import 'theme.dart';
import 'widgets.dart';

/// Connects, or explains why it cannot and offers the way out.
Future<void> connectWithPrompts(BuildContext context) async {
  final state = context.read<AppState>();
  try {
    await state.toggle();
  } on ElevationRequired {
    if (!context.mounted) return;
    final s = S.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.admin_panel_settings_outlined),
        title: Text(s.needAdminTitle),
        content: SizedBox(width: 420, child: Text(s.needAdminBody)),
        actionsOverflowButtonSpacing: 4,
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, 'proxy'),
              child: Text(s.useProxyInstead)),
          FilledButton(
              onPressed: () => Navigator.pop(context, 'admin'),
              child: Text(s.restartAsAdmin)),
        ],
      ),
    );
    if (choice == 'proxy') {
      state.updateSettings((st) => st.mode = ConnectionMode.systemProxy);
      await state.connect();
    } else if (choice == 'admin') {
      // The elevated copy takes over; `--elevated` lets it past the
      // single-instance guard while this one is still closing. Settings are
      // flushed first so it starts with what is on screen.
      await state.store.flush();
      if (win32.shellExecute(Platform.resolvedExecutable,
          verb: 'runas', args: elevatedArguments(const [], connect: true))) {
        exit(0);
      }
    }
  }
}

/// The main screen: connect, see the traffic, pick a configuration.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return LayoutBuilder(builder: (context, c) {
      final panel = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConnectPanel(state: state),
          if (state.error != null) _ErrorCard(state: state),
        ],
      );

      // Two columns when there is room: the connection on the left stays
      // put while the list on the right scrolls.
      if (c.maxWidth >= 800) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 330, child: SingleChildScrollView(child: panel)),
              const SizedBox(width: 14),
              const Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(bottom: 20),
                  child: ConfigList(),
                ),
              ),
            ],
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [panel, const SizedBox(height: 12), const ConfigList()],
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// The power button with the live speed next to it, status and totals.
class ConnectPanel extends StatelessWidget {
  const ConnectPanel({super.key, required this.state, this.dense = false});

  final AppState state;

  /// The compact-window variant: no card, tighter spacing.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final colors = StatusColors.of(context);
    final profile = state.selectedProfile;
    final hasServer = profile != null;
    final label = profile == null ? null : ServerLabel.of(profile.name);
    final country = label?.country;

    final (title, titleColor) = switch (state.status) {
      CoreStatus.running => (s.statusOn, colors.connected),
      CoreStatus.starting => (s.statusConnecting, colors.connecting),
      CoreStatus.stopping => (s.statusStopping, colors.connecting),
      CoreStatus.stopped => (s.statusOff, theme.colorScheme.onSurface),
    };

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            PowerButton(state: state, size: dense ? 92 : 104, enabled: hasServer),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [...previous, ?current],
                    ),
                    child: Text(
                      title,
                      key: ValueKey(title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: 20, fontWeight: FontWeight.w700, color: titleColor),
                    ),
                  ),
                  if (state.isConnected && state.connectedSince != null)
                    _Elapsed(since: state.connectedSince!)
                  else if (state.canCancel)
                    // Setting up a connection can take a while; nobody
                    // should have to sit it out.
                    TextButton(
                      onPressed: state.disconnect,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        alignment: Alignment.centerLeft,
                        minimumSize: const Size(0, 26),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        foregroundColor: colors.connecting,
                      ),
                      child: Text(s.cancelConnecting),
                    )
                  else
                    const SizedBox(height: 2),
                  const SizedBox(height: 8),
                  _Speed(
                      icon: Icons.south_rounded,
                      value: formatSpeed(state.speed.down),
                      color: colors.connected,
                      active: state.isConnected),
                  const SizedBox(height: 2),
                  _Speed(
                      icon: Icons.north_rounded,
                      value: formatSpeed(state.speed.up),
                      color: theme.colorScheme.primary,
                      active: state.isConnected),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (country != null)
              FlagChip(country, height: 12)
            else
              Icon(Icons.dns_rounded, size: 15, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label?.title ?? s.noServerHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500)),
            ),
            if (profile != null) LatencyBadge(profile.latencyMs),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(Icons.data_usage_rounded, size: 15, color: muted),
            const SizedBox(width: 6),
            // Arrows are icons, not characters: not every system font has them.
            Expanded(
              child: DefaultTextStyle.merge(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                child: Row(
                  children: [
                    Flexible(child: Text('${s.sessionTraffic}:')),
                    const SizedBox(width: 6),
                    Icon(Icons.south_rounded, size: 12, color: muted),
                    Text(' ${formatBytes(state.totalDown)}'),
                    const SizedBox(width: 8),
                    Icon(Icons.north_rounded, size: 12, color: muted),
                    Text(' ${formatBytes(state.totalUp)}'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );

    if (dense) return content;
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: content));
  }
}

class _Speed extends StatelessWidget {
  const _Speed({
    required this.icon,
    required this.value,
    required this.color,
    required this.active,
  });

  final IconData icon;
  final String value;
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: active ? color : theme.colorScheme.outline),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: active ? null : theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// The connect button: a glowing ring that pulses while connected and
/// spins while the connection is being set up.
class PowerButton extends StatefulWidget {
  const PowerButton({
    super.key,
    required this.state,
    this.size = 104,
    this.enabled = true,
  });

  final AppState state;
  final double size;
  final bool enabled;

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton> with SingleTickerProviderStateMixin {
  late final _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  bool get _animated =>
      widget.state.settings.animations && !MediaQuery.disableAnimationsOf(context);

  void _sync() {
    final lively = _animated && widget.state.status != CoreStatus.stopped;
    if (lively) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PowerButton old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final colors = StatusColors.of(context);
    final s = S.of(context);
    final status = state.status;
    final on = status == CoreStatus.running;
    final busy = state.isBusy;
    // While connecting, the button calls the attempt off.
    final cancels = state.canCancel;
    final color = switch (status) {
      CoreStatus.running => colors.connected,
      CoreStatus.starting || CoreStatus.stopping => colors.connecting,
      CoreStatus.stopped => widget.enabled ? scheme.primary : scheme.outline,
    };
    final size = widget.size;
    final core = size * 0.74;

    return Semantics(
      button: true,
      label: cancels ? s.tapToCancel : (on ? s.tapToDisconnect : s.tapToConnect),
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => CustomPaint(
                size: Size.square(size),
                painter: _RingPainter(
                  color: color,
                  phase: _pulse.value,
                  mode: busy ? _RingMode.spinning : (on ? _RingMode.pulsing : _RingMode.idle),
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOut,
              width: core,
              height: core,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: on
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [color, Color.lerp(color, brandCyan, 0.55)!],
                      )
                    : null,
                color: on ? null : scheme.surfaceContainerHigh,
                border: Border.all(color: color.withValues(alpha: on ? 0 : 0.9), width: 2),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: on ? 0.55 : 0.22),
                    blurRadius: on ? 26 : 14,
                    spreadRadius: on ? 1 : 0,
                  ),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  autofocus: state.isTv,
                  customBorder: const CircleBorder(),
                  onTap: busy && !cancels ? null : () => connectWithPrompts(context),
                  child: Center(
                    child: Icon(
                        cancels ? Icons.close_rounded : Icons.power_settings_new_rounded,
                        size: core * 0.46,
                        color: on ? const Color(0xFF03130B) : color),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _RingMode { idle, pulsing, spinning }

class _RingPainter extends CustomPainter {
  _RingPainter({required this.color, required this.phase, required this.mode});

  final Color color;
  final double phase;
  final _RingMode mode;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width / 2;
    switch (mode) {
      case _RingMode.idle:
        canvas.drawCircle(
            centre,
            radius * 0.88,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = color.withValues(alpha: 0.16));
      case _RingMode.pulsing:
        // Two rings expanding out of phase, fading as they grow.
        for (final offset in [0.0, 0.5]) {
          final p = (phase + offset) % 1;
          canvas.drawCircle(
              centre,
              radius * (0.76 + 0.24 * p),
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2
                ..color = color.withValues(alpha: 0.42 * (1 - p)));
        }
      case _RingMode.spinning:
        final rect = Rect.fromCircle(center: centre, radius: radius * 0.9);
        canvas.drawArc(
            rect,
            phase * 2 * math.pi * 2,
            math.pi * 1.25,
            false,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..strokeCap = StrokeCap.round
              ..shader = SweepGradient(
                transform: GradientRotation(phase * 2 * math.pi * 2),
                colors: [color.withValues(alpha: 0), color],
              ).createShader(rect));
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.phase != phase || old.mode != mode || old.color != color;
}

class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.since});
  final DateTime since;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      formatDuration(DateTime.now().difference(widget.since)),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final raw = state.error!;
    final noServer = raw == 'no-server';
    const timeoutPrefix = 'start-timeout:';
    final detail = noServer
        ? s.noServerHint
        : (raw.startsWith(timeoutPrefix)
            ? s.startTimeout(int.tryParse(raw.substring(timeoutPrefix.length)) ?? 60)
            : raw);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Card(
        color: scheme.errorContainer.withValues(alpha: 0.9),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(noServer ? s.noServer : s.errorTitle,
                        style: TextStyle(
                            color: scheme.onErrorContainer, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    SelectableText(detail,
                        style: TextStyle(color: scheme.onErrorContainer, fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The system proxy / VPN switch: a pill with a sliding thumb.
class ModeSlider extends StatelessWidget {
  const ModeSlider({super.key, required this.state, this.showLabel = true});

  final AppState state;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tun = state.settings.mode == ConnectionMode.tun;

    void set(ConnectionMode mode) => state.updateSettings((st) => st.mode = mode);

    Widget half(IconData icon, bool selected) => Expanded(
          child: Center(
            child: Icon(icon,
                size: 16,
                color: selected ? scheme.onPrimary : scheme.onSurfaceVariant),
          ),
        );

    return Tooltip(
      message: tun ? s.modeTunHint : s.modeProxyHint,
      waitDuration: const Duration(milliseconds: 400),
      // A paragraph, not a label: keep it a readable column, above the
      // switch so it does not cover the buttons underneath.
      constraints: const BoxConstraints(maxWidth: 340),
      preferBelow: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            toggled: tun,
            label: s.mode,
            child: Material(
              color: scheme.surfaceContainerHighest,
              shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => set(tun ? ConnectionMode.systemProxy : ConnectionMode.tun),
                child: SizedBox(
                  width: 64,
                  height: 30,
                  child: Stack(
                    children: [
                      AnimatedAlign(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: tun ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          width: 32,
                          height: 30,
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            gradient: const LinearGradient(colors: [brandBlue, brandCyan]),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          half(Icons.public_rounded, !tun),
                          half(Icons.shield_rounded, tun),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (showLabel) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tun ? s.modeTunShort : s.modeProxyShort,
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                // VPN mode needs administrator rights; show that they are there.
                if (state.elevated) ...[
                  const SizedBox(width: 3),
                  Icon(Icons.admin_panel_settings_rounded,
                      size: 13, color: scheme.primary),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
