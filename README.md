# Blind Call Assistant

A fully voice-controlled Flutter app for dialing and attending calls without
needing to see the screen.

## What's implemented

**Outgoing calls** — tap anywhere → app asks "who do you want to call?" →
speech-to-text captures a name → fuzzy-matched against device contacts →
TTS confirms and dials via `Intent.ACTION_CALL`.

**Incoming calls** — the phone rings normally for ~3 seconds, then the app
announces the caller's name (or number, if unknown) and listens for
"answer" / "ignore". A full-screen tap answers immediately at any time,
since that's the fastest possible action in an emergency.

## Required one-time setup: default dialer role

Android only delivers call state (ringing, active, ended) and answer/reject
control to an app that's registered as a **calling account** — in practice,
this means the user must set this app as their default (or an available)
Phone app via Android's system role picker. There's no way around this; it's
an OS security boundary, not a bug in this code.

Call `CallPlatform.instance.requestPhoneAccountSetup()` once during
onboarding — it triggers Android's own dialog for this. Walk the user
through it verbally, since it's the one moment they can't be purely
voice-driven (it's a system UI, not this app's).

## Known limitations to address before shipping

1. **Background delivery**: `CallInService` is bound by the OS independently
   of the Activity, but events currently only reach Flutter while
   `MainActivity` is alive and has attached its `EventChannel` sink (see
   `CallEventBridge.kt`). If the app is fully killed, an incoming call won't
   be announced. Fix: back the bridge with a headless `FlutterEngine` held
   in a custom `Application` class so it's always available.
2. **STT accuracy for names**: the fuzzy matcher in `ContactsService` is a
   simple token-overlap heuristic — fine to start, but worth tuning against
   real recordings of your users' contact lists and accents.
3. **Permissions flow**: `permission_handler` requests are fired but the UI
   doesn't yet have a spoken fallback if the user denies contacts/phone
   permissions. Needs a voice-guided retry path.
4. **No tests yet** — the state machine in `dial_screen.dart` is the
   highest-value thing to cover first (idle → listening → confirming →
   in-call, and the incoming-call branch).

## Structure

```
lib/
  main.dart
  screens/dial_screen.dart       # the entire UI — one screen, voice + full-screen tap
  services/tts_service.dart      # speak-and-wait wrapper
  services/speech_service.dart   # single-shot listen wrapper
  services/contacts_service.dart # contact loading + fuzzy name matching
  services/call_platform.dart    # Dart side of the platform channel

android/app/src/main/kotlin/com/blindassist/call/
  MainActivity.kt      # MethodChannel + EventChannel wiring, dialer role request
  CallInService.kt      # android.telecom.InCallService — receives/controls real calls
  CallEventBridge.kt    # static relay from the OS-bound service to the Activity
```

## Next steps

Run `flutter pub get`, then `flutter run` on a physical Android device
(call handling can't be tested on most emulators). Walk through the dialer
role prompt once, then test both flows end to end.
