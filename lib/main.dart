import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'shell/app_controller.dart';
import 'shell/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(VisionAssistApp(controller: AppController()));
}

class VisionAssistApp extends StatelessWidget {
  final AppController controller;
  const VisionAssistApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Life Lense',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: HomeScreen(controller: controller),
    );
  }
}
