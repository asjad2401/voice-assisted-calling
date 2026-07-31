import 'package:permission_handler/permission_handler.dart';
import 'call_platform.dart';
import 'tts_service.dart';

class OnboardingStatus {
  final bool hasContactsPermission;
  final bool hasMicrophonePermission;
  final bool hasPhonePermission;
  final bool isDefaultDialer;

  OnboardingStatus({
    required this.hasContactsPermission,
    required this.hasMicrophonePermission,
    required this.hasPhonePermission,
    required this.isDefaultDialer,
  });

  bool get hasBasicPermissions =>
      hasContactsPermission && hasMicrophonePermission && hasPhonePermission;

  bool get isFullyConfigured => hasBasicPermissions && isDefaultDialer;

  List<String> get missingPermissions {
    final list = <String>[];
    if (!hasContactsPermission) list.add('Contacts');
    if (!hasMicrophonePermission) list.add('Microphone');
    if (!hasPhonePermission) list.add('Phone');
    return list;
  }
}

/// Manages setup, permissions, and system calling role configuration.
class OnboardingService {
  OnboardingService._internal();
  static final OnboardingService instance = OnboardingService._internal();

  bool _hasPromptedDialerThisSession = false;

  /// Checks current permissions and default dialer status.
  Future<OnboardingStatus> checkStatus() async {
    final contacts = await Permission.contacts.isGranted;
    final mic = await Permission.microphone.isGranted;
    final phone = await Permission.phone.isGranted;
    final isDialer = await CallPlatform.instance.isDefaultDialer();

    return OnboardingStatus(
      hasContactsPermission: contacts,
      hasMicrophonePermission: mic,
      hasPhonePermission: phone,
      isDefaultDialer: isDialer,
    );
  }

  /// Runs onboarding ONLY if permissions are missing or if user explicitly initiates setup.
  /// Will NOT repeat startup voice lines if basic permissions are already granted.
  Future<bool> runSpokenOnboarding({bool forcePromptDialer = false}) async {
    var status = await checkStatus();

    // 1. Spoken welcome & permissions request ONLY if permissions are missing
    if (status.missingPermissions.isNotEmpty) {
      await TtsService.instance.speak(
        'Welcome to Call Assistant. We need permission to access your contacts, microphone, and phone calls. Please tap allow on the upcoming prompts.',
      );

      final permissionsToRequest = <Permission>[
        if (!status.hasContactsPermission) Permission.contacts,
        if (!status.hasMicrophonePermission) Permission.microphone,
        if (!status.hasPhonePermission) Permission.phone,
      ];

      await permissionsToRequest.request();
      status = await checkStatus();

      if (!status.hasBasicPermissions) {
        await TtsService.instance.speak(
          'Permissions were not granted. Please grant permissions in app settings for Call Assistant to work.',
        );
        return false;
      }
    }

    // 2. Default dialer setup request ONLY ONCE per session or when forced
    if (!status.isDefaultDialer && (!_hasPromptedDialerThisSession || forcePromptDialer)) {
      _hasPromptedDialerThisSession = true;
      await TtsService.instance.speak(
        'Please set Call Assistant as your default Phone app so it can answer incoming calls.',
      );

      await CallPlatform.instance.requestPhoneAccountSetup();
      await Future.delayed(const Duration(milliseconds: 1500));
      status = await checkStatus();
    }

    return status.hasBasicPermissions;
  }
}
