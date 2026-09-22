import 'package:flutter/material.dart';

import 'app_state.dart';
import 'theme.dart';
import '../ui/widget/token_dock_widget.dart';

class TokenDockApp extends StatelessWidget {
  const TokenDockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: TokenDockTheme.lightTheme(),
      darkTheme: TokenDockTheme.darkTheme(),
      home: const Scaffold(
        body: TokenDockWidget(state: AppState.loading()),
      ),
    );
  }
}
