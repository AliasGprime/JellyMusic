package app.jellymusic

import com.ryanheise.audioservice.AudioService
import java.lang.reflect.Modifier

/**
 * Application retirée des applications récentes (glissée) : le service de
 * lecture (audio_service) le signale, mais just_audio_background n'en fait
 * rien, et l'application restait active en arrière-plan après avoir joué
 * de la musique.
 *
 * On intercepte ce signal en enveloppant l'écouteur du service : le
 * signal continue d'arriver à audio_service, puis [onRemoved] est appelé.
 */
object TaskRemovedHook {
    var onRemoved: (() -> Unit)? = null

    private class Wrapper(
        val inner: AudioService.ServiceListener,
    ) : AudioService.ServiceListener by inner {
        override fun onTaskRemoved() {
            inner.onTaskRemoved()
            onRemoved?.invoke()
        }
    }

    /** Installe le crochet (à appeler une fois le service configuré). */
    fun install(): Boolean {
        // Champ privé et statique de AudioService : cherché par son type (le
        // nom peut être raccourci à la compilation).
        val field = AudioService::class.java.declaredFields.firstOrNull {
            Modifier.isStatic(it.modifiers) &&
                it.type == AudioService.ServiceListener::class.java
        } ?: return false
        field.isAccessible = true
        val current = field.get(null) as? AudioService.ServiceListener ?: return false
        if (current is Wrapper) return true
        AudioService.init(Wrapper(current))
        return true
    }
}
