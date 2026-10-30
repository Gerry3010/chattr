// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/calls/call_controller.dart';
import '../../features/calls/call_minimized.dart';
import '../../features/calls/call_system_bridge.dart';
import '../../features/calls/call_rules.dart';
import '../../features/profiles/profile_helpers.dart';
import '../../features/profiles/widgets/user_avatar.dart';
import 'call_waveform.dart';

/// Puts the call screen above EVERY route while a call exists.
///
/// An overlay rather than a pushed route, for the same reason as the PiP host:
/// an incoming call has to appear wherever the user happens to be, and a call
/// must survive them navigating — neither is something a route on the stack
/// does by itself. Sits inside the lock gate, so a locked app never shows who
/// is calling.
/// The full call screen is up (ringing, connecting, in the call, the end
/// screen), not the minimized bar.
final _callScreenShowingProvider = Provider<bool>((ref) {
  final phase = ref.watch(callControllerProvider.select((s) => s.phase));
  return phase != CallPhase.idle && !ref.watch(callMinimizedProvider);
});

class CallOverlayHost extends ConsumerWidget {
  const CallOverlayHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Stage 3: accept/decline from the system call UI, iOS VoIP token.
    ref.watch(callSystemBridgeProvider);
    // The call screen lies over the app, and a text field underneath kept its
    // focus: the keyboard stayed up over the call (Gerry, 2026-10-24, after
    // accepting). Let go of it whenever the full screen appears.
    ref.listen<bool>(_callScreenShowingProvider, (prev, next) {
      if (next && prev != true) FocusManager.instance.primaryFocus?.unfocus();
    });
    final phase = ref.watch(callControllerProvider.select((s) => s.phase));
    final minimized =
        ref.watch(callMinimizedProvider) && phase != CallPhase.idle;
    final barHeight = MediaQuery.paddingOf(context).top + CallBar.height;
    return Stack(
      children: [
        // The app always sits in this same slot — swapping the widget around
        // it would rebuild the Navigator and lose every open route.
        Positioned.fill(
          top: minimized ? barHeight : 0,
          child: MediaQuery.removePadding(
            context: context,
            removeTop: minimized,
            child: child,
          ),
        ),
        if (minimized)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: barHeight,
            child: const CallBar(),
          )
        else if (phase != CallPhase.idle)
          const Positioned.fill(child: CallScreen()),
      ],
    );
  }
}

/// The minimized call: a bar across the top, like the green one of the
/// system phone. A tap brings the full screen back; hanging up works from
/// here directly, so nobody has to open the call just to end it.
///
/// While it rings the bar takes the theme's accent and pulses, with accept
/// and decline in it: green means "call running, microphone open", and a
/// ringing call must not look like one (Gerry, 2026-10-24). Both buttons go
/// through the same controller calls as the full screen.
class CallBar extends ConsumerStatefulWidget {
  const CallBar({super.key});

  static const double height = 56;

  @override
  ConsumerState<CallBar> createState() => _CallBarState();
}

class _CallBarState extends ConsumerState<CallBar> {
  /// The bar keeps the look of the last live phase through the end screen.
  /// A call declined or given up while it rang used to flash green on its
  /// way out (Gerry, 2026-10-24); the state alone cannot tell, it does not
  /// record which way the call went.
  bool _ringLook = false;

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callControllerProvider);
    final controller = ref.read(callControllerProvider.notifier);
    final peerId = call.peerId;
    final peerName = peerId == null
        ? ''
        : (ref.watch(optionalUsernameProvider(peerId)) ?? '');
    final scheme = Theme.of(context).colorScheme;
    final ringing = call.phase == CallPhase.incoming;
    switch (call.phase) {
      case CallPhase.incoming:
        _ringLook = true;
      case CallPhase.outgoing || CallPhase.connecting || CallPhase.active:
        _ringLook = false;
      case CallPhase.ended || CallPhase.idle:
        break;
    }
    // The theme's own contrast colour on the ringing bar, white on green.
    final onBar = _ringLook
        ? ringingBarColors(scheme).foreground
        : Colors.white;
    final onBarMuted = onBar.withValues(alpha: 0.72);

    return _BarBackground(
      ringLook: _ringLook,
      pulse: ringing,
      child: InkWell(
        key: const ValueKey('call_bar'),
        onTap: ref.read(callMinimizedProvider.notifier).expand,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: CallBar.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  if (peerId != null) UserAvatar(userId: peerId, radius: 16),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Semantics(
                      button: true,
                      label: 'call.expand'.tr(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            peerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: onBar,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          _StatusLine(call: call, color: onBarMuted),
                        ],
                      ),
                    ),
                  ),
                  if (call.muted && !ringing)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.mic_off, color: onBar, size: 20),
                    ),
                  if (ringing) ...[
                    _LabeledIconButton(
                      key: const ValueKey('call_bar_decline'),
                      label: 'call.decline'.tr(),
                      onPressed: controller.hangUp,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                      ),
                      icon: const Icon(Icons.call_end, color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                    _LabeledIconButton(
                      key: const ValueKey('call_bar_accept'),
                      label: 'call.accept'.tr(),
                      onPressed: controller.accept,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                      ),
                      icon: const Icon(Icons.call, color: Colors.white),
                    ),
                  ] else if (canMinimizeCall(call.phase))
                    _LabeledIconButton(
                      key: const ValueKey('call_bar_hang_up'),
                      label: 'call.hang_up'.tr(),
                      onPressed: ref
                          .read(callControllerProvider.notifier)
                          .hangUp,
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.error,
                      ),
                      icon: Icon(Icons.call_end, color: scheme.onError),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The ringing bar's colours: the theme's accent, so the bar belongs to the
/// theme in use (Gerry, 2026-10-24: in Forest that is the ochre). Where the
/// accent itself is green (Meadow, Matrix) it would read as "call running",
/// the one thing a ringing call must not look like; then the theme's third
/// colour, and amber where that is green as well.
@visibleForTesting
({Color background, Color foreground}) ringingBarColors(ColorScheme scheme) {
  bool greenish(Color c) {
    final hsv = HSVColor.fromColor(c);
    return hsv.saturation > 0.25 && hsv.hue >= 75 && hsv.hue <= 165;
  }

  if (!greenish(scheme.primary)) {
    return (background: scheme.primary, foreground: scheme.onPrimary);
  }
  if (!greenish(scheme.tertiary)) {
    return (background: scheme.tertiary, foreground: scheme.onTertiary);
  }
  // Matrix is phosphor green throughout: amber, the bar's first colour.
  return (background: const Color(0xFFFFB300), foreground: Colors.black87);
}

/// The other end of the ringing bar's pulse: a step away from the text
/// colour (darker under light text, lighter under dark text).
@visibleForTesting
Color pulseFarEnd(({Color background, Color foreground}) colors) {
  final textIsLight = colors.foreground.computeLuminance() > 0.5;
  return Color.lerp(
    colors.background,
    textIsLight ? Colors.black : Colors.white,
    0.18,
  )!;
}

/// The bar's ground: green for a call under way, the theme's accent while it
/// rings, pulsing gently unless the system asks for reduced motion.
class _BarBackground extends StatefulWidget {
  const _BarBackground({
    required this.ringLook,
    required this.pulse,
    required this.child,
  });

  /// The accent instead of the call green.
  final bool ringLook;

  /// Only while it actually rings; the end screen holds still.
  final bool pulse;
  final Widget child;

  @override
  State<_BarBackground> createState() => _BarBackgroundState();
}

class _BarBackgroundState extends State<_BarBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final pulse = widget.ringLook && widget.pulse && !reduceMotion;
    if (pulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!pulse && _pulse.isAnimating) {
      _pulse.stop();
    }
    if (!widget.ringLook) {
      return Material(color: Colors.green.shade700, child: widget.child);
    }
    final colors = ringingBarColors(Theme.of(context).colorScheme);
    // The pulse moves away from the text colour, so the text never loses
    // contrast at the far end of it.
    final ring = colors.background;
    final ringFar = pulseFarEnd(colors);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Material(
        color: Color.lerp(ring, ringFar, _pulse.value),
        child: child,
      ),
      child: widget.child,
    );
  }
}

class CallScreen extends ConsumerWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callControllerProvider);
    final controller = ref.read(callControllerProvider.notifier);
    final peerId = call.peerId;
    final peerName = peerId == null
        ? ''
        : (ref.watch(optionalUsernameProvider(peerId)) ?? '');
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Column(
            children: [
              Align(
                alignment: AlignmentDirectional.topStart,
                child: canMinimizeCall(call.phase)
                    ? _LabeledIconButton(
                        key: const ValueKey('call_minimize'),
                        label: 'call.minimize'.tr(),
                        onPressed: ref
                            .read(callMinimizedProvider.notifier)
                            .minimize,
                        icon: const Icon(Icons.keyboard_arrow_down),
                      )
                    // Same height either way, so the screen does not jump
                    // when the button comes and goes.
                    : const SizedBox(height: 48),
              ),
              const Spacer(),
              if (peerId != null)
                _Ripples(
                  // Rings while the call is being set up; once audio flows
                  // the waveform below takes over.
                  active:
                      call.phase == CallPhase.outgoing ||
                      call.phase == CallPhase.incoming ||
                      call.phase == CallPhase.connecting,
                  color: scheme.primary,
                  child: UserAvatar(userId: peerId, radius: 56),
                ),
              const SizedBox(height: 20),
              Text(
                peerName,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              _StatusLine(call: call),
              const SizedBox(height: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'call.e2e_hint'.tr(),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              // Only while audio flows; before that there is nothing to show.
              if (call.phase == CallPhase.active)
                const CallWaveform()
              else
                const SizedBox(height: 72),
              const Spacer(),
              _Controls(call: call, controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatefulWidget {
  const _StatusLine({required this.call, this.color});

  final CallState call;
  final Color? color;

  @override
  State<_StatusLine> createState() => _StatusLineState();
}

class _StatusLineState extends State<_StatusLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Only the running timer needs a repaint every second.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.call.phase == CallPhase.active && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final text = switch (call.phase) {
      CallPhase.outgoing => 'call.calling'.tr(),
      CallPhase.incoming => 'call.incoming'.tr(),
      CallPhase.connecting => 'call.connecting'.tr(),
      // A dropped connection being rebuilt (network change) says so, instead
      // of a clock running over silence.
      CallPhase.active =>
        call.reconnecting
            ? 'call.reconnecting'.tr()
            : _elapsed(call.connectedAt),
      CallPhase.ended =>
        'call.ended.${(call.endReason ?? CallEndReason.hangup).name}'.tr(),
      CallPhase.idle => '',
    };
    return Text(
      text,
      style: TextStyle(
        color: widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  String _elapsed(DateTime? since) {
    if (since == null) return '';
    final d = DateTime.now().difference(since);
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = two(d.inMinutes.remainder(60));
    final s = two(d.inSeconds.remainder(60));
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.call, required this.controller});

  final CallState call;
  final CallController controller;

  @override
  Widget build(BuildContext context) {
    switch (call.phase) {
      case CallPhase.incoming:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _RoundButton(
              key: const ValueKey('call_decline'),
              icon: Icons.call_end,
              label: 'call.decline'.tr(),
              background: Colors.red,
              onPressed: controller.hangUp,
            ),
            _RoundButton(
              key: const ValueKey('call_accept'),
              icon: Icons.call,
              label: 'call.accept'.tr(),
              background: Colors.green,
              onPressed: controller.accept,
            ),
          ],
        );
      case CallPhase.ended:
        return _RoundButton(
          key: const ValueKey('call_close'),
          icon: Icons.close,
          label: 'call.close'.tr(),
          background: Theme.of(context).colorScheme.surfaceContainerHighest,
          foreground: Theme.of(context).colorScheme.onSurface,
          onPressed: controller.dismiss,
        );
      case CallPhase.idle:
        return const SizedBox.shrink();
      case CallPhase.outgoing || CallPhase.connecting || CallPhase.active:
        final neutral = Theme.of(context).colorScheme.surfaceContainerHighest;
        final onNeutral = Theme.of(context).colorScheme.onSurface;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _RoundButton(
              key: const ValueKey('call_mute'),
              icon: call.muted ? Icons.mic_off : Icons.mic,
              label: (call.muted ? 'call.unmute' : 'call.mute').tr(),
              background: call.muted ? onNeutral : neutral,
              foreground: call.muted ? neutral : onNeutral,
              onPressed: controller.toggleMute,
            ),
            _RoundButton(
              key: const ValueKey('call_hang_up'),
              icon: Icons.call_end,
              label: 'call.hang_up'.tr(),
              background: Colors.red,
              onPressed: controller.hangUp,
            ),
            _RoundButton(
              key: const ValueKey('call_speaker'),
              icon: Icons.volume_up,
              label: 'call.speaker'.tr(),
              background: call.speakerOn ? onNeutral : neutral,
              foreground: call.speakerOn ? neutral : onNeutral,
              onPressed: controller.toggleSpeaker,
            ),
          ],
        );
    }
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.background,
    required this.onPressed,
    this.foreground = Colors.white,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          child: Material(
            color: background,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: SizedBox(
                width: 68,
                height: 68,
                child: Icon(icon, color: foreground, size: 30),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ExcludeSemantics(
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}

/// Rings that pulse out from the avatar while a call is being set up — the
/// screen otherwise sits still until the other side picks up, and stillness
/// reads as "stuck". Respects the system's reduce-motion setting.
class _Ripples extends StatefulWidget {
  const _Ripples({
    required this.active,
    required this.color,
    required this.child,
  });

  final bool active;
  final Color color;
  final Widget child;

  @override
  State<_Ripples> createState() => _RipplesState();
}

class _RipplesState extends State<_Ripples>
    with SingleTickerProviderStateMixin {
  static const double _spread = 44;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  void _sync(bool reduceMotion) {
    final run = widget.active && !reduceMotion;
    if (run && !_anim.isAnimating) {
      _anim.repeat();
    } else if (!run && _anim.isAnimating) {
      _anim.stop();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    return SizedBox(
      width: 112 + 2 * _spread,
      height: 112 + 2 * _spread,
      child: CustomPaint(
        painter: widget.active
            ? _RipplePainter(_anim, widget.color, _spread)
            : null,
        child: Center(child: widget.child),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter(this.progress, this.color, this.spread)
    : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final double spread;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = size.shortestSide / 2 - spread;
    const rings = 3;
    for (var i = 0; i < rings; i++) {
      final t = (progress.value + i / rings) % 1.0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: (1 - t) * 0.45);
      canvas.drawCircle(center, base + t * spread, paint);
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.color != color || old.progress != progress;
}

/// An [IconButton] with a screen-reader label instead of a tooltip. The call
/// UI sits above the Navigator (MaterialApp.builder), where there is no
/// Overlay, and a Tooltip needs one even to build: debug builds failed into
/// the error screen as soon as a call appeared (Mac-Claude, 2026-10-24), and
/// release builds would fail on a long press. Same fix as the PiP window.
class _LabeledIconButton extends StatelessWidget {
  const _LabeledIconButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.icon,
    this.style,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget icon;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      label: label,
      child: IconButton(onPressed: onPressed, style: style, icon: icon),
    ),
  );
}
