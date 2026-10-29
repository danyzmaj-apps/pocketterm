import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:pocketterm_core/speech.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/corona.dart';
import 'package:pocketterm_mobile/e2e_hooks.dart';
import 'package:pocketterm_mobile/motion.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the voice sheet hears from: the phone's on-device recognizer, or in an E2E build (no microphone in the
/// Simulator) a made-up speaker that says [ScriptedSpeech.words]. Tests put a fake here.
SpeechSource voiceSource = e2eBuild ? ScriptedSpeech() : const NativeSpeech();

/// The language the voice sheet listens in, per phone: chosen in Settings or on the sheet, else Auto (the phone's
/// first language PocketTerm can listen for, see [SpeechLanguage.fromLocales]).
final voiceLanguage = VoiceLanguage();

/// [voiceLanguage]: kept as the preference `voiceLanguage`, a [SpeechLanguage]'s name; none is Auto.
class VoiceLanguage extends ChangeNotifier {
  static const prefsKey = 'voiceLanguage';

  SharedPreferences? _prefs;
  SpeechLanguage? _choice;

  /// What was chosen; null for Auto.
  SpeechLanguage? get choice => _choice;

  /// What it listens in now.
  SpeechLanguage get language => _choice ?? phone;

  /// What Auto listens in: the phone's languages, as they are now.
  SpeechLanguage get phone => SpeechLanguage.fromLocales(ui.PlatformDispatcher.instance.locales);

  void load(SharedPreferences prefs) {
    _prefs = prefs;
    _choice = SpeechLanguage.values.asNameMap()[prefs.getString(prefsKey)];
    notifyListeners();
  }

  /// Keeps [choice] for this phone; null goes back to Auto.
  Future<void> choose(SpeechLanguage? choice) async {
    if (choice == _choice) return;
    _choice = choice;
    notifyListeners();
    final prefs = _prefs;
    if (prefs == null) return;
    await (choice == null ? prefs.remove(prefsKey) : prefs.setString(prefsKey, choice.name));
  }
}

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
  final _orbLink = CoronaLink();

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

  /// Listens. The star, hidden until it's laid out, then gathers itself: from [gatherFrom] (points in the sheet) or out
  /// of the dark.
  Future<void> _start({List<Offset>? gatherFrom}) async {
    _orbLink.reset();
    _go(_Phase.checking);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final orb = _rectOf(_Mark.orb);
      _orbLink.assemble(orb == null || gatherFrom == null ? null : [for (final p in gatherFrom) p - orb.topLeft]);
    });
    SpeechCheck check;
    try {
      check = await widget.source.check(_language);
    } on Object {
      check = const SpeechCheck(SpeechStatus.unavailable);
    }
    if (!mounted) return;
    if (!check.ready) {
      _problem = check;
      return _go(_Phase.problem);
    }
    unawaited(HapticFeedback.mediumImpact());
    _sub = widget.source
        .listen(_language)
        .listen(
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
          _problem = SpeechCheck(status, fix: status == SpeechStatus.noLanguage ? SpeechFix.speechSettings : null);
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
    // The star bursts and fades as its specks, where they are now, set off.
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

  /// Listens again, the new words after what's in the editor now. The star gathers back out of the buttons it broke
  /// into.
  void _keepTalking() {
    final buttons = [for (final m in _Mark.buttons) _rectOf(m)];
    final from = buttons.contains(null)
        ? null
        : [for (final (_, _, p) in _Flock.landings(buttons.cast<Rect>(), C.t.shape, math.Random(7))) p];
    _before = _edit.text.trim();
    _heard = _before;
    _note = null;
    _fly.value = 1;
    _flock = null;
    unawaited(_start(gatherFrom: from));
  }

  SpeechLanguage get _language => voiceLanguage.language;

  /// Listens in the other language from now on, and keeps it for this phone. Mid-listening, the words so far stay
  /// and listening goes on in the new one; a problem is checked again for it.
  void _switchLanguage() {
    final next = SpeechLanguage.values[(_language.index + 1) % SpeechLanguage.values.length];
    unawaited(voiceLanguage.choose(next));
    switch (_phase) {
      case _Phase.listening:
        unawaited(_sub?.cancel());
        _sub = null;
        _before = _heard.trim();
        _heard = _before;
        unawaited(_start());
      case _Phase.problem:
        _note = null;
        unawaited(_start());
      case _Phase.review || _Phase.checking || _Phase.stopping || _Phase.downloading:
        setState(() {});
    }
  }

  Future<void> _fix(SpeechFix fix) async {
    if (fix != SpeechFix.download) return await widget.source.fix(fix, _language);
    _go(_Phase.downloading);
    try {
      await widget.source.fix(fix, _language);
    } on Object catch (e) {
      if (!mounted) return;
      _problem = const SpeechCheck(SpeechStatus.noLanguage, fix: SpeechFix.download);
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

  static String problemText(SpeechCheck c, SpeechLanguage language) {
    final lang = language.title;
    return switch ((c.status, c.fix)) {
      (SpeechStatus.denied, _) =>
        isIos
            ? 'PocketTerm isn’t allowed to use the microphone or speech recognition. Allow them in Settings.'
            : 'PocketTerm isn’t allowed to use the microphone. Allow it in Settings.',
      (SpeechStatus.restricted, _) => 'Speech recognition is turned off on this phone.',
      (SpeechStatus.noLanguage, SpeechFix.download) =>
        '$lang for speech recognition isn’t on this phone yet. Download it once; what you say stays on the phone.',
      (SpeechStatus.noLanguage, SpeechFix.speechSettings) =>
        'This phone has no $lang for speech recognition on the device. Add it in the phone’s speech settings.',
      (SpeechStatus.noLanguage, _) =>
        isIos
            ? 'This iPhone can’t recognize $lang on the device yet. Turn on Dictation in $lang in Settings → General → '
                  'Keyboard, and it downloads.'
            : 'This phone can’t recognize $lang on the device.',
      (SpeechStatus.downloading, _) => '$lang for speech recognition is downloading. Try again when it’s done.',
      (SpeechStatus.unavailable || SpeechStatus.ready, _) =>
        'This phone can’t recognize speech on the device, so voice prompts are off here.',
    };
  }

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
            _languageChip(),
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
        problemText(_problem, _language),
        key: const ValueKey('voice-problem'),
        style: TextStyle(fontSize: 18, height: 1.4, color: C.text),
      ),
      if (_note != null) ...[const SizedBox(height: 8), Text(_note!, style: TextStyle(fontSize: 14, color: C.dim))],
    ],
    _Phase.downloading => [
      Text(
        'Downloading ${_language.title} for speech recognition…',
        style: TextStyle(fontSize: 18, height: 1.4, color: C.dim),
      ),
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

  /// The language it listens in, at the top; a tap switches to the other one. Not while it's starting, stopping or
  /// downloading, nor while held (the finger is on the microphone).
  Widget _languageChip() {
    final can = !_held && (_phase == _Phase.listening || _phase == _Phase.problem || _phase == _Phase.review);
    final language = _language;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Semantics(
          identifier: 'voice-language',
          label: 'Language: ${language.title}. Switch',
          excludeSemantics: true,
          button: true,
          enabled: can,
          child: TextButton.icon(
            key: const ValueKey('voice-language'),
            style: TextButton.styleFrom(foregroundColor: C.dim, visualDensity: VisualDensity.compact),
            onPressed: can ? _switchLanguage : null,
            icon: const Icon(Icons.translate_rounded, size: 16),
            label: Text(language.label),
          ),
        ),
      ),
    );
  }

  /// The controls under what's said: the orb becomes Keep talking, Insert and Send by motes flying from one to
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
          child: Corona(level: _level, away: away, busy: !listening, link: _orbLink),
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
              // A tap needs no hint: the star is the stop button. A hold says how to stop or cancel.
              if (_held)
                Text(
                  away ? 'Release to cancel' : 'Release to stop · Slide away to cancel',
                  key: const ValueKey('voice-hold-hint'),
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
        // No Cancel: the sheet's close button and dragging it away already do that.
        final row = [
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
                // Side by side while the longer label fits half the width; very large text stacks them.
                final style = Theme.of(context).textTheme.labelLarge;
                final scaler = MediaQuery.textScalerOf(context);
                var widest = 0.0;
                for (final text in ['Insert', 'Send']) {
                  final label = TextPainter(
                    text: TextSpan(text: C.label(text), style: style),
                    textDirection: TextDirection.ltr,
                    textScaler: scaler,
                  )..layout();
                  widest = math.max(widest, label.width);
                  label.dispose();
                }
                final fits = 2 * (widest + tight.horizontal) + 8 <= box.maxWidth;
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
  insert,
  send;

  static const List<_Mark> buttons = [more, insert, send];
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

/// The specks the orb breaks into on Stop (the starts, where each was drawn, in its colour), landing on the buttons
/// at [landings].
class _Flock {
  factory _Flock(Rect orb, List<(Offset, Color)> starts, List<Rect> buttons, ThemeShape shape) {
    final rnd = math.Random(7);
    final ends = [for (final (i, at, p) in landings(buttons, shape, rnd)) (i, at, p.dx)];
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

  /// Where on [buttons] (in [_Mark.buttons]' order) the motes land, as which button, where on it (a fraction of its
  /// width and height) and where that is now: Send and Keep talking fill with them and Insert's outline traces. Keep
  /// talking flies the star back together from the same points.
  static List<(int, Offset, Offset)> landings(List<Rect> buttons, ThemeShape shape, math.Random rnd) {
    final out = <(int, Offset, Offset)>[];
    for (final (i, rect) in buttons.indexed) {
      final round = RRect.fromRectAndRadius(
        rect,
        Radius.circular(shape == ThemeShape.soft ? rect.height / 2 : math.min(shape.maxRadius, rect.height / 2)),
      );
      Offset land(Offset p) => Offset((p.dx - rect.left) / rect.width, (p.dy - rect.top) / rect.height);
      if (i == 1) {
        final edge = (Path()..addRRect(round.deflate(1))).computeMetrics().first;
        for (var k = 0; k < counts[i]; k++) {
          final p = edge.getTangentForOffset(edge.length * (k + rnd.nextDouble() * .5) / counts[i])!.position;
          out.add((i, land(p), p));
        }
        continue;
      }
      final area = rect;
      for (var k = 0; k < counts[i];) {
        final p = Offset(area.left + rnd.nextDouble() * area.width, area.top + rnd.nextDouble() * area.height);
        if (!round.contains(p)) continue;
        out.add((i, land(p), p));
        k++;
      }
    }
    return out;
  }

  /// How many motes it makes: what each button gets, in [_Mark.buttons]' order.
  static const counts = [140, 90, 140];
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
    final colors = [C.accent, C.text, C.accent];
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

/// An E2E build's speaker (no microphone in the Simulator): says [words] (else a sentence in the language it
/// listens in) one by one, a loudness swinging with each, then goes quiet until stopped.
class ScriptedSpeech implements SpeechSource {
  ScriptedSpeech({this.words});

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

  static const _croatian = ['Dodaj', 'tamni', 'način', 'rada', 'u', 'postavke', 'i', 'napiši', 'test', 'za', 'to.'];

  final List<String>? words;
  StreamController<SpeechEvent>? _out;
  Timer? _timer;
  String _said = '';

  @override
  Future<SpeechCheck> check(SpeechLanguage language) async => const SpeechCheck(SpeechStatus.ready);

  @override
  Stream<SpeechEvent> listen(SpeechLanguage language) {
    _timer?.cancel();
    _said = '';
    final words = this.words ?? (language == SpeechLanguage.croatian ? _croatian : _sentence);
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
  Future<void> fix(SpeechFix fix, SpeechLanguage language) async {}
}
