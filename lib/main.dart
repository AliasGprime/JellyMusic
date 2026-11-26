import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:provider/provider.dart';

import 'audio/player_router.dart';
import 'state/download_store.dart';
import 'state/equalizer_store.dart';
import 'state/player_controller.dart';
import 'state/playlist_store.dart';
import 'state/session.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';
import 'ui/player_screen.dart';
import 'update/update_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final native = JustAudioPlatform.instance;
    // Lecture en arrière-plan, notification et contrôles sur l'écran verrouillé.
    await JustAudioBackground.init(
      androidNotificationChannelId: 'app.jellymusic.audio',
      androidNotificationChannelName: 'Lecture de musique',
      androidNotificationOngoing: true,
    );
    // Second lecteur du fondu enchaîné : directement au moteur natif.
    JustAudioPlatform.instance = PlayerRouter(
      background: JustAudioPlatform.instance,
      native: native,
    );
  }
  final session = Session();
  await session.load();
  final downloads = DownloadStore(session);
  await downloads.init();
  // Sans attendre : l'accueil affiche « Connexion au serveur… » en attendant,
  // puis le mode hors connexion si le serveur ne répond pas.
  session.checkServer();
  runApp(JellyMusicApp(session: session, downloads: downloads));
}

class JellyMusicApp extends StatelessWidget {
  final Session session;
  final DownloadStore downloads;
  const JellyMusicApp({
    super.key,
    required this.session,
    required this.downloads,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: downloads),
        ChangeNotifierProvider(
          create: (_) => PlayerController(session, downloads),
        ),
        ChangeNotifierProvider(create: (_) => PlaylistStore(session)),
        ChangeNotifierProvider(
          create: (_) => EqualizerStore(session),
          lazy: false, // applique l'égaliseur du compte dès le démarrage
        ),
      ],
      child: MaterialApp(
        scaffoldMessengerKey: messengerKey,
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

/// Pour afficher des messages courts depuis n'importe quel écran.
final messengerKey = GlobalKey<ScaffoldMessengerState>();

class _StartupUpdateCheckState extends State<_StartupUpdateCheck> {
  StreamSubscription<String>? _msgSub;

  @override
  void dispose() {
    _msgSub?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _msgSub = context.read<PlayerController>().messages.listen((m) {
      messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
    // En données mobiles, confirmation avant d'écouter en qualité originale.
    final pc = context.read<PlayerController>();
    pc.confirmOriginalOnMobile = (n) =>
        mounted ? showMobileDataDialog(context, n) : Future.value(false);
    // Wi-Fi perdu en pleine écoute en qualité originale.
    pc.confirmWifiLost = () =>
        mounted ? showWifiLostDialog(context) : Future.value(false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) checkForUpdates(context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
