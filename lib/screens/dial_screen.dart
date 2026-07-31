import 'dart:async';
import 'package:flutter/material.dart';

import '../services/tts_service.dart';
import '../services/speech_service.dart';
import '../services/contacts_service.dart';
import '../services/call_platform.dart';
import '../services/onboarding_service.dart';

enum _AppState {
  onboarding,
  idle,
  listeningForName,
  confirmingDial,
  incomingCall,
  inCall,
  error
}

/// Primary voice-first screen for Blind Call Assistant.
/// Features dynamic contact syncing, spoken dial confirmation, real-time incoming voice command streaming,
/// reverse phone caller-ID resolution, and speakerphone enforcement.
class DialScreen extends StatefulWidget {
  const DialScreen({super.key});

  @override
  State<DialScreen> createState() => _DialScreenState();
}

class _DialScreenState extends State<DialScreen> with SingleTickerProviderStateMixin {
  _AppState _state = _AppState.idle;
  String _statusText = 'Initializing...';
  String _activeCallTarget = '';
  StreamSubscription? _callSub;
  bool _hasAnnouncedReadyOnLaunch = false;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _setupAnimation();
    _bootstrap();
  }

  void _setupAnimation() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _bootstrap() async {
    _callSub = CallPlatform.instance.events.listen(_onCallEvent);

    final status = await OnboardingService.instance.checkStatus();
    if (!status.hasBasicPermissions) {
      setState(() {
        _state = _AppState.onboarding;
        _statusText = 'Setup Required\nTap screen to begin setup';
      });
      await OnboardingService.instance.runSpokenOnboarding();
      final updatedStatus = await OnboardingService.instance.checkStatus();
      if (!updatedStatus.hasBasicPermissions) {
        return;
      }
    }

    await ContactsService.instance.loadContacts();

    // Preserve incoming or in-call state if app was launched cold by an incoming call event!
    if (_state != _AppState.incomingCall && _state != _AppState.inCall) {
      _resetToIdle();

      if (!_hasAnnouncedReadyOnLaunch) {
        _hasAnnouncedReadyOnLaunch = true;
        await TtsService.instance.speak('Call Assistant Ready.');
      }
    } else {
      _hasAnnouncedReadyOnLaunch = true;
    }
  }

  @override
  void dispose() {
    _callSub?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  // ---- Screen Interaction Handler ----------------------------------------

  Future<void> _onScreenTap() async {
    // 1. Setup / Onboarding Tap
    if (_state == _AppState.onboarding) {
      await OnboardingService.instance.runSpokenOnboarding(forcePromptDialer: true);
      final status = await OnboardingService.instance.checkStatus();
      if (status.hasBasicPermissions) {
        await ContactsService.instance.loadContacts();
        _resetToIdle();
      }
      return;
    }

    // 2. Incoming Call Tap -> Answer Call immediately & enable speakerphone
    if (_state == _AppState.incomingCall) {
      await _answerIncoming();
      return;
    }

    // 3. Active In-Call Tap -> End Call / Hang Up
    if (_state == _AppState.inCall) {
      await _endCall();
      return;
    }

    // 4. Tap during dial confirmation -> Cancel confirmation
    if (_state == _AppState.confirmingDial) {
      await SpeechService.instance.cancel();
      await TtsService.instance.stop();
      await TtsService.instance.speak('Call cancelled.');
      _resetToIdle();
      return;
    }

    // 5. Tap during speech listening -> Cancel listening and reset
    if (_state == _AppState.listeningForName) {
      await SpeechService.instance.cancel();
      await TtsService.instance.stop();
      _resetToIdle();
      return;
    }

    if (_state != _AppState.idle) return;

    // Start outgoing voice dial
    setState(() {
      _state = _AppState.listeningForName;
      _statusText = 'Listening...\nWho do you want to call?';
    });

    await TtsService.instance.speak('Who do you want to call?');
    if (_state != _AppState.listeningForName) return;

    final heard = await SpeechService.instance.listenOnce(
      timeout: const Duration(seconds: 10),
    );

    if (_state != _AppState.listeningForName) return;

    if (heard == null || heard.trim().isEmpty) {
      setState(() {
        _statusText = 'Did not hear a name.\nTap to try again.';
      });
      await TtsService.instance.speak('I didn\'t hear a name. Tap to try again.');
      _resetToIdle();
      return;
    }

    // Dynamic sync with device contacts to include any newly added contacts!
    final match = await ContactsService.instance.findBestMatchAsync(heard);
    if (match == null) {
      setState(() {
        _statusText = 'Contact "$heard" not found.\nTap to try again.';
      });
      await TtsService.instance.speak(
        'I couldn\'t find $heard in your contacts. Tap to try again.',
      );
      _resetToIdle();
      return;
    }

    // Lock in target and require spoken confirmation before placing call!
    _activeCallTarget = match.displayName;
    setState(() {
      _state = _AppState.confirmingDial;
      _statusText = 'Call ${match.displayName}?\nSay YES to confirm\nor TAP to cancel';
    });

    await TtsService.instance.speak(
      'Do you want to call ${match.displayName}? Say yes to confirm, or tap screen to cancel.',
    );

    if (_state != _AppState.confirmingDial) return;

    final confirmationHeard = await SpeechService.instance.listenOnce(
      timeout: const Duration(seconds: 7),
    );

    if (_state != _AppState.confirmingDial) return;

    final confirmQuery = confirmationHeard?.toLowerCase().trim() ?? '';
    final isYes = _isConfirmYesKeyword(confirmQuery);

    if (!isYes) {
      setState(() {
        _statusText = 'Call Cancelled\nTap anywhere to try again';
      });
      await TtsService.instance.speak('Call cancelled. Tap anywhere to try again.');
      _resetToIdle();
      return;
    }

    // Confirmed YES! Proceed to dial:
    setState(() {
      _state = _AppState.inCall;
      _statusText = 'CALLING / IN CALL\n$_activeCallTarget\nTap screen to end call';
    });

    await SpeechService.instance.cancel();
    await TtsService.instance.speak('Calling ${match.displayName}.');

    try {
      await CallPlatform.instance.placeCall(match.phoneNumber);
      await CallPlatform.instance.enableSpeakerphone();
    } catch (e) {
      await TtsService.instance.speak('Unable to place call.');
      _resetToIdle();
    }
  }

  bool _isConfirmYesKeyword(String text) {
    final keywords = ['yes', 'yeah', 'yep', 'sure', 'ok', 'okay', 'call', 'dial', 'correct', 'right', 'do it', 'go'];
    for (final kw in keywords) {
      if (text.contains(kw)) return true;
    }
    return false;
  }

  void _resetToIdle({bool speakCallEnded = false}) async {
    if (!mounted) return;
    setState(() {
      _state = _AppState.idle;
      _statusText = 'Tap Anywhere\nto Call a Contact';
      _activeCallTarget = '';
    });

    if (speakCallEnded) {
      await TtsService.instance.speak('Call ended. Call Assistant ready.');
    }
  }

  // ---- Call Telecom State Event Listener ----------------------------------

  void _onCallEvent(CallEvent event) {
    switch (event.type) {
      case 'incoming':
        _handleIncoming(event);
        break;
      case 'dialing':
        setState(() {
          _state = _AppState.inCall;
          _statusText = 'CALLING / IN CALL\n${_activeCallTarget.isNotEmpty ? _activeCallTarget : "Dialing"}\nTap screen to end call';
        });
        CallPlatform.instance.enableSpeakerphone();
        break;
      case 'ended':
      case 'rejected':
        if (_state == _AppState.inCall || _state == _AppState.incomingCall || _state == _AppState.confirmingDial) {
          _resetToIdle(speakCallEnded: true);
        } else {
          _resetToIdle();
        }
        break;
      case 'answered':
        CallPlatform.instance.enableSpeakerphone();
        setState(() {
          _state = _AppState.inCall;
          _statusText = 'IN ACTIVE CALL\n${_activeCallTarget.isNotEmpty ? _activeCallTarget : "Connected"}\nTap screen to end call';
        });
        break;
    }
  }

  Future<void> _handleIncoming(CallEvent event) async {
    // Immediately stop any startup TTS & mark launch announcement as done!
    _hasAnnouncedReadyOnLaunch = true;
    await TtsService.instance.stop();

    // Resolve caller identification with dynamic contact sync & reverse phone lookup
    String callerName = 'Unknown caller';

    if (event.number != null && event.number!.isNotEmpty) {
      final contact = await ContactsService.instance.findContactByNumberAsync(event.number!);
      if (contact != null && contact.displayName.isNotEmpty) {
        callerName = contact.displayName;
      } else if (event.callerName != null && event.callerName!.isNotEmpty) {
        callerName = event.callerName!;
      } else {
        callerName = 'number ${event.number}';
      }
    } else if (event.callerName != null && event.callerName!.isNotEmpty) {
      callerName = event.callerName!;
    }

    _activeCallTarget = callerName;
    setState(() {
      _state = _AppState.incomingCall;
      _statusText = 'INCOMING CALL\n$callerName\nTap to answer or say answer / ignore';
    });

    // Brief announcement prompt
    await TtsService.instance.speak('Call from $callerName. Say answer or ignore.');
    await TtsService.instance.stop(); // Stop TTS immediately so mic has audio focus

    if (_state != _AppState.incomingCall) return;

    final answerKw = [
      'answer', 'pick', 'pickup', 'yes', 'accept', 'hello', 'attend',
      'yeah', 'yep', 'receive', 'ok', 'okay', 'take'
    ];
    final ignoreKw = [
      'ignore', 'reject', 'decline', 'no', 'cut', 'cancel', 'stop',
      'hang', 'dont', 'nope', 'drop', 'busy', 'end'
    ];

    // Real-time partial speech recognition stream
    await SpeechService.instance.listenForKeywords(
      answerKeywords: answerKw,
      ignoreKeywords: ignoreKw,
      onMatched: (matchedType) async {
        if (_state != _AppState.incomingCall) return;
        if (matchedType == 'answer') {
          await _answerIncoming();
        } else if (matchedType == 'ignore') {
          await _rejectIncoming();
        }
      },
    );
  }

  Future<void> _answerIncoming() async {
    await SpeechService.instance.cancel();
    await TtsService.instance.stop();
    await CallPlatform.instance.answerCall();
    await CallPlatform.instance.enableSpeakerphone();
    setState(() {
      _state = _AppState.inCall;
      _statusText = 'IN ACTIVE CALL\n$_activeCallTarget\nTap screen to end call';
    });
    await TtsService.instance.speak('Call answered.');
  }

  Future<void> _rejectIncoming() async {
    await SpeechService.instance.cancel();
    await TtsService.instance.stop();
    await CallPlatform.instance.rejectCall();
    _resetToIdle(speakCallEnded: true);
  }

  Future<void> _endCall() async {
    await SpeechService.instance.cancel();
    await TtsService.instance.stop();
    await CallPlatform.instance.rejectCall();
    _resetToIdle(speakCallEnded: true);
  }

  // ---- Dynamic Visual Accessibility Styling ---------------------------------

  Color get _backgroundColor => switch (_state) {
        _AppState.onboarding => const Color(0xFF1E1B4B),
        _AppState.idle => const Color(0xFF0F172A),
        _AppState.listeningForName => const Color(0xFF581C87),
        _AppState.confirmingDial => const Color(0xFF0284C7), // Sky blue confirmation screen
        _AppState.incomingCall => const Color(0xFF065F46),
        _AppState.inCall => const Color(0xFF1E3A8A),
        _AppState.error => const Color(0xFF991B1B),
      };

  IconData get _stateIcon => switch (_state) {
        _AppState.onboarding => Icons.settings_voice,
        _AppState.idle => Icons.touch_app,
        _AppState.listeningForName => Icons.mic,
        _AppState.confirmingDial => Icons.record_voice_over,
        _AppState.incomingCall => Icons.ring_volume,
        _AppState.inCall => Icons.volume_up, // Speakerphone active icon
        _AppState.error => Icons.warning_amber_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final isListening = _state == _AppState.listeningForName;
    final isConfirming = _state == _AppState.confirmingDial;
    final isRinging = _state == _AppState.incomingCall;
    final isInCall = _state == _AppState.inCall;

    return Scaffold(
      backgroundColor: _backgroundColor,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onScreenTap,
        child: Semantics(
          label: _statusText.replaceAll('\n', ' '),
          button: true,
          child: SafeArea(
            child: SizedBox.expand(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Dynamic animated visual feedback icon
                    ScaleTransition(
                      scale: (isListening || isConfirming || isRinging || isInCall)
                          ? _pulseAnimation
                          : const AlwaysStoppedAnimation(1.0),
                      child: Container(
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isInCall ? Colors.red.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.15),
                          border: Border.all(color: isInCall ? Colors.redAccent : Colors.white.withValues(alpha: 0.3), width: 3),
                        ),
                        child: Icon(
                          _stateIcon,
                          size: 72,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 48),

                    // Primary high-contrast status text
                    Text(
                      _statusText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        height: 1.3,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Action hint bar
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: isInCall ? Colors.red.shade900.withValues(alpha: 0.6) : Colors.black.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: isInCall ? Colors.redAccent : Colors.white24),
                      ),
                      child: Text(
                        _getHintText(),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isInCall ? Colors.white : Colors.white70,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _getHintText() => switch (_state) {
        _AppState.onboarding => 'Tap screen to configure permissions',
        _AppState.idle => 'Tap anywhere to speak',
        _AppState.listeningForName => 'Listening... Speak contact name',
        _AppState.confirmingDial => 'SAY YES TO CALL OR TAP TO CANCEL',
        _AppState.incomingCall => 'TAP TO ANSWER OR SAY ANSWER/IGNORE',
        _AppState.inCall => 'SPEAKERPHONE ON - TAP TO HANG UP',
        _AppState.error => 'Tap to retry',
      };
}
