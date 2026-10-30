package net.geraldhofbauer.chattr

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * Checks a downloaded update APK before it goes to the system installer
 * (CHAT-40): same package name, same signing certificate and a higher
 * versionCode than the app that is running.
 *
 * The update manifest carries the APK address and its sha256 side by side, so
 * whoever can change the manifest (CMS, ingest token, Cloudflare, DNS) could
 * point both at an app of their own, and Chattr would hand it to the installer
 * under its "install unknown apps" permission. The running app's own
 * certificate is the anchor: nothing in the manifest can change that.
 */
object ApkVerifierChannel {
    private const val CHANNEL = "net.geraldhofbauer.chattr/apk_verify"

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "verify" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.success(mapOf("ok" to false, "reason" to "no path"))
                    } else {
                        result.success(verify(context, path))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun verify(context: Context, path: String): Map<String, Any?> {
        return try {
            val pm = context.packageManager
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                @Suppress("DEPRECATION")
                PackageManager.GET_SIGNATURES
            }
            val archive = pm.getPackageArchiveInfo(path, flags)
                ?: return mapOf("ok" to false, "reason" to "unreadable")
            if (archive.packageName != context.packageName) {
                return mapOf("ok" to false, "reason" to "package ${archive.packageName}")
            }
            val own = pm.getPackageInfo(context.packageName, flags)
            val theirs = certificates(archive)
            val mine = certificates(own)
            if (theirs.isEmpty() || theirs != mine) {
                return mapOf("ok" to false, "reason" to "certificate")
            }
            if (versionCode(archive) <= versionCode(own)) {
                return mapOf("ok" to false, "reason" to "not newer")
            }
            mapOf("ok" to true, "reason" to null)
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: e.javaClass.simpleName))
        }
    }

    /** SHA-256 of every signing certificate, as a set. */
    private fun certificates(info: PackageInfo): Set<String> {
        val raw = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return emptySet()
            if (signing.hasMultipleSigners()) {
                signing.apkContentsSigners
            } else {
                signing.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            info.signatures
        } ?: return emptySet()
        val digest = MessageDigest.getInstance("SHA-256")
        return raw.map { sig ->
            digest.digest(sig.toByteArray()).joinToString("") { "%02x".format(it) }
        }.toSet()
    }

    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
}
