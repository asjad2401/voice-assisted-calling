import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/commands.dart';
import '../core/vision/detection.dart';
import 'calls/call_controller.dart';
import 'calls/contacts_service.dart';
import 'module.dart';

class EmergencyContact {
  final String name;
  final String number;
  const EmergencyContact(this.name, this.number);
  Map<String, String> toJson() => {'name': name, 'number': number};
}

/// Medical and contact details kept on the phone for emergencies.
class EmergencyProfile {
  String name = '';
  String bloodGroup = '';
  String conditions = '';
  String allergies = '';
  String medications = '';
  String notes = '';
  List<EmergencyContact> contacts = [];

  bool get isEmpty =>
      name.isEmpty &&
      bloodGroup.isEmpty &&
      conditions.isEmpty &&
      allergies.isEmpty &&
      medications.isEmpty &&
      notes.isEmpty;

  Map<String, dynamic> toJson() => {
        'name': name,
        'blood': bloodGroup,
        'conditions': conditions,
        'allergies': allergies,
        'meds': medications,
        'notes': notes,
        'contacts': contacts.map((c) => c.toJson()).toList(),
      };

  static EmergencyProfile fromJson(Map<String, dynamic> m) => EmergencyProfile()
    ..name = m['name'] as String? ?? ''
    ..bloodGroup = m['blood'] as String? ?? ''
    ..conditions = m['conditions'] as String? ?? ''
    ..allergies = m['allergies'] as String? ?? ''
    ..medications = m['meds'] as String? ?? ''
    ..notes = m['notes'] as String? ?? ''
    ..contacts = ((m['contacts'] as List?) ?? [])
        .map((c) => EmergencyContact((c as Map)['name'] as String, c['number'] as String))
        .toList();

  /// Spoken / displayed summary for first responders.
  String summary() {
    final p = <String>[];
    if (name.isNotEmpty) p.add('Name: $name.');
    p.add('I am blind or visually impaired.');
    if (bloodGroup.isNotEmpty) p.add('Blood group: $bloodGroup.');
    if (conditions.isNotEmpty) p.add('Medical conditions: $conditions.');
    if (allergies.isNotEmpty) p.add('Allergies: $allergies.');
    if (medications.isNotEmpty) p.add('Medications: $medications.');
    if (notes.isNotEmpty) p.add('Notes: $notes.');
    if (contacts.isNotEmpty) {
      p.add('Emergency contacts: ${joinSpoken(contacts.map((c) => '${c.name}, ${c.number}').toList())}.');
    }
    return p.join(' ');
  }
}

/// Builds the SOS text message.
String sosMessage(EmergencyProfile p, {double? lat, double? lng, double? accuracyM, DateTime? at}) {
  final who = p.name.isEmpty ? 'I' : p.name;
  final b = StringBuffer('EMERGENCY: $who need${p.name.isEmpty ? '' : 's'} help. ');
  if (lat != null && lng != null) {
    b.write('Location: https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}');
    if (accuracyM != null) b.write(' (within about ${accuracyM.round()} m)');
    b.write('. ');
  } else {
    b.write('Location unavailable. ');
  }
  if (p.bloodGroup.isNotEmpty) b.write('Blood group ${p.bloodGroup}. ');
  if (p.conditions.isNotEmpty) b.write('Conditions: ${p.conditions}. ');
  final t = at ?? DateTime.now();
  b.write('Sent ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} by Life Lense.');
  return b.toString();
}

/// SOS alerts (SMS with GPS location + phone call, no internet needed),
/// a loud alarm, and the medical information card.
class EmergencyModule extends AssistModule {
  @override
  String get id => 'emergency';
  @override
  String get title => 'Emergency';
  @override
  IconData get icon => Icons.emergency;
  @override
  Color get color => const Color(0xFF7F1D1D);
  @override
  String get hint =>
      'Tap to send an emergency alert to your contacts. Double tap to read your medical information. Say "set up emergency" to add contacts and details.';
  @override
  String get help =>
      'Emergency mode. Tap to start an SOS: after a 5 second countdown, which you can cancel by tapping, I send a text message with your GPS location to your emergency contacts and then call the first one. This works without internet; it needs mobile signal. '
      'You can also say "emergency" or "help me" from any mode, or shake the phone hard three times. '
      'Double tap to read your medical information aloud for a helper; it is also shown in large text. Say "alarm" to sound a loud alarm. '
      'Say "add emergency contact" or "set up medical information" to fill in your details.';
  @override
  String get tapLabel => _countdown != null ? 'Cancel SOS' : 'Send SOS';
  @override
  String get doubleTapLabel => 'Read medical information';

  @override
  bool get usesCamera => false;

  static const _device = MethodChannel('vision_assist/device');

  EmergencyProfile profile = EmergencyProfile();
  Timer? _countdown;
  bool _alarm = false;

  Future<void> load() async {
    final m = await store.getJson('emergency');
    if (m != null) profile = EmergencyProfile.fromJson(m);
  }

  Future<void> _save() => store.setJson('emergency', profile.toJson());

  @override
  Future<void> onEnter() async {
    await load();
    status = profile.isEmpty && profile.contacts.isEmpty
        ? 'No emergency details yet. Say "set up emergency".'
        : profile.summary();
  }

  @override
  Future<void> onExit() async {
    _alarm = false;
  }

  @override
  Future<void> onTap() async {
    if (_alarm) {
      _alarm = false;
      return say('Alarm off.');
    }
    if (_countdown != null) return cancelSos();
    await startSos();
  }

  /// Starts the cancellable countdown. Can be called from any mode.
  Future<void> startSos() async {
    if (_countdown != null) return;
    await load();
    if (profile.contacts.isEmpty) {
      await say('No emergency contacts are set. I will call Rescue 1122 instead. Tap to cancel.');
    }
    int left = 5;
    status = 'SOS in $left… tap to cancel';
    cues.error();
    await say('Sending emergency alert in 5 seconds. Tap the screen to cancel.');
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) async {
      left--;
      if (left > 0) {
        status = 'SOS in $left… tap to cancel';
        cues.beep(frequency: 1000, durationMs: 150, volume: 1);
        return;
      }
      t.cancel();
      _countdown = null;
      await _sendSos();
    });
  }

  Future<void> cancelSos() async {
    _countdown?.cancel();
    _countdown = null;
    status = 'SOS cancelled';
    await say('Emergency alert cancelled.');
  }

  bool get countingDown => _countdown != null;

  Future<void> _sendSos() async {
    status = 'Sending SOS…';
    await say('Sending alert.');
    double? lat, lng, acc;
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm != LocationPermission.denied && perm != LocationPermission.deniedForever) {
        Position? pos;
        try {
          pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)),
          );
        } catch (_) {
          pos = await Geolocator.getLastKnownPosition();
        }
        if (pos != null) {
          lat = pos.latitude;
          lng = pos.longitude;
          acc = pos.accuracy;
        }
      }
    } catch (_) {}
    final msg = sosMessage(profile, lat: lat, lng: lng, accuracyM: acc);
    int sent = 0;
    if (profile.contacts.isNotEmpty && await Permission.sms.request().isGranted) {
      for (final c in profile.contacts) {
        try {
          await _device.invokeMethod('sendSms', {'number': c.number, 'text': msg});
          sent++;
        } catch (_) {}
      }
    }
    await log('emergency', 'SOS sent to $sent contacts${lat != null ? ' with location' : ' without location'}');
    final first = profile.contacts.isNotEmpty ? profile.contacts.first : const EmergencyContact('Rescue 1122', '1122');
    status = 'SOS sent to $sent. Calling ${first.name}.';
    await say('${sent > 0 ? 'Alert sent to $sent ${sent == 1 ? 'contact' : 'contacts'}. ' : ''}Calling ${first.name}.');
    await CallController.instance.placeCall(first.name, first.number);
  }

  @override
  Future<void> onDoubleTap() async {
    await load();
    if (profile.isEmpty) {
      return say('No medical information saved. Say "set up medical information" to add it.');
    }
    status = profile.summary();
    await say(profile.summary());
  }

  Future<void> addContact() async {
    final heard = await host.ask('Say the name of the contact to add.');
    if (heard == null) return say('I did not hear a name.');
    final m = await ContactsService.instance.findBestMatchAsync(heard);
    if (m == null) return say('I could not find $heard in your contacts.');
    if (!await host.confirm('Add ${m.displayName} as an emergency contact?')) return say('Not added.');
    profile.contacts.removeWhere((c) => c.number == m.phoneNumber);
    profile.contacts.add(EmergencyContact(m.displayName, m.phoneNumber));
    await _save();
    await say(
        'Added ${m.displayName}. You have ${profile.contacts.length} emergency ${profile.contacts.length == 1 ? 'contact' : 'contacts'}.');
  }

  Future<void> setupMedical() async {
    Future<String?> field(String prompt, String current) async {
      final ans = await host.ask(current.isEmpty
          ? '$prompt Say skip to leave it empty.'
          : '$prompt Currently: $current. Say skip to keep it.');
      if (ans == null || RegExp(r'^\s*(skip|next|keep|none)\s*$', caseSensitive: false).hasMatch(ans)) return null;
      return ans.trim();
    }

    profile.name = await field('What is your full name?', profile.name) ?? profile.name;
    profile.bloodGroup = await field('What is your blood group?', profile.bloodGroup) ?? profile.bloodGroup;
    profile.conditions = await field('Any medical conditions?', profile.conditions) ?? profile.conditions;
    profile.allergies = await field('Any allergies?', profile.allergies) ?? profile.allergies;
    profile.medications = await field('Any regular medications?', profile.medications) ?? profile.medications;
    profile.notes =
        await field('Anything else a helper should know, such as your home address?', profile.notes) ?? profile.notes;
    await _save();
    status = profile.summary();
    await say('Saved. ${profile.contacts.isEmpty ? 'Now say "add emergency contact".' : ''}');
  }

  Future<void> toggleAlarm() async {
    _alarm = !_alarm;
    if (!_alarm) return say('Alarm off.');
    await say('Alarm on. Tap to stop.');
    while (_alarm && active) {
      await cues.beep(frequency: 2000, durationMs: 300, volume: 1);
      await Future.delayed(const Duration(milliseconds: 120));
      await cues.beep(frequency: 1400, durationMs: 300, volume: 1);
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  @override
  Future<bool> handle(Command c) async {
    final raw = normalizeUtterance(c.raw);
    if (raw.contains('alarm') || raw.contains('siren')) {
      await toggleAlarm();
      return true;
    }
    if (raw.contains('emergency contact') || raw.contains('add contact')) {
      await addContact();
      return true;
    }
    if (raw.contains('set up') ||
        raw.contains('setup') ||
        raw.contains('edit medical') ||
        raw.contains('medical information') && raw.contains('set')) {
      await setupMedical();
      if (profile.contacts.isEmpty) await addContact();
      return true;
    }
    switch (c.intent) {
      case VoiceIntent.emergency:
        await startSos();
        return true;
      case VoiceIntent.medicalInfo:
        await onDoubleTap();
        return true;
      case VoiceIntent.cancel:
      case VoiceIntent.no:
      case VoiceIntent.stop:
        if (_countdown != null) {
          await cancelSos();
          return true;
        }
        if (_alarm) {
          _alarm = false;
          return true;
        }
        return false;
      default:
        return false;
    }
  }
}
