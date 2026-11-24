package app.jellymusic

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Garde l'application active pendant les téléchargements, même en arrière-plan
 * ou écran éteint : service de premier plan avec une notification silencieuse
 * qui montre la progression. Le téléchargement lui-même est fait par le code
 * Dart ; ce service ne fait qu'afficher la notification et empêcher Android
 * d'endormir ou d'arrêter l'application.
 */
class DownloadService : Service() {
    companion object {
        const val CHANNEL_ID = "app.jellymusic.downloads"
        const val NOTIF_ID = 4201
        const val DONE_NOTIF_ID = 4202
        const val ACTION_UPDATE = "update"
        const val ACTION_STOP = "stop"
        const val ACTION_CANCEL = "cancel" // bouton « Arrêter » de la notification

        /** Service en marche (pour mettre la notification à jour sans le relancer). */
        var instance: DownloadService? = null

        /** Appelé quand l'utilisateur touche « Arrêter » dans la notification. */
        var onCancelRequested: (() -> Unit)? = null

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Téléchargements",
                NotificationManager.IMPORTANCE_LOW, // sans son ni vibration
            )
            ch.description = "Progression des téléchargements de musique"
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var started = false
    private val handler = Handler(Looper.getMainLooper())

    // Sécurité : si l'application ne donne plus de nouvelles (fermée de
    // force), la notification ne reste pas affichée indéfiniment.
    private val watchdog = Runnable { stopEverything() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> {
                onCancelRequested?.invoke()
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
        }
        val title = intent?.getStringExtra("title") ?: "Téléchargement"
        val text = intent?.getStringExtra("text") ?: ""
        val progress = intent?.getIntExtra("progress", 0) ?: 0
        val max = intent?.getIntExtra("max", 0) ?: 0
        update(title, text, progress, max)
        return START_NOT_STICKY
    }

    /** Met à jour la notification (et démarre le premier plan la première fois). */
    fun update(title: String, text: String, progress: Int, max: Int) {
        val notif = build(title, text, progress, max)
        if (!started) {
            ensureChannel(this)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIF_ID, notif)
            }
            acquireLocks()
            started = true
        } else {
            getSystemService(NotificationManager::class.java).notify(NOTIF_ID, notif)
        }
        handler.removeCallbacks(watchdog)
        handler.postDelayed(watchdog, 3 * 60 * 1000L)
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    private fun build(title: String, text: String, progress: Int, max: Int): Notification {
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val cancel = PendingIntent.getService(
            this,
            1,
            Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setProgress(max, progress, max <= 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setContentIntent(open)
            .addAction(0, "Arrêter", cancel)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun acquireLocks() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "JellyMusic:downloads").apply {
            setReferenceCounted(false)
            acquire(6 * 60 * 60 * 1000L)
        }
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "JellyMusic:downloads").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    fun stopEverything() {
        handler.removeCallbacks(watchdog)
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock = null
        started = false
        if (instance === this) instance = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // Android 15 : limite de temps des services de synchronisation atteinte.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopEverything()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        handler.removeCallbacks(watchdog)
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}
