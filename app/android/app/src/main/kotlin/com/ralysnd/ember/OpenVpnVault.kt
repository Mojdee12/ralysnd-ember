package com.ralysnd.ember

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Saved OpenVPN credentials, encrypted at rest (build 2025).
 *
 * A profile's username/password live in an app-private file
 * (filesDir/openvpn/vault/<key>.json) as AES-256-GCM ciphertext
 * under a key held by the Android Keystore — the plaintext
 * never touches the app's JSON stores, and a save that cannot
 * encrypt FAILS rather than falling back to plaintext. Keys are
 * profile ids, plus the shared "tunnelbear" entry the 47
 * built-in TunnelBear profiles authenticate against.
 */
object OpenVpnVault {
    private const val KEY_ALIAS = "ember_openvpn_vault"
    private const val TRANSFORM = "AES/GCM/NoPadding"

    private fun dir(context: Context): File =
        File(context.filesDir, "openvpn/vault").apply { mkdirs() }

    private fun file(context: Context, key: String): File {
        // Profile ids are app-generated slugs; keep the file
        // name to a safe subset regardless.
        val safe = key.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(dir(context), "$safe.json")
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    /** Saves (or replaces) the credentials for [key]. Throws on failure. */
    fun save(context: Context, key: String, username: String, password: String) {
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val plain = JSONObject()
            .put("u", username)
            .put("p", password)
            .toString()
            .toByteArray(Charsets.UTF_8)
        val sealed = cipher.doFinal(plain)
        val doc = JSONObject()
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("data", Base64.encodeToString(sealed, Base64.NO_WRAP))
        val target = file(context, key)
        // Build 2071 (review §5.2): through AtomicFile —
        // write + flush + fsync, then rename. The old
        // writeText-then-rename had a power-loss window that
        // could rename a zero-length vault over the good one,
        // losing the credentials it was saving. A failure
        // still throws, as this save always promised.
        AtomicFile.writeText(target, doc.toString())
    }

    /** The stored pair for [key], or null when none is saved. */
    fun load(context: Context, key: String): Pair<String, String>? {
        val target = file(context, key)
        if (!target.exists()) return null
        return try {
            val doc = JSONObject(target.readText())
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(128, Base64.decode(doc.getString("iv"), Base64.NO_WRAP)),
            )
            val plain = cipher.doFinal(Base64.decode(doc.getString("data"), Base64.NO_WRAP))
            val pair = JSONObject(String(plain, Charsets.UTF_8))
            pair.getString("u") to pair.getString("p")
        } catch (_: Exception) {
            // A store that cannot be decrypted (key rotated by a
            // reinstall, file damaged) reads as "no credentials",
            // and the connect flow asks again.
            null
        }
    }

    fun has(context: Context, key: String): Boolean = file(context, key).exists()

    fun delete(context: Context, key: String) {
        file(context, key).delete()
    }

    // Build 2116 (E-7): generic single-value secrets under
    // the same Keystore key — the GitHub sync token's home
    // now, instead of the plaintext app-settings document.
    // Their own directory, so a secret's file name can
    // never collide with a credential entry's.
    private fun secretFile(context: Context, key: String): File {
        val safe = key.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(
            File(context.filesDir, "secrets").apply { mkdirs() },
            "$safe.json",
        )
    }

    /** Saves (or replaces) the secret for [key]. Throws on failure. */
    fun saveSecret(context: Context, key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val plain = JSONObject()
            .put("v", value)
            .toString()
            .toByteArray(Charsets.UTF_8)
        val sealed = cipher.doFinal(plain)
        val doc = JSONObject()
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("data", Base64.encodeToString(sealed, Base64.NO_WRAP))
        AtomicFile.writeText(secretFile(context, key), doc.toString())
    }

    /** The stored secret for [key], or null when none is
     *  saved (or it cannot be decrypted on this device). */
    fun loadSecret(context: Context, key: String): String? {
        val target = secretFile(context, key)
        if (!target.exists()) return null
        return try {
            val doc = JSONObject(target.readText())
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(128, Base64.decode(doc.getString("iv"), Base64.NO_WRAP)),
            )
            val plain = cipher.doFinal(Base64.decode(doc.getString("data"), Base64.NO_WRAP))
            JSONObject(String(plain, Charsets.UTF_8)).optString("v")
        } catch (_: Exception) {
            null
        }
    }

    fun deleteSecret(context: Context, key: String) {
        secretFile(context, key).delete()
    }

    /**
     * What the store can actually prove about an entry
     * (build 2027). NONE: nothing stored. OK: the stored
     * payload decrypts to a credential pair. UNREADABLE: a
     * payload exists but cannot be decrypted on this device
     * (keystore key rotated or lost, file damaged) — a state
     * build 2026 could not distinguish from OK: its "saved"
     * checks keyed on file existence only, so an unreadable
     * entry read as saved in the UI and as EMPTY credentials
     * in the connect flow.
     */
    enum class CredStatus { NONE, OK, UNREADABLE }

    fun status(context: Context, key: String): CredStatus {
        if (!file(context, key).exists()) return CredStatus.NONE
        val pair = load(context, key)
        return if (pair != null && pair.first.isNotEmpty()) {
            CredStatus.OK
        } else {
            CredStatus.UNREADABLE
        }
    }

    /**
     * Drops an entry AND the master key, so the next save
     * starts from a clean vault (self-healing, build 2027):
     * the coherent explanation for an entry that exists but
     * cannot be decrypted is a keystore key that was
     * invalidated or lost after the entry was written —
     * deleting only the file would leave the same broken
     * key in place for the rewrite.
     */
    private fun heal(context: Context, key: String) {
        try {
            file(context, key).delete()
        } catch (_: Exception) {
        }
        try {
            val ks = KeyStore.getInstance("AndroidKeyStore")
            ks.load(null)
            if (ks.containsAlias(KEY_ALIAS)) ks.deleteEntry(KEY_ALIAS)
        } catch (_: Exception) {
        }
    }

    /**
     * Saves and then proves it: the entry is read back and
     * decrypted, and only an exact round-trip counts as
     * saved. Any failure — encrypt, write, or read-back —
     * returns false instead of letting the UI claim a save
     * that the connect flow would never see.
     *
     * If the first attempt fails, the vault heals itself
     * (entry + master key wiped, key regenerated) and the
     * save is retried once before giving up — that is what
     * rescues a device whose keystore key was invalidated
     * under a carried-over entry (the build-2026 field
     * state). Reads never heal: [status] reports UNREADABLE
     * and the UI says so, rather than a read silently
     * erasing the entry and the evidence with it.
     */
    fun saveVerified(
        context: Context,
        key: String,
        username: String,
        password: String,
    ): Boolean {
        fun attempt(): Boolean = try {
            save(context, key, username, password)
            val back = load(context, key)
            back != null && back.first == username && back.second == password
        } catch (_: Exception) {
            false
        }
        if (attempt()) return true
        heal(context, key)
        return attempt()
    }
}
