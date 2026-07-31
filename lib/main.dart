import 'package:flutter/material.dart';
import 'screens/dial_screen.dart';

void main() {
  runApp(const BlindCallAssistantApp());
}

class BlindCallAssistantApp extends StatelessWidget {
  const BlindCallAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Call Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const DialScreen(),
    );
  }
}
