package land.lico.licoup

import java.security.MessageDigest
import java.util.Base64

internal object ReleaseClosureBinding {
    private val encodedValuePattern = Regex("^[A-Za-z0-9_-]{43}$")

    fun digest(value: String): String {
        if (!encodedValuePattern.matches(value)) return ""
        return try {
            val decoded = Base64.getUrlDecoder().decode(value)
            val canonical = Base64.getUrlEncoder().withoutPadding().encodeToString(decoded)
            if (decoded.size != 32 || canonical != value) {
                ""
            } else {
                val digest = MessageDigest.getInstance("SHA-256")
                    .digest(value.toByteArray(Charsets.US_ASCII))
                    .joinToString("") { "%02x".format(it.toInt() and 0xff) }
                "sha256:$digest"
            }
        } catch (_: IllegalArgumentException) {
            ""
        }
    }
}
