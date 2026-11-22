import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'state/player_controller.dart';
import 'state/playlist_store.dart';
import 'state/session.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';
import 'update/update_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    // Lecture en arrière-plan, notification et contrôles sur l'écran verrouillé.
    await JustAudioBackground.init(
      androidNotificationChannelId: 'app.jellymusic.audio',
      androidNotificationChannelName: 'Lecture de musique',
      androidNotificationOngoing: true,
    );
  }
  final session = Session();
  await session.load();
  runApp(JellyMusicApp(session: session));
}

class JellyMusicApp extends StatelessWidget {
  final Session session;
  const JellyMusicApp({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider(create: (_) => PlayerController(session)),
        ChangeNotifierProvider(create: (_) => PlaylistStore(session)),
      ],
      child: MaterialApp(
        title: 'JellyMusic',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF7C4DFF),
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
        home: _StartupUpdateCheck(
          child: Consumer<Session>(
            builder: (_, s, __) => s.isLoggedIn
                ? const HomeScreen(key: ValueKey('home'))
                : const LoginScreen(key: ValueKey('login')),
          ),
        ),
      ),
    );
  }
}

/// Vérifie une seule fois, au démarrage, si une nouvelle version existe sur
/// GitHub. Silencieux s'il n'y en a pas ou si le réseau ne répond pas.
class _StartupUpdateCheck extends StatefulWidget {
  final Widget child;
  const _StartupUpdateCheck({required this.child});

  @override
  State<_StartupUpdateCheck> createState() => _StartupUpdateCheckState();
}

class _StartupUpdateCheckState extends State<_StartupUpdateCheck> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) checkForUpdates(context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
