package app.jellymusic

import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity permet à la lecture de continuer en arrière-plan.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.jellymusic/downloads",
        )
        // Bouton « Arrêter » de la notification → le code Dart arrête tout.
        DownloadService.onCancelRequested = {
            runOnUiThread { channel.invokeMethod("cancel", null) }
        }
        channel.setMethodCallHandler { call, result ->
            val ctx = applicationContext
            when (call.method) {
                "update" -> {
                    val running = DownloadService.instance
                    if (running != null) {
                        running.update(
                            call.argument<String>("title") ?: "",
                            call.argument<String>("text") ?: "",
                            call.argument<Int>("progress") ?: 0,
                            call.argument<Int>("max") ?: 0,
                        )
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    val i = Intent(ctx, DownloadService::class.java)
                        .setAction(DownloadService.ACTION_UPDATE)
                        .putExtra("title", call.argument<String>("title"))
                        .putExtra("text", call.argument<String>("text"))
                        .putExtra("progress", call.argument<Int>("progress") ?: 0)
                        .putExtra("max", call.argument<Int>("max") ?: 0)
                    try {
                        ContextCompat.startForegroundService(ctx, i)
                        result.success(true)
                    } catch (e: Exception) {
                        // Android peut refuser de démarrer le service si
                        // l'application est déjà en arrière-plan.
                        result.success(false)
                    }
                }
                "stop" -> {
                    DownloadService.instance?.stopEverything()
                    result.success(null)
                }
                "done" -> {
                    // Résumé silencieux une fois la série terminée.
                    DownloadService.ensureChannel(ctx)
                    val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
                        android.app.PendingIntent.getActivity(
                            ctx, 0, it, android.app.PendingIntent.FLAG_IMMUTABLE,
                        )
                    }
                    val n = NotificationCompat.Builder(ctx, DownloadService.CHANNEL_ID)
                        .setSmallIcon(android.R.drawable.stat_sys_download_done)
                        .setContentTitle(call.argument<String>("title"))
                        .setContentText(call.argument<String>("text"))
                        .setSilent(true)
                        .setAutoCancel(true)
                        .setContentIntent(open)
                        .build()
                    try {
                        NotificationManagerCompat.from(ctx)
                            .notify(DownloadService.DONE_NOTIF_ID, n)
                    } catch (_: SecurityException) {
                        // Notifications refusées : rien à afficher.
                    }
                    result.success(null)
                }
                "askPermission" -> {
                    // Android 13 et plus : autorisation d'afficher la notification.
                    if (android.os.Build.VERSION.SDK_INT >= 33 &&
                        ContextCompat.checkSelfPermission(
                            this, android.Manifest.permission.POST_NOTIFICATIONS,
                        ) != android.content.pm.PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(
                            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 4203,
                        )
                    }
                    result.success(null)
                }
                "clearDone" -> {
                    NotificationManagerCompat.from(ctx).cancel(DownloadService.DONE_NOTIF_ID)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
