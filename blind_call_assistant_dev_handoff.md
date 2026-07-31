# Blind Call Assistant — Developer Handoff

## What this app is

A Flutter app for Android that lets a blind or low-vision user dial and
answer phone calls entirely by voice. No menus, no small buttons — every
interaction is either spoken or a single full-screen tap.

App launch itself happens via an external gesture mechanism that is **out
of scope** for this build — assume the app is already open and treat the
first screen as the starting point.

## Core requirements

1. **Outgoing calls, fully voice-driven**
   - On launch (or on-screen tap), the app asks who to call.
   - User speaks a saved contact's name.
   - App matches the spoken name against the device's contact list and
     calls the best match, confirming aloud before dialing ("Calling
     Ahmed.").
   - If no confident match is found, say so and let the user try again —
     never guess-dial a low-confidence match.

2. **Incoming calls, fully voice-driven**
   - Let the phone ring normally for a few seconds first (don't talk over
     the initial ring / any caller-ID chime the user may already rely on).
   - Then announce the caller's name (from contacts) or number if unknown.
   - Accept "answer" / "ignore" as spoken commands.
   - A full-screen tap must also answer immediately at any point — this is
     the fastest path in case voice recognition is slow or fails, and
     matters for urgency (e.g., an emergency call).

3. **Everything else** (UI layout, exact wording of prompts, fallback
   behavior, etc.) is at the developer's discretion, within the constraint
   that the app must remain usable by someone who cannot see the screen at
   all — every state change needs a spoken confirmation, not just a visual
   one.

## Non-negotiable platform constraint

This is **Android-only**. Answering/rejecting real cellular calls and
observing call state requires Android's `telecom` APIs (`InCallService`),
which iOS does not expose to third-party apps for regular calls. Do not
attempt an iOS version of the call-handling piece.

## Required one-time OS-level setup

Android will only deliver call state and answer/reject control to an app
registered as a calling account — practically, the user must set this app
as their default (or an available) Phone app through Android's own system
role picker (`RoleManager.ROLE_DIALER` on Android 10+, `ACTION_CHANGE_
DEFAULT_DIALER` before that). This is a one-time, OS-owned dialog — it
cannot be made voice-only or skipped. Trigger it once during onboarding and
have the app talk the user through it verbally beforehand, since it's the
one moment of the flow that isn't under our control.

## Required permissions

- `CALL_PHONE`
- `READ_PHONE_STATE`
- `READ_CONTACTS`
- `ANSWER_PHONE_CALLS`
- `RECORD_AUDIO` (for speech recognition)
- `MANAGE_OWN_CALLS`

The app should have a spoken fallback if any of these are denied — right
now this is a gap, see "Known gaps" below.

## Suggested architecture (already scaffolded — see attached code)

- **Flutter side**: one screen, state machine (idle → listening →
  confirming → in-call, plus a parallel incoming-call branch). Services for
  TTS (speak-and-wait, never overlapping prompts), STT (single-shot listen
  with silence detection), contacts (load + fuzzy-match spoken names), and
  a platform channel bridge for call control.
- **Native Android side (Kotlin)**: an `InCallService` implementation that
  the OS binds once the dialer role is granted — this is what receives
  ringing/active/disconnected state and exposes `answer()`/`reject()`. A
  `MethodChannel` for placing outgoing calls and triggering the role
  request; an `EventChannel` for pushing call state to Flutter.

## Known gaps to close before shipping

1. **Background reliability**: call events currently only reach Flutter
   while the Activity is alive and has an attached `EventChannel` sink. If
   the app is fully killed, an incoming call won't be announced. Needs a
   headless `FlutterEngine` (held in a custom `Application` class) so the
   native service can always deliver events regardless of Activity state.
2. **Contact name matching**: the current matcher is a simple
   token-overlap/substring heuristic. It should be tuned and tested against
   real recordings of the actual users' contact lists and accents — this is
   the single biggest determinant of whether the app feels reliable.
3. **Permission-denial handling**: needs a spoken retry/explanation path,
   not just a silent failure.
4. **Testing**: prioritize automated tests around the dial/incoming-call
   state machine before adding new features — it's the part most likely to
   have edge-case bugs (e.g., a call ending mid-listen, or two events
   arriving out of order).

## Deliverable expectations

- Runs on a physical Android device (call handling can't be verified on
  most emulators).
- Both flows (voice-dial, voice-answer) working end to end, including the
  one-time dialer-role setup.
- Written notes on any deviations from this spec and why.
