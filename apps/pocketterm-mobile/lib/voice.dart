import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:pocketterm_core/speech.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/e2e_hooks.dart';
import 'package:pocketterm_mobile/motion.dart';

/// Where the voice sheet hears from: the phone's on-device recognizer, or in an E2E build (no microphone in the
/// Simulator) a made-up speaker that says [ScriptedSpeech.words]. Tests put a fake here.
SpeechSource voiceSource = e2eBuild ? ScriptedSpeech() : const NativeSpeech();

/// What the person did with what they said: [send] it as the composer would, or insert it into the composer.
class VoiceResult {
  const VoiceResult(this.text, {required this.send});
  final String text;
  final bool send;
}

/// [existing] and then [spoken], a space between them when [existing] has words.
String appendSpoken(String existing, String spoken) {
  final before = existing.trimRight();
  return before.isEmpty ? spoken : '$before $spoken';
}

/// The composer's microphone. A tap opens the voice sheet, which listens until Stop; a hold opens it at once and
/// listens while held: lifting the finger stops and leaves what was said to check, sliding far up or left first
/// cancels. [existing]: the composer's text then, shown dimmed above what's said.
class VoiceMic extends StatefulWidget {
  const VoiceMic({
    required this.enabled,
    required this.existing,
    required this.onResult,
    this.small = false,
    super.key,
  });
  final bool enabled;
  final String Function() existing;
  final void Function(VoiceResult result) onResult;

  /// Inside the field, beside the send button: smaller and dimmer.
  final bool small;

  @override
  State<VoiceMic> createState() => _VoiceMicState();
}

/// Held this long, a press is a hold rather than a tap.
const _holdAfter = Duration(milliseconds: 300);

/// Slid this far up or left while held, lifting the finger cancels.
const voiceCancelDistance = 100.0;

class _VoiceMicState extends State<VoiceMic> {
  Timer? _holdTimer;
  Offset? _down;
  late int _device;
  VoiceHold? _hold;
  bool _open = false;

  /// A finger is on it and it hasn't opened yet: it grows on a disc, so a hold shows it's taking before the sheet
  /// slides up.
  bool _pressed = false;

  void _press(bool pressed) {
    if (pressed != _pressed && mounted) setState(() => _pressed = pressed);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _hold?.dispose();
    super.dispose();
  }

  void _pointerDown(PointerDownEvent e) {
    if (!widget.enabled || _open || _down != null) return;
    _down = e.position;
    _device = e.device;
    _holdTimer = Timer(_holdAfter, _startHold);
    _press(true);
  }

  void _pointerMove(PointerMoveEvent e) {
    // Moved before it counted as a hold: a scroll or a slip, neither a tap nor a hold.
    if (_hold == null && _down != null && (e.position - _down!).distance > kTouchSlop) {
      _reset();
      _press(false);
    }
  }

  void _pointerCancel(PointerCancelEvent e) {
    // A hold's sheet takes the finger as it opens (see [_startHold]): only a press that hadn't become one ends here.
    if (_hold == null) _reset();
    _press(false);
  }

  void _pointerUp(PointerUpEvent e) {
    if (_hold != null || _down == null) return;
    _reset();
    unawaited(_openSheet(null));
  }

  void _reset() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _down = null;
  }

  void _startHold() {
    final origin = _down;
    if (origin == null || !mounted) return;
    _holdTimer = null;
    final hold = _hold = VoiceHold();
    final ratio = View.of(context).devicePixelRatio;
    // The sheet's route takes the finger from every widget as it's pushed (NavigatorState cancels the pointers it
    // saw go down on each navigation, and a cancelled pointer's moves and lift reach no widget after), so the
    // hold follows the finger's raw touches from the platform instead.
    hold.finger = RawFinger.follow(
      _device,
      onMove: (at) {
        final d = at / ratio - origin;
        hold.away = d.dy < -voiceCancelDistance || d.dx < -voiceCancelDistance;
      },
      onUp: hold.release,
    );
    unawaited(_openSheet(hold));
  }

  Future<void> _openSheet(VoiceHold? hold) async {
    _open = true;
    _press(false);
    final result = await showVoiceSheet(context, existing: widget.existing(), hold: hold);
    _open = false;
    _down = null;
    if (identical(_hold, hold)) _hold = null;
    hold?.dispose();
    if (result != null && mounted) widget.onResult(result);
  }

  @override
  Widget build(BuildContext context) {
    final color = !widget.enabled
        ? C.dim2
        : widget.small
        ? C.dim
        : C.accent;
    return Semantics(
      identifier: widget.small ? 'session-mic-small' : 'session-mic',
      button: true,
      enabled: widget.enabled,
      label: 'Voice prompt',
      onTap: widget.enabled ? () => unawaited(_openSheet(null)) : null,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _pointerDown,
        onPointerMove: _pointerMove,
        onPointerUp: _pointerUp,
        onPointerCancel: _pointerCancel,
        child: SizedBox(
          width: widget.small ? 36 : 48,
          height: 48,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedOpacity(
                opacity: _pressed ? 1 : 0,
                duration: Motion.of(context, Motion.quick),
                curve: Motion.ease,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: C.round(20)),
                  child: SizedBox.square(dimension: widget.small ? 32 : 40),
                ),
              ),
              AnimatedScale(
                scale: _pressed ? 1.15 : 1,
                duration: Motion.of(context, Motion.quick),
                curve: Motion.ease,
                child: Icon(Icons.mic_none_rounded, size: widget.small ? 20 : 24, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A hold on the microphone in progress: whether the finger is still down, and whether it slid away to cancel.
class VoiceHold extends ChangeNotifier {
  RawFinger? finger;
  bool down = true;
  bool _away = false;

  bool get away => _away;
  set away(bool v) {
    if (v == _away || !down) return;
    _away = v;
    notifyListeners();
  }

  void release() {
    if (!down) return;
    down = false;
    finger?.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    finger?.stop();
    super.dispose();
  }
}

/// One finger's touches as the platform reports them, before the framework routes them: they keep coming after
/// a route push cancels the pointer for every widget. [onMove] gets positions in physical pixels.
class RawFinger {
  RawFinger._(this.device, this.onMove, this.onUp);

  /// Follows touch [device] (a [PointerEvent.device]) until it lifts or [stop].
  factory RawFinger.follow(int device, {required void Function(Offset at) onMove, required VoidCallback onUp}) {
    final f = RawFinger._(device, onMove, onUp);
    _fingers.add(f);
    _install();
    return f;
  }

  final int device;
  final void Function(Offset at) onMove;
  final VoidCallback onUp;

  static final _fingers = <RawFinger>[];
  static ui.PointerDataPacketCallback? _framework;

  static void _install() {
    if (_framework != null) return;
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    _framework = dispatcher.onPointerDataPacket;
    dispatcher.onPointerDataPacket = _packet;
  }

  static void _uninstall() {
    final framework = _framework;
    if (framework == null) return;
    WidgetsBinding.instance.platformDispatcher.onPointerDataPacket = framework;
    _framework = null;
  }

  static void _packet(ui.PointerDataPacket packet) {
    for (final d in packet.data) {
      for (final f in List.of(_fingers)) {
        if (f.device != d.device) continue;
        switch (d.change) {
          case ui.PointerChange.move:
            f.onMove(Offset(d.physicalX, d.physicalY));
          case ui.PointerChange.up || ui.PointerChange.cancel:
            f.stop();
            f.onUp();
          case ui.PointerChange.add ||
              ui.PointerChange.remove ||
              ui.PointerChange.hover ||
              ui.PointerChange.down ||
              ui.PointerChange.panZoomStart ||
              ui.PointerChange.panZoomUpdate ||
              ui.PointerChange.panZoomEnd:
        }
      }
    }
    // The framework still gets every touch, as before.
    _framework?.call(packet);
  }

  void stop() {
    _fingers.remove(this);
    if (_fingers.isEmpty) _uninstall();
  }
}

/// Opens the voice sheet: listening at once, and once stopped what was said, editable, to Send, Insert or Cancel.
/// [hold]: opened by a hold, which lifting stops. Null: cancelled, closed or dragged away.
Future<VoiceResult?> showVoiceSheet(BuildContext context, {required String existing, VoiceHold? hold}) {
  final title = ValueNotifier<String>('Listening');
  return showFullscreenModal<VoiceResult>(
    context,
    closeKey: const ValueKey('voice-close'),
    title: ValueListenableBuilder(valueListenable: title, builder: (_, t, _) => Text(t)),
    builder: (context) => VoiceSheet(source: voiceSource, existing: existing, hold: hold, title: title),
  ).whenComplete(title.dispose);
}

enum _Phase { checking, problem, downloading, listening, stopping, review }

/// What the voice sheet shows: the composer's [existing] text dimmed, then what's said, live and large; once
/// stopped, editable in place with Cancel, Insert and Send. Leaving the app, a call or Siri stop it, keeping what
/// was said.
class VoiceSheet extends StatefulWidget {
  const VoiceSheet({required this.source, required this.existing, required this.title, this.hold, super.key});
  final SpeechSource source;
  final String existing;
  final ValueNotifier<String> title;
  final VoiceHold? hold;

  @override
  State<VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<VoiceSheet> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  _Phase _phase = _Phase.checking;
  late SpeechCheck _problem;
  StreamSubscription<SpeechEvent>? _sub;
  String _heard = '';

  /// What was said (and edited) before Keep talking: the new words go after it.
  String _before = '';
  final _level = ValueNotifier<double>(0);
  final _edit = TextEditingController();
  Timer? _stopWait;

  /// Why listening ended early, shown under the text.
  String? _note;

  /// Still held to talk: lifting stops. False after a lift, or for a tap.
  bool _held = false;

  /// The orb breaking into motes on Stop that gather into the buttons: 0 as it starts, 1 when the buttons are in.
  late final AnimationController _fly = AnimationController(vsync: this, value: 1)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && _flock != null) setState(() => _flock = null);
    });

  /// The buttons fade in as the motes land.
  late final Animation<double> _reveal = CurvedAnimation(
    parent: _fly,
    curve: const Interval(.7, 1, curve: Motion.ease),
  );

  /// The motes in flight, null when none are.
  _Flock? _flock;

  /// The orb's state while listening, and what it breaks into on Stop.
  final _orbLink = _OrbLink();

  /// Where the orb and the buttons are on screen now, found by [_Spot].
  final _spots = <_Mark, BuildContext>{};
  final GlobalKey _stack = GlobalKey();

  VoiceHold? get _hold => widget.hold;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _held = _hold?.down ?? false;
    _hold?.addListener(_holdChanged);
    _edit.addListener(() => setState(() {}));
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hold?.removeListener(_holdChanged);
    _stopWait?.cancel();
    // Closed or dragged away while listening: what was heard goes, and the microphone stops at once.
    unawaited(_sub?.cancel());
    _fly.dispose();
    _level.dispose();
    _edit.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Out of sight: the microphone stops, what was said stays to check when the person is back.
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) unawaited(_stop());
  }

  void _holdChanged() {
    final hold = _hold!;
    if (!hold.down && _held) {
      _held = false;
      if (hold.away) {
        unawaited(_sub?.cancel());
        _sub = null;
        Navigator.of(context).maybePop();
        return;
      }
      // Lifted before listening began (a permission prompt took the finger): it goes on until Stop, as for a tap.
      if (_phase == _Phase.listening) unawaited(_stop());
    }
    setState(_retitle);
  }

  void _retitle() {
    widget.title.value = switch (_phase) {
      _Phase.checking ||
      _Phase.listening ||
      _Phase.stopping => _held && _hold!.away ? 'Release to cancel' : 'Listening',
      _Phase.downloading => 'Downloading',
      _Phase.problem || _Phase.review => 'Voice prompt',
    };
  }

  void _go(_Phase phase) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _retitle();
    });
  }

  Future<void> _start() async {
    _orbLink.reset();
    _go(_Phase.checking);
    SpeechCheck check;
    try {
      check = await widget.source.check();
    } on Object {
      check = const SpeechCheck(SpeechStatus.unavailable);
    }
    if (!mounted) return;
    if (!check.ready) {
      _problem = check;
      return _go(_Phase.problem);
    }
    unawaited(HapticFeedback.mediumImpact());
    _sub = widget.source.listen().listen(
      _on,
      onError: (Object e) => _ended(SpeechEnd.error, message: e is PlatformException ? e.message : '$e'),
      onDone: () => _ended(SpeechEnd.stopped),
    );
    _go(_Phase.listening);
  }

  void _on(SpeechEvent e) {
    switch (e) {
      case SpeechHeard(:final text):
        if (_phase == _Phase.listening || _phase == _Phase.stopping) {
          setState(() => _heard = appendSpoken(_before, text));
        }
      case SpeechLevel(:final level):
        _level.value = level;
      case SpeechEnded(:final why, :final message, :final status):
        if (status != null && status != SpeechStatus.ready && _heard.trim().isEmpty) {
          unawaited(_sub?.cancel());
          _sub = null;
          _problem = SpeechCheck(status, fix: status == SpeechStatus.noEnglish ? SpeechFix.speechSettings : null);
          return _go(_Phase.problem);
        }
        _ended(why, message: message);
    }
  }

  Future<void> _stop() async {
    if (_phase != _Phase.listening) return;
    _go(_Phase.stopping);
    // The recognizer settles the last words and says so; one that doesn't answer still leaves what it heard.
    _stopWait = Timer(const Duration(seconds: 3), () => _ended(SpeechEnd.stopped));
    try {
      await widget.source.stop();
    } on Object catch (e) {
      _ended(SpeechEnd.error, message: e is PlatformException ? e.message : '$e');
    }
  }

  void _ended(SpeechEnd why, {String? message}) {
    if (!mounted || (_phase != _Phase.listening && _phase != _Phase.stopping)) return;
    _stopWait?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
    _level.value = 0;
    _scatter();
    unawaited(HapticFeedback.lightImpact());
    _held = false;
    _note = switch (why) {
      SpeechEnd.stopped => null,
      SpeechEnd.interrupted => 'Stopped: something else took the microphone.',
      SpeechEnd.error => message == null || message.isEmpty ? 'Listening stopped.' : 'Listening stopped: $message',
    };
    _edit.text = _heard.trim();
    _go(_Phase.review);
  }

  /// [mark]'s place in the sheet, as drawn now (mid-fade it may be a little smaller). Null when it isn't shown.
  Rect? _rectOf(_Mark mark) {
    final box = _spots[mark]?.findRenderObject();
    final stack = _stack.currentContext?.findRenderObject();
    if (box is! RenderBox || stack is! RenderBox || !box.attached || !box.hasSize) return null;
    return MatrixUtils.transformRect(box.getTransformTo(stack), Offset.zero & box.size);
  }

  /// Breaks the orb into motes that fly to the buttons coming in its place, once they're laid out. With reduced
  /// motion the buttons only cross-fade in.
  void _scatter() {
    _fly.stop();
    final orb = _rectOf(_Mark.orb);
    if (orb == null || Motion.reduced(context)) {
      _flock = null;
      _fly.value = 1;
      return;
    }
    // The orb's mesh fades as its specks, where they are now, set off.
    final starts = [for (final (at, color) in _orbLink.sample(_Flock.count)) (at + orb.topLeft, color)];
    _orbLink.gone = true;
    _fly.value = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _phase != _Phase.review) return;
      final targets = [for (final m in _Mark.buttons) _rectOf(m)];
      if (targets.contains(null)) {
        _fly.value = 1;
        return;
      }
      setState(() => _flock = _Flock(orb, starts, targets.cast<Rect>(), C.t.shape));
      _fly
        ..duration = Motion.themed(const Duration(milliseconds: 650))
        ..forward(from: 0);
    });
  }

  /// Listens again, the new words after what's in the editor now.
  void _keepTalking() {
    _before = _edit.text.trim();
    _heard = _before;
    _note = null;
    _fly.value = 1;
    _flock = null;
    unawaited(_start());
  }

  Future<void> _fix(SpeechFix fix) async {
    if (fix != SpeechFix.download) return await widget.source.fix(fix);
    _go(_Phase.downloading);
    try {
      await widget.source.fix(fix);
    } on Object catch (e) {
      if (!mounted) return;
      _problem = const SpeechCheck(SpeechStatus.noEnglish, fix: SpeechFix.download);
      _note = e is PlatformException ? e.message : '$e';
      return _go(_Phase.problem);
    }
    _note = null;
    await _start();
  }

  void _finish({required bool send}) {
    final text = _edit.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(VoiceResult(text, send: send));
  }

  static String problemText(SpeechCheck c) => switch ((c.status, c.fix)) {
    (SpeechStatus.denied, _) =>
      isIos
          ? 'PocketTerm isn’t allowed to use the microphone or speech recognition. Allow them in Settings.'
          : 'PocketTerm isn’t allowed to use the microphone. Allow it in Settings.',
    (SpeechStatus.restricted, _) => 'Speech recognition is turned off on this phone.',
    (SpeechStatus.noEnglish, SpeechFix.download) =>
      'English for speech recognition isn’t on this phone yet. Download it once; what you say stays on the phone.',
    (SpeechStatus.noEnglish, SpeechFix.speechSettings) =>
      'This phone has no English for speech recognition on the device. Add it in the phone’s speech settings.',
    (SpeechStatus.noEnglish, _) =>
      isIos
          ? 'This iPhone can’t recognize English on the device yet. Turn on Dictation in Settings → General → '
                'Keyboard, and English downloads.'
          : 'This phone can’t recognize English on the device.',
    (SpeechStatus.downloading, _) => 'English for speech recognition is downloading. Try again when it’s done.',
    (SpeechStatus.unavailable || SpeechStatus.ready, _) =>
      'This phone can’t recognize speech on the device, so voice prompts are off here.',
  };

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing.trim();
    final flock = _flock;
    // The motes fly over the whole sheet, from the orb to the buttons.
    return Stack(
      key: _stack,
      fit: StackFit.expand,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => SingleChildScrollView(
                  // The newest words stay in view as they come; while they fit, they read from the top.
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: box.maxHeight - 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (existing.isNotEmpty && _phase != _Phase.problem)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              existing,
                              key: const ValueKey('voice-existing'),
                              style: TextStyle(fontSize: 20, height: 1.35, color: C.dim2),
                            ),
                          ),
                        ..._body(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _bottom(),
          ],
        ),
        if (flock != null)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _FlockPainter(flock, _fly, () => [for (final m in _Mark.buttons) _rectOf(m)]),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static const _big = TextStyle(fontSize: 28, height: 1.3, fontWeight: FontWeight.w500);

  List<Widget> _body() => switch (_phase) {
    _Phase.problem => [
      Text(
        problemText(_problem),
        key: const ValueKey('voice-problem'),
        style: TextStyle(fontSize: 18, height: 1.4, color: C.text),
      ),
      if (_note != null) ...[const SizedBox(height: 8), Text(_note!, style: TextStyle(fontSize: 14, color: C.dim))],
    ],
    _Phase.downloading => [
      Text('Downloading English for speech recognition…', style: TextStyle(fontSize: 18, height: 1.4, color: C.dim)),
    ],
    _Phase.checking ||
    _Phase.listening ||
    _Phase.stopping => [_LiveWords(_heard, key: const ValueKey('voice-live'), style: _big)],
    _Phase.review => [
      Semantics(
        identifier: 'voice-edit',
        child: TextField(
          key: const ValueKey('voice-edit'),
          controller: _edit,
          onTapOutside: dismissKeyboard,
          maxLines: null,
          style: _big.copyWith(color: C.text),
          decoration: plainInput.copyWith(
            hintText: 'Nothing heard',
            hintStyle: _big.copyWith(color: C.dim2),
          ),
        ),
      ),
      if (_note != null) ...[
        const SizedBox(height: 12),
        Text(
          _note!,
          key: const ValueKey('voice-note'),
          style: TextStyle(fontSize: 14, color: C.warn),
        ),
      ],
    ],
  };

  /// The controls under what's said: the orb becomes Keep talking, Cancel, Insert and Send by motes flying from one to
  /// the other (and a problem's buttons come and go) by a cross-fade, the room they take changing with it.
  Widget _bottom() => FadeSwap(
    scale: .95,
    alignment: Alignment.bottomCenter,
    resize: true,
    child: KeyedSubtree(
      key: ValueKey(switch (_phase) {
        _Phase.checking || _Phase.listening || _Phase.stopping => _Phase.listening,
        final phase => phase,
      }),
      child: _controls(),
    ),
  );

  Widget _controls() {
    const pad = EdgeInsets.fromLTRB(20, 8, 20, 12);
    switch (_phase) {
      case _Phase.problem:
        final p = _problem;
        final (String? label, VoidCallback? act) = switch ((p.status, p.fix)) {
          (SpeechStatus.downloading, _) => ('Try again', () => unawaited(_start())),
          (_, SpeechFix.download) => ('Download', () => unawaited(_fix(SpeechFix.download))),
          (_, final fix?) => ('Open Settings', () => unawaited(_fix(fix))),
          _ => (null, null),
        };
        return Padding(
          padding: pad,
          child: OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const ValueKey('voice-cancel'),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(C.label('Cancel')),
              ),
              if (label != null)
                FilledButton(key: const ValueKey('voice-fix'), onPressed: act, child: Text(C.label(label))),
            ],
          ),
        );
      case _Phase.downloading:
        return const Padding(
          padding: pad,
          child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
        );
      case _Phase.checking || _Phase.listening || _Phase.stopping:
        final away = _held && _hold!.away;
        final listening = _phase == _Phase.listening;
        final orb = _Spot(
          _Mark.orb,
          _spots,
          child: _Orb(level: _level, away: away, busy: !listening, link: _orbLink),
        );
        return Padding(
          padding: pad,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_held)
                orb
              else
                Semantics(
                  identifier: 'voice-stop',
                  button: true,
                  enabled: listening,
                  label: 'Stop',
                  child: GestureDetector(
                    key: const ValueKey('voice-stop'),
                    behavior: HitTestBehavior.opaque,
                    onTap: listening ? () => unawaited(_stop()) : null,
                    child: orb,
                  ),
                ),
              Text(
                _held ? (away ? 'Release to cancel' : 'Release to stop · Slide away to cancel') : 'Tap to stop',
                key: _held ? const ValueKey('voice-hold-hint') : null,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.4, color: away ? C.error : C.dim),
              ),
            ],
          ),
        );
      case _Phase.review:
        final can = _edit.text.trim().isNotEmpty;
        const tall = Size(0, 48);
        const tight = EdgeInsets.symmetric(horizontal: 12);
        final row = [
          _Spot(
            _Mark.cancel,
            _spots,
            child: Semantics(
              identifier: 'voice-cancel',
              child: TextButton(
                key: const ValueKey('voice-cancel'),
                style: TextButton.styleFrom(foregroundColor: C.dim, minimumSize: tall, padding: tight),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(C.label('Cancel')),
              ),
            ),
          ),
          _Spot(
            _Mark.insert,
            _spots,
            child: Semantics(
              identifier: 'voice-insert',
              child: OutlinedButton(
                key: const ValueKey('voice-insert'),
                style: OutlinedButton.styleFrom(minimumSize: tall, padding: tight),
                onPressed: can ? () => _finish(send: false) : null,
                child: Text(C.label('Insert')),
              ),
            ),
          ),
          _Spot(
            _Mark.send,
            _spots,
            child: Semantics(
              identifier: 'voice-send',
              child: FilledButton(
                key: const ValueKey('voice-send'),
                style: FilledButton.styleFrom(minimumSize: tall, padding: tight),
                onPressed: can ? () => _finish(send: true) : null,
                child: Text(C.label('Send')),
              ),
            ),
          ),
        ];
        return FadeTransition(
          opacity: _reveal,
          child: Padding(
            padding: pad,
            child: LayoutBuilder(
              builder: (context, box) {
                // Side by side while the longest label fits a third of the width; very large text stacks them.
                final style = Theme.of(context).textTheme.labelLarge;
                final scaler = MediaQuery.textScalerOf(context);
                var widest = 0.0;
                for (final text in ['Cancel', 'Insert', 'Send']) {
                  final label = TextPainter(
                    text: TextSpan(text: C.label(text), style: style),
                    textDirection: TextDirection.ltr,
                    textScaler: scaler,
                  )..layout();
                  widest = math.max(widest, label.width);
                  label.dispose();
                }
                final fits = 3 * (widest + tight.horizontal) + 16 <= box.maxWidth;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    _Spot(
                      _Mark.more,
                      _spots,
                      child: Semantics(
                        identifier: 'voice-more',
                        child: TextButton.icon(
                          key: const ValueKey('voice-more'),
                          style: TextButton.styleFrom(
                            backgroundColor: C.accent.withValues(alpha: .12),
                            minimumSize: tall,
                          ),
                          onPressed: _keepTalking,
                          icon: const Icon(Icons.mic_rounded, size: 18),
                          label: Text(C.label('Keep talking')),
                        ),
                      ),
                    ),
                    if (fits) Row(spacing: 8, children: [for (final b in row) Expanded(child: b)]) else ...row,
                  ],
                );
              },
            ),
          ),
        );
    }
  }
}

/// What's being said, large: each new word fades in as the recognizer adds it. A recognizer revises as it goes (after
/// every word on iOS 26): a word it changes swaps in place, so the text keeps up with the voice instead of blinking.
/// One string (no widgets between the words), so it wraps, reads to VoiceOver and is found as the text it is. Until
/// something's heard, "Speak now…".
class _LiveWords extends StatefulWidget {
  const _LiveWords(this.text, {required this.style, super.key});
  final String text;
  final TextStyle style;

  @override
  State<_LiveWords> createState() => _LiveWordsState();
}

class _LiveWordsState extends State<_LiveWords> with SingleTickerProviderStateMixin {
  static final _word = RegExp(r'\S+\s*');

  final _clock = Stopwatch()..start();
  late final Ticker _ticker = createTicker((_) {
    setState(() {});
    if (_born.every((t) => _clock.elapsed - t >= Motion.fast)) _ticker.stop();
  });
  List<String> _words = const [];

  /// When each word showed, on [_clock].
  List<Duration> _born = const [];

  @override
  void initState() {
    super.initState();
    _words = _split(widget.text);
    // Already there when the sheet opens (it never is, but a rebuild of the sheet may make one anew): no fade.
    _born = List.filled(_words.length, -Motion.fast);
  }

  @override
  void didUpdateWidget(_LiveWords old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text) return;
    final words = _split(widget.text);
    final now = _clock.elapsed;
    // A place that had a word keeps its fade (done or under way); only places past the old end fade in.
    _born = [..._born.take(words.length), for (var i = _born.length; i < words.length; i++) now];
    final grew = words.length > _words.length;
    _words = words;
    if (grew && !_ticker.isActive && !Motion.reduced(context)) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  static List<String> _split(String text) => [for (final m in _word.allMatches(text)) m[0]!];

  @override
  Widget build(BuildContext context) {
    if (_words.isEmpty) return Text('Speak now…', style: widget.style.copyWith(color: C.dim2));
    final reduced = Motion.reduced(context);
    final now = _clock.elapsed;
    return Text.rich(
      TextSpan(
        children: [
          for (final (i, w) in _words.indexed)
            TextSpan(
              text: w,
              style: TextStyle(
                color: C.text.withValues(
                  alpha: reduced
                      ? 1
                      : Motion.ease.transform(
                          ((now - _born[i]).inMicroseconds / Motion.fast.inMicroseconds).clamp(0.0, 1.0),
                        ),
                ),
              ),
            ),
        ],
      ),
      style: widget.style,
    );
  }
}

/// What the motes leave from ([orb]) and land on ([buttons], in [_Flock]'s order).
enum _Mark {
  orb,
  more,
  cancel,
  insert,
  send;

  static const List<_Mark> buttons = [more, cancel, insert, send];
}

/// [child], found in [spots] under [mark] while it's shown. Unlike a GlobalKey, the one going in a cross-fade and the
/// one coming may both be there: the newest is found.
class _Spot extends StatefulWidget {
  const _Spot(this.mark, this.spots, {required this.child});
  final _Mark mark;
  final Map<_Mark, BuildContext> spots;
  final Widget child;

  @override
  State<_Spot> createState() => _SpotState();
}

class _SpotState extends State<_Spot> {
  @override
  void initState() {
    super.initState();
    widget.spots[widget.mark] = context;
  }

  @override
  void dispose() {
    if (identical(widget.spots[widget.mark], context)) widget.spots.remove(widget.mark);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// How loud the voice is, as a glowing wireframe sphere in the theme's colours: a fine mesh whose surface ripples and
/// folds like a living thing, slowly tumbling, with a haze of specks drifting around it. It keeps moving in silence,
/// and as you talk it swells, ripples harder and faster, and the specks spread out and brighten. Red while a held
/// press is slid away to cancel; dim and slow while it isn't listening yet or is stopping. With reduced motion it holds
/// still and only swells.
class _Orb extends StatefulWidget {
  const _Orb({required this.level, required this.away, required this.busy, required this.link});
  final ValueListenable<double> level;
  final bool away;
  final bool busy;
  final _OrbLink link;

  @override
  State<_Orb> createState() => _OrbState();
}

/// The orb's state, kept by the sheet: a cross-fade builds the orb going anew, and it carries on from here rather than
/// starting over. Once [gone], it holds still and fades its mesh while its specks fly off.
class _OrbLink {
  final sphere = _Sphere();

  /// How loud, eased: 0 to 1.
  double level = 0;

  /// Its clocks: [t] runs faster as the voice is louder, what the ripples evolve with; [spin] turns it; [clock] is
  /// plain seconds, what it breathes with.
  double t = 0;
  double spin = 0;
  double clock = 0;

  /// Eased toward 1 while busy or away, so it dims or reddens rather than switching.
  double busy = 0;
  double away = 0;

  /// The mesh: 1 while it shows, fading to 0 once [gone].
  double shown = 1;
  bool gone = false;

  /// Shows it whole again, to listen.
  void reset() {
    gone = false;
    shown = 1;
  }

  /// Moves it on by [dt] seconds, hearing [heard] (0 to 1, as the recognizer says). [still]: reduced motion, so it
  /// only swells.
  void step(double dt, {required double heard, required bool busy, required bool away, required bool still}) {
    if (gone) {
      shown = math.max(0, shown - dt / .25);
      return;
    }
    double ease(double from, double to, double rate) => from + (to - from) * (1 - math.exp(-rate * dt));
    // A curve that lifts quiet speech, so normal talking swells it well, not just shouting. It rises quickly with the
    // voice and settles more slowly, so words read as pulses rather than flicker, at any frame rate.
    final target = busy ? 0.0 : math.min(1, math.pow(heard, .5) * 1.25).toDouble();
    level = ease(level, target, target > level ? 30 : 6);
    this.busy = ease(this.busy, busy ? 1 : 0, 10);
    this.away = ease(this.away, away ? 1 : 0, 14);
    if (still) return;
    final slow = 1 - .65 * this.busy;
    t += dt * slow * (1 + 1.6 * level);
    spin += dt * .3 * slow;
    clock += dt;
  }

  /// The orb's colours now: from the theme's accent to its warm prompt colour, the app icon's family, reddening while
  /// away and dimming while busy.
  _Palette palette() {
    final dark = C.t.dark;
    Color tint(Color c) {
      final shown = Color.lerp(Color.lerp(c, C.error, .85 * away), dark ? C.dim2 : C.dim, .65 * busy)!;
      // On a light background the lines read best a little darker than the accent.
      return dark ? shown : Color.lerp(shown, C.text, .15)!;
    }

    return _Palette(
      tint(Color.lerp(C.accent, dark ? C.text : C.accent, .35)!),
      tint(C.accent),
      tint(Color.lerp(C.accent, C.warn, .8)!),
    );
  }

  /// [count] specks of the orb as last drawn (in its own box), with their colours: mostly the mesh's visible points,
  /// some of the haze.
  List<(Offset, Color)> sample(int count) {
    final colors = palette();
    return [
      for (final (at, depth) in sphere.sample(count, math.Random(5)))
        (at, colors.at(sphere.along(at)).withValues(alpha: .55 + .45 * depth)),
    ];
  }
}

class _OrbState extends State<_Orb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  void _tick(Duration now) {
    final dt = math.min((now - _last).inMicroseconds / 1e6, .05);
    _last = now;
    setState(
      () => widget.link.step(
        dt,
        heard: widget.level.value,
        busy: widget.busy,
        away: widget.away,
        still: Motion.reduced(context),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final reduced = Motion.reduced(context);
    return Semantics(
      label: 'Listening',
      child: TweenAnimationBuilder<double>(
        // It grows into place as it comes, and when Keep talking brings it back; not when a cross-fade builds it anew.
        tween: Tween(begin: reduced || link.gone ? 1 : .6, end: 1),
        duration: Motion.themed(Motion.slow),
        curve: Motion.ease,
        builder: (context, grow, child) => Transform.scale(scale: grow, child: child),
        child: LayoutBuilder(
          builder: (context, box) {
            final d = math.min(box.maxWidth * .68, 260).toDouble();
            return SizedBox(
              key: const ValueKey('voice-level'),
              width: d * 1.3,
              height: d * 1.3,
              child: CustomPaint(
                painter: _OrbPainter(
                  sphere: link.sphere,
                  palette: link.palette(),
                  diameter: d,
                  breathe: math.sin(link.clock * 2 * math.pi / 3.4),
                  t: link.t,
                  spin: link.spin,
                  level: link.level,
                  amp: reduced ? .06 : (.08 + .14 * link.level) * (1 - .5 * link.busy),
                  glow: (C.t.dark ? 1 : .4) * (1 - .7 * link.busy),
                  dark: C.t.dark,
                  shown: link.shown,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The orb's gradient, from the top left ([from]) through [mid] to the bottom right ([to]).
@immutable
class _Palette {
  const _Palette(this.from, this.mid, this.to);
  final Color from;
  final Color mid;
  final Color to;

  /// The colour at [t] along it, 0 to 1.
  Color at(double t) => t < .5 ? Color.lerp(from, mid, t * 2)! : Color.lerp(mid, to, t * 2 - 1)!;

  @override
  bool operator ==(Object other) => other is _Palette && other.from == from && other.mid == mid && other.to == to;

  @override
  int get hashCode => Object.hash(from, mid, to);
}

/// The orb's mesh (lines of latitude and longitude on a sphere) and the haze of specks around it: where each point
/// sits on a unit sphere, fixed, and where it was last drawn, in buffers kept from frame to frame.
class _Sphere {
  _Sphere() {
    var k = 0;
    for (var i = 0; i < rings; i++) {
      final polar = math.pi * (i + 1) / (rings + 1);
      for (var j = 0; j < meridians; j++) {
        final azimuth = 2 * math.pi * j / meridians;
        _ux[k] = math.sin(polar) * math.cos(azimuth);
        _uy[k] = math.cos(polar);
        _uz[k] = math.sin(polar) * math.sin(azimuth);
        k++;
      }
    }
    _uy[k] = 1;
    _uy[k + 1] = -1;
    final rnd = math.Random(11);
    for (var h = 0; h < specks; h++) {
      final y = rnd.nextDouble() * 2 - 1;
      final a = rnd.nextDouble() * 2 * math.pi;
      final s = math.sqrt(1 - y * y);
      _hx[h] = s * math.cos(a);
      _hy[h] = y;
      _hz[h] = s * math.sin(a);
      // Most hug the surface; a few stray further out.
      _hr[h] = .04 + .36 * math.pow(rnd.nextDouble(), 2.2);
      _hp[h] = rnd.nextDouble() * 2 * math.pi;
      _hs[h] = (.12 + .3 * rnd.nextDouble()) * (rnd.nextBool() ? 1 : -1);
    }
  }

  static const rings = 44;
  static const meridians = 52;
  static const int points = rings * meridians + 2;
  static const int segments = rings * meridians + (rings - 1) * meridians + 2 * meridians;
  static const specks = 280;

  final _ux = Float32List(points);
  final _uy = Float32List(points);
  final _uz = Float32List(points);
  final _hx = Float32List(specks);
  final _hy = Float32List(specks);
  final _hz = Float32List(specks);

  /// How far out each speck floats past the surface, as a fraction of the radius; [_hp] its phase, [_hs] its drift.
  final _hr = Float32List(specks);
  final _hp = Float32List(specks);
  final _hs = Float32List(specks);

  /// Where each point and speck was last drawn, and how near (-1 the back, 1 the front).
  final _px = Float32List(points);
  final _py = Float32List(points);
  final _pz = Float32List(points);
  final _sx = Float32List(specks);
  final _sy = Float32List(specks);
  final _sz = Float32List(specks);

  /// The mesh's line ends and points, and the specks, split by depth: back, middle and front.
  final List<Float32List> lines = [for (var i = 0; i < 3; i++) Float32List(segments * 4)];
  final List<int> lineEnds = [0, 0, 0];
  final List<Float32List> dots = [for (var i = 0; i < 2; i++) Float32List(points * 2)];
  final List<int> dotEnds = [0, 0];
  final List<Float32List> haze = [for (var i = 0; i < 2; i++) Float32List(specks * 2)];
  final List<int> hazeEnds = [0, 0];

  /// The gradient's box last drawn, to find a point's colour along it.
  Rect _box = Rect.zero;
  late ui.Shader _shader;
  (Rect, _Palette)? _shaderFor;

  /// The gradient across [box] in [palette], made again only when either changes.
  ui.Shader shader(Rect box, _Palette palette) {
    _box = box;
    if (_shaderFor != (box, palette)) {
      _shaderFor = (box, palette);
      _shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [palette.from, palette.mid, palette.to],
      ).createShader(box);
    }
    return _shader;
  }

  /// How far along the gradient [at] is, 0 at its top left to 1 at its bottom right.
  double along(Offset at) {
    if (_box.isEmpty) return .5;
    final p = at - _box.topLeft;
    return ((p.dx / _box.width + p.dy / _box.height) / 2).clamp(0.0, 1.0);
  }

  /// How far the surface is pushed out at unit point (x, y, z) at time [t]: a few slow waves across the sphere, each
  /// bent by another, so it folds into lumps that drift and change instead of rolling round.
  static double _noise(double x, double y, double z, double t) {
    final warp = math.sin(1.9 * x + 1.4 * z + .6 * t);
    return .28 * math.sin(2.3 * (.8 * x + .6 * y) + t + 1.3 * warp) +
        .26 * math.sin(3.6 * (-.5 * y + .86 * z) - .9 * t + warp) +
        .3 * math.sin(4.9 * (.6 * x - .64 * y + .48 * z) + 1.4 * t + 2 + .8 * warp) +
        .26 * math.sin(6.1 * (.36 * x + .48 * y - .8 * z) - 1.2 * t + 4) +
        .16 * math.sin(8.2 * (.7 * x + .1 * y + .7 * z) + 1.7 * t + 1);
  }

  /// Works out where everything is drawn: centred on [c], [radius] across, rippled by [amp] at time [t], turned by
  /// [spin], the specks spread out by [spread].
  void place(Offset c, double radius, double t, double spin, double amp, double spread) {
    // Turning about its axis, which leans aside and tips toward the viewer and back: a slow tumble.
    final pitch = .3 + .25 * math.sin(spin * .37);
    final roll = .45 + .2 * math.sin(spin * .23);
    final (sa, ca, sb, cb) = (math.sin(spin), math.cos(spin), math.sin(pitch), math.cos(pitch));
    final (sr, cr) = (math.sin(roll), math.cos(roll));
    final (m10, m12, m20, m22) = (sb * sa, -sb * ca, -cb * sa, cb * ca);
    const eye = 3.4;
    for (var k = 0; k < points; k++) {
      final (x, y, z) = (_ux[k], _uy[k], _uz[k]);
      final r = 1 + amp * _noise(x, y, z, t);
      final (rx, ry, rz) = (x * r, y * r, z * r);
      final depth = m20 * rx + sb * ry + m22 * rz;
      final s = radius * eye / (eye - depth);
      final (sx, sy) = (ca * rx + sa * rz, m10 * rx + cb * ry + m12 * rz);
      _px[k] = c.dx + (cr * sx - sr * sy) * s;
      _py[k] = c.dy - (sr * sx + cr * sy) * s;
      _pz[k] = depth;
    }
    lineEnds.fillRange(0, 3, 0);
    void line(int a, int b) {
      final z = (_pz[a] + _pz[b]) / 2;
      final i = z < -.2 ? 0 : (z < .35 ? 1 : 2);
      final buffer = lines[i];
      var n = lineEnds[i];
      buffer[n++] = _px[a];
      buffer[n++] = _py[a];
      buffer[n++] = _px[b];
      buffer[n++] = _py[b];
      lineEnds[i] = n;
    }

    const m = meridians;
    for (var i = 0; i < rings; i++) {
      for (var j = 0; j < m; j++) {
        line(i * m + j, i * m + (j + 1) % m);
        if (i < rings - 1) line(i * m + j, (i + 1) * m + j);
      }
    }
    for (var j = 0; j < m; j++) {
      line(points - 2, j);
      line(points - 1, (rings - 1) * m + j);
    }
    dotEnds.fillRange(0, 2, 0);
    for (var k = 0; k < points; k++) {
      if (_pz[k] < -.15) continue;
      final i = _pz[k] < .4 ? 0 : 1;
      dots[i][dotEnds[i]++] = _px[k];
      dots[i][dotEnds[i]++] = _py[k];
    }
    hazeEnds.fillRange(0, 2, 0);
    for (var h = 0; h < specks; h++) {
      // Each drifts round the vertical at its own pace and bobs in and out.
      final a = t * _hs[h] + _hp[h];
      final (x0, z0) = (_hx[h] * math.cos(a) - _hz[h] * math.sin(a), _hx[h] * math.sin(a) + _hz[h] * math.cos(a));
      final r = 1 + amp * .5 + _hr[h] * (1 + .25 * math.sin(1.3 * t + _hp[h])) * spread;
      final (x, y, z) = (x0 * r, _hy[h] * r, z0 * r);
      final depth = m20 * x + sb * y + m22 * z;
      final s = radius * eye / (eye - depth);
      final (sx, sy) = (ca * x + sa * z, m10 * x + cb * y + m12 * z);
      _sx[h] = c.dx + (cr * sx - sr * sy) * s;
      _sy[h] = c.dy - (sr * sx + cr * sy) * s;
      _sz[h] = depth / r;
      final i = depth < 0 ? 0 : 1;
      haze[i][hazeEnds[i]++] = _sx[h];
      haze[i][hazeEnds[i]++] = _sy[h];
    }
  }

  /// [count] points as last drawn, with how near each is (0 the back, 1 the front): about three in four from the
  /// mesh's visible side, the rest from the haze.
  List<(Offset, double)> sample(int count, math.Random rnd) {
    final out = <(Offset, double)>[];
    while (out.length < count) {
      if (out.length % 4 == 3) {
        final h = rnd.nextInt(specks);
        out.add((Offset(_sx[h], _sy[h]), (_sz[h] + 1) / 2));
        continue;
      }
      final k = rnd.nextInt(points);
      if (_pz[k] > -.1) out.add((Offset(_px[k], _py[k]), (_pz[k] + 1) / 2));
    }
    return out;
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.sphere,
    required this.palette,
    required this.diameter,
    required this.breathe,
    required this.t,
    required this.spin,
    required this.level,
    required this.amp,
    required this.glow,
    required this.dark,
    required this.shown,
  });
  final _Sphere sphere;
  final _Palette palette;

  /// Across, at rest.
  final double diameter;

  /// Where its slow breath is, -1 to 1.
  final double breathe;
  final double t;
  final double spin;
  final double level;
  final double amp;
  final double glow;
  final bool dark;
  final double shown;

  static final _paint = Paint()..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = diameter / 2 * .8 * (1 + .025 * breathe + .14 * level);
    sphere.place(c, radius, t, spin, amp, 1 + 1.2 * level);
    final shader = sphere.shader(Rect.fromCircle(center: c, radius: diameter * .42), palette);

    // The bloom behind: the accent in the middle, each end of the gradient toward its side.
    for (final (at, color, reach, strength) in [
      (c, palette.mid, 1.9, .3),
      (c + Offset(radius * .35, radius * .4), palette.to, 1.3, .22),
      (c - Offset(radius * .35, radius * .4), palette.from, 1.2, .14),
    ]) {
      final r = radius * reach * (1 + .1 * level);
      canvas.drawCircle(
        at,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: glow * strength * (1 + .6 * level) * (.3 + .7 * shown)),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: at, radius: r)),
      );
    }

    void draw(ui.PointMode mode, Float32List buffer, int end, double width, double alpha) {
      if (end == 0 || alpha <= 0) return;
      canvas.drawRawPoints(
        mode,
        Float32List.sublistView(buffer, 0, end),
        _paint
          ..shader = shader
          ..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0))
          ..strokeWidth = width,
      );
    }

    final lit = .55 + .45 * level;
    draw(ui.PointMode.points, sphere.haze[0], sphere.hazeEnds[0], 1.4, .35 * lit);
    if (shown > 0) {
      draw(ui.PointMode.lines, sphere.lines[0], sphere.lineEnds[0], .5, (dark ? .14 : .1) * shown);
      // The near side glows: a blurred copy under its crisp lines.
      if (glow > 0) {
        canvas.saveLayer(
          Offset.zero & size,
          Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4, tileMode: TileMode.decal),
        );
        draw(ui.PointMode.lines, sphere.lines[2], sphere.lineEnds[2], 2.4, .5 * glow * shown);
        canvas.restore();
      }
      draw(ui.PointMode.lines, sphere.lines[1], sphere.lineEnds[1], .6, (dark ? .38 : .28) * shown);
      draw(ui.PointMode.lines, sphere.lines[2], sphere.lineEnds[2], .8, (dark ? .75 : .55) * shown);
      draw(ui.PointMode.points, sphere.dots[0], sphere.dotEnds[0], 1.3, .5 * shown);
      draw(ui.PointMode.points, sphere.dots[1], sphere.dotEnds[1], 1.9, (dark ? 1 : .8) * shown);
    }
    draw(ui.PointMode.points, sphere.haze[1], sphere.hazeEnds[1], 1.8, .8 * lit);
  }

  @override
  bool shouldRepaint(_OrbPainter old) => true;
}

/// One speck of the orb: where it leaves from and in what [color], which button it lands on ([to], in
/// [_Mark.buttons]'s order) and where on it ([at], a fraction of its width and height, so it lands right as the button
/// grows into place). It bursts out toward [burst] first, then comes down onto its place from [approach] (relative to
/// it).
class _Mote {
  const _Mote(this.from, this.color, this.burst, this.to, this.at, this.approach, this.delay, this.size);
  final Offset from;
  final Color color;
  final Offset burst;
  final int to;
  final Offset at;
  final Offset approach;

  /// How far into the flight it sets off: the orb's edge goes first.
  final double delay;
  final double size;
}

/// The specks the orb breaks into on Stop (the starts, where each was drawn, in its colour): Send and Keep talking fill
/// with them, Insert's outline traces, and a few gather where Cancel's label is.
class _Flock {
  factory _Flock(Rect orb, List<(Offset, Color)> starts, List<Rect> buttons, ThemeShape shape) {
    final rnd = math.Random(7);
    final ends = <(int, Offset, double)>[];
    for (final (i, rect) in buttons.indexed) {
      final round = RRect.fromRectAndRadius(
        rect,
        Radius.circular(shape == ThemeShape.soft ? rect.height / 2 : math.min(shape.maxRadius, rect.height / 2)),
      );
      Offset land(Offset p) => Offset((p.dx - rect.left) / rect.width, (p.dy - rect.top) / rect.height);
      if (i == 2) {
        final edge = (Path()..addRRect(round.deflate(1))).computeMetrics().first;
        for (var k = 0; k < counts[i]; k++) {
          final p = edge.getTangentForOffset(edge.length * (k + rnd.nextDouble() * .5) / counts[i])!.position;
          ends.add((i, land(p), p.dx));
        }
        continue;
      }
      final area = i == 1
          ? Rect.fromCenter(center: rect.center, width: rect.width * .4, height: rect.height * .3)
          : rect;
      for (var k = 0; k < counts[i];) {
        final p = Offset(area.left + rnd.nextDouble() * area.width, area.top + rnd.nextDouble() * area.height);
        if (!round.contains(p)) continue;
        ends.add((i, land(p), p.dx));
        k++;
      }
    }
    // Left of the orb goes left: paired by where they are across, the motes stream rather than cross in a tangle.
    final center = orb.center;
    final radius = orb.shortestSide * .3;
    final reach = [for (final (at, _) in starts) (at - center).distance].fold<double>(1, math.max);
    final across = [for (final (at, _) in starts) at.dx + (rnd.nextDouble() - .5) * radius * .5];
    final order = [for (var k = 0; k < starts.length; k++) k]..sort((a, b) => across[a].compareTo(across[b]));
    ends.sort((a, b) => a.$3.compareTo(b.$3));
    return _Flock._(orb, [
      for (final (k, (to, at, _)) in ends.indexed)
        if (starts[order[k * starts.length ~/ ends.length]] case (final from, final color))
          if (from - center case final out)
            _Mote(
              from,
              color,
              from +
                  (out.distance < 1 ? Offset.fromDirection(rnd.nextDouble() * 2 * math.pi) : out / out.distance) *
                      (radius * (.3 + .7 * rnd.nextDouble())) -
                  Offset(0, radius * .3 * rnd.nextDouble()),
              to,
              at,
              Offset((rnd.nextDouble() - .5) * 60, -(20 + 50 * rnd.nextDouble())),
              lag * (1 - out.distance / reach) + rnd.nextDouble() * .05,
              1.6 + rnd.nextDouble() * 1.4,
            ),
    ]);
  }

  _Flock._(this.orb, this.motes);

  /// How many motes it makes: what each button gets, in [_Mark.buttons]' order.
  static const counts = [130, 30, 80, 130];
  static final int count = counts.fold(0, (a, b) => a + b);

  /// The longest a mote waits to set off, as a fraction of the flight.
  static const lag = .3;

  final Rect orb;
  final List<_Mote> motes;
}

/// [flock] in flight at [t]: a flash where the orb was, then each mote along a curve to its button, a short trail
/// behind it, all fading as the buttons fade in. [buttons]: where they are now.
class _FlockPainter extends CustomPainter {
  _FlockPainter(this.flock, this.t, this.buttons) : super(repaint: t);
  final _Flock flock;
  final Animation<double> t;
  final List<Rect?> Function() buttons;

  @override
  void paint(Canvas canvas, Size size) {
    final p = t.value;
    if (p >= 1) return;
    final rects = buttons();
    if (rects.contains(null)) return;
    final colors = [C.accent, C.dim, C.text, C.accent];
    final fade = 1 - const Interval(.8, 1).transform(p);

    final flash = 1 - (p / .3).clamp(0.0, 1.0);
    if (flash > 0) {
      final c = flock.orb.center;
      final r = flock.orb.shortestSide * .4 * (1 + .5 * (1 - flash));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              C.accent.withValues(alpha: .25 * flash),
              C.accent.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    final trail = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dot = Paint();
    const curve = Curves.easeInOutCubic;
    for (final m in flock.motes) {
      final rect = rects[m.to]!;
      final to = rect.topLeft + Offset(m.at.dx * rect.width, m.at.dy * rect.height);
      final bend = to + m.approach;
      Offset along(double e) {
        final u = 1 - e;
        return m.from * (u * u * u) + m.burst * (3 * u * u * e) + bend * (3 * u * e * e) + to * (e * e * e);
      }

      // Each sets off after its delay and lands a little before the buttons are fully in.
      final local = ((p - m.delay) / (.95 - _Flock.lag)).clamp(0.0, 1.0);
      final e = curve.transform(local);
      final head = along(e);
      final color = Color.lerp(m.color, colors[m.to], Curves.easeIn.transform(e))!;
      final size = m.size * (1 - .3 * e);
      if (local > 0 && local < 1) {
        canvas.drawLine(
          along(curve.transform(math.max(0, local - .05))),
          head,
          trail
            ..color = color.withValues(alpha: .3 * fade)
            ..strokeWidth = size * .7,
        );
      }
      canvas.drawCircle(head, size / 2, dot..color = color.withValues(alpha: fade));
    }
  }

  @override
  bool shouldRepaint(_FlockPainter old) => old.flock != flock;
}

/// An E2E build's speaker (no microphone in the Simulator): says [words] one by one, a loudness swinging with
/// each, then goes quiet until stopped.
class ScriptedSpeech implements SpeechSource {
  ScriptedSpeech({this.words = _sentence});

  static const _sentence = [
    'Add',
    'a',
    'dark',
    'mode',
    'toggle',
    'to',
    'the',
    'settings',
    'page',
    'and',
    'write',
    'a',
    'test',
    'for',
    'it.',
  ];

  final List<String> words;
  StreamController<SpeechEvent>? _out;
  Timer? _timer;
  String _said = '';

  @override
  Future<SpeechCheck> check() async => const SpeechCheck(SpeechStatus.ready);

  @override
  Stream<SpeechEvent> listen() {
    _timer?.cancel();
    _said = '';
    var tick = 0;
    final out = _out = StreamController<SpeechEvent>(onCancel: () => _timer?.cancel());
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      tick++;
      final word = tick ~/ 3;
      out.add(SpeechLevel(word < words.length ? .45 + .4 * math.sin(tick * 1.3).abs() : .04));
      if (tick % 3 == 0 && word <= words.length) {
        _said = words.take(word).join(' ');
        out.add(SpeechHeard(_said));
      }
    });
    return out.stream;
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    final out = _out;
    if (out == null || out.isClosed) return;
    out
      ..add(SpeechHeard(_said))
      ..add(const SpeechEnded(SpeechEnd.stopped));
    await out.close();
  }

  @override
  Future<void> fix(SpeechFix fix) async {}
}
