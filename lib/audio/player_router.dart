import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// Android : la lecture en arrière-plan (just_audio_background) n'accepte
/// qu'un seul lecteur. Le fondu enchaîné en demande un second, le temps de
/// jouer la fin du morceau qui s'éteint.
///
/// Cet aiguillage envoie le lecteur principal à just_audio_background
/// (notification, écran verrouillé) et le second lecteur directement au
/// moteur natif d'Android, qui accepte plusieurs lecteurs. Le second lecteur
/// se reconnaît à l'absence de réglage de mémoire tampon (le principal en a
/// toujours un).
class PlayerRouter extends JustAudioPlatform {
  final JustAudioPlatform background;
  final JustAudioPlatform native;
  final _nativeIds = <String>{};

  PlayerRouter({required this.background, required this.native});

  /// Vrai si [request] vient du second lecteur (fondu enchaîné).
  static bool isSecondary(InitRequest request) =>
      request.audioLoadConfiguration?.androidLoadControl == null;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) {
    if (isSecondary(request)) {
      _nativeIds.add(request.id);
      return native.init(request);
    }
    return background.init(request);
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) =>
      _nativeIds.remove(request.id)
      ? native.disposePlayer(request)
      : background.disposePlayer(request);

  // Appelé une seule fois, au démarrage de l'application (avant tout second
  // lecteur) : seul just_audio_background est concerné.
  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) {
    _nativeIds.clear();
    return background.disposeAllPlayers(request);
  }
}
