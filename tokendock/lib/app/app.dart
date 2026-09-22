import 'package:flutter/material.dart';

class TokenDockApp extends StatelessWidget {
  const TokenDockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Text('TokenDock'),
        ),
      ),
    );
  }
}
