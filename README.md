# Life Lense

A fully offline, voice-first Android app for blind and visually impaired people. It
merges the original **Blind Call Assistant** (voice calling) and the **PKR currency
detector** with the remaining modules into one app. Every feature runs on the phone:
the release build has no `INTERNET` permission at all.

## Modes

The modules are grouped into 11 modes, so related features share one gesture set:

| Mode | Covers | Tap | Double tap |
|---|---|---|---|
| **Explore** | object recognition, scene description | describe the whole scene | pause/resume live object announcements |
| **Obstacle alerts** | obstacle alerts | is the path clear? | pause/resume |
| **Read text** | text reading | photo + read page in reading order (tap again to stop) | quick live reading of short signs/labels |
| **Currency** | PKR note detection (your YOLO11n model) | count all notes in view + total | add note to running total |
| **Color & clothing** | color detection, clothing assistance | color at center | describe garment (colors, plain/mixed, saved item) |
| **People** | saved person recognition | who is here | save a new person |
| **My objects** | saved object recognition ("find my keys") | choose object to find (beeps speed up as you get closer) | save a new object |
| **Places** | indoor landmark navigation | where am I | save this spot as a landmark |
| **Calls** | voice-assisted calling (ported from your app) | call a contact by name | call back last person |
| **Emergency** | emergency information, SOS | SOS: 5 s countdown, then SMS with GPS location + call | read medical info aloud |
| **Activity log** | local activity logs | latest entries | today's summary |

**Voice guidance** is everywhere rather than a separate mode: each mode speaks its name
and a hint when opened (full hints the first times, or always in verbose mode),
"help" explains the current mode, "tutorial" replays the walkthrough, and every
state change is spoken.

### Gestures (anywhere on the screen)

- **Swipe left / right**: next / previous mode
- **Tap / double tap**: the mode's two main actions (see table)
- **Press and hold**: voice command after the beep
- **Swipe up**: repeat last speech. **Swipe down**: stop speaking
- **Shake hard 3 times**: emergency SOS (can be turned off: "shake off")
- With **TalkBack** on, raw gestures go to the screen reader, so the app shows large
  labelled buttons instead (actions, previous/next mode, voice command, repeat).

During a call the whole screen becomes one button: tap to answer or hang up.

### Voice commands (examples)

"what's in front of me", "describe the scene", "read this", "how much money is this",
"what color is this", "does this match", "light", "who is here", "save this person as Sara",
"find my keys", "save this as my wallet", "where did I leave my keys", "where am I",
"save this place as kitchen", "record route to bedroom", "take me to the kitchen",
"stop navigation", "call Ahmed", "emergency" / "help me", "read my medical information",
"add emergency contact", "set up emergency", "alarm", "what did I do today",
"clear history", "what time is it", "date", "repeat", "speak faster/slower", "brief"/"verbose",
"flashlight", "clock directions", "vibration off", "permissions", "help", "tutorial", or a mode name.

The active mode gets each command first (e.g. "reset total" in Currency); otherwise it is
routed to the right mode, which opens automatically. The parser is pure Dart
(`lib/core/commands.dart`) and unit tested.

## How each feature works offline

| Feature | On-device technology |
|---|---|
| Objects, obstacles | YOLO11n (COCO, 80 classes), TFLite, 320 px; pinhole distance estimate from typical object heights |
| Currency | your fine-tuned YOLO11n PKR model, exported to TFLite at 416 px (output verified identical to `best.pt`) |
| Scene description | YOLO11n objects + ML Kit image labeling (bundled model) + light level + dominant color + text presence, composed into sentences |
| Text | ML Kit text recognition (bundled Latin model), full-resolution still photo, reading order, framing hints ("move left", "move closer") |
| Color / clothing | CIELAB nearest-color naming (47 names), k-means dominant colors, outfit-matching rules, saved garments via image embeddings |
| People | ML Kit face detection + MobileFaceNet 192-d embeddings, roll-aligned crops, cosine matching with margin |
| My objects / places | MediaPipe MobileNetV3 image embedder (1024-d), several reference shots per item |
| Navigation | accelerometer step detector + tilt-compensated compass; routes recorded by walking once, reversed automatically, chained across landmarks |
| Speech | Android TTS (offline voices) and `speech_to_text` with `onDevice: true`, falling back to the standard recognizer |
| SOS | GPS (no data needed) + SMS via `SmsManager` + phone call |
| Storage | one local SQLite DB (`sqflite`): settings, activity log, face/object/place embeddings, routes |

All TensorFlow Lite models run in a long-lived background isolate
(`lib/core/vision/vision_worker.dart`); camera frames are dropped while it is busy so the
app always works on the freshest frame. Frames are sampled straight from NV21 into the
model input with rotation and letterboxing (`lib/core/vision/frame.dart`).

## Project layout

```
lib/
  main.dart
  shell/            app_controller.dart (modes, gestures, voice routing, SOS shake, permissions, tutorial)
                    home_screen.dart (full-screen UI, TalkBack controls, call overlay)
  core/             commands.dart, settings.dart, cues.dart (haptics + tones)
    camera/         camera_service.dart
    speech/         speaker.dart (TTS), listener.dart (offline-first STT)
    storage/        store.dart (SQLite)
    vision/         frame.dart, detection.dart, labels.dart, color_names.dart, embedding.dart,
                    announcer.dart, vision_worker.dart
    nav/            motion.dart (steps, compass), route.dart (record, guide, route graph)
  modules/          one file per mode; calls/ holds the ported call assistant
android/app/src/main/kotlin/com/blindassist/app/
  MainActivity.kt, CallInService.kt, CallEventBridge.kt, PhoneStateReceiver.kt  (from the call assistant)
  DeviceChannel.kt  (beeps, SMS, keep-screen-on)
assets/models/      coco_yolo11n, pkr_currency_yolo11n, image_embedder, face_embedder (.tflite, ~20 MB)
tools/export_models.py
```

## Build and run

```bash
flutter pub get
flutter test                 # 77 unit tests
flutter run --release        # on a physical Android phone (Android 8.0+)
```

First launch: the app asks for camera, microphone, contacts, phone, location and SMS
permissions (with spoken explanations), then plays a short tutorial. For incoming-call
announcements the app must be the default phone app; say "set up calls" in Calls mode.

For the best offline voice commands, install the offline English speech-recognition
pack (Settings, then Google, then Voice / Offline speech recognition, depending on the phone)
and an offline TTS voice.

## Changes to the original call assistant

- Moved from `lib/screens/dial_screen.dart` into `modules/calls/call_controller.dart` so an
  incoming call takes over the screen from any mode; behaviour (3 s ring before announcing,
  "answer"/"ignore", tap to answer, speakerphone, confirm before dialing) is unchanged.
- Removed the pre-warmed second `FlutterEngine` in `MainApplication`: MainActivity never
  attached to it, so `main()` ran twice in the background. Events are still buffered by
  `CallEventBridge`, and `CallInService` brings the activity to the front.
- `flutter_contacts` stays on 1.x (2.x changed the API); package renamed to `vision_assist`,
  Kotlin package to `com.blindassist.app`.

## Limitations and what to test on a device

- Not yet run on a phone: this build was compiled and unit-tested only. The vision
  pipeline (NV21 to tensor to YOLO decode) was checked against the real models and matches
  PyTorch outputs, but camera orientation, ML Kit coordinates and performance need a
  real-device pass. Thresholds to tune with real users: `PeopleModule.matchThreshold`
  (0.62), `ObjectsModule.threshold` (0.68), `PlacesModule.landmarkThreshold` (0.70).
- Obstacle alerts only know the 30 or so COCO obstacle classes. They do not see walls, steps,
  holes, glass or overhanging branches, so this is an aid next to a cane, not a replacement.
  A monocular depth model would be the next step.
- Step counting and compass headings drift, especially near metal and electronics; routes are
  guidance, not precise positioning.
- Text reading supports Latin scripts only (ML Kit has no Urdu model). For Urdu, add an Urdu
  OCR TFLite model, and an Urdu TTS voice for speech.
- Speech recognition offline depends on the phone having an on-device recognizer. If yours does
  not, a Vosk small English model (~40 MB) can replace `listener.dart` with no other changes.
- **Licensing**: YOLO11 weights and anything fine-tuned from them (including the PKR model)
  are AGPL-3.0 under Ultralytics' terms unless you hold an Ultralytics Enterprise licence.
  Check this before publishing on the Play Store. The embedders are Apache-2.0; ML Kit falls
  under Google's ML Kit terms.
