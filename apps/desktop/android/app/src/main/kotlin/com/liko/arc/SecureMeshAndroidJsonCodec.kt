package com.liko.arc

import org.json.JSONArray
import org.json.JSONObject

/** Product-safe JSON projection for the Flutter method-channel boundary. */
internal object SecureMeshAndroidJsonCodec {
    fun jsonObjectToMap(value: JSONObject): Map<String, Any?> {
        val output = linkedMapOf<String, Any?>()
        val keys = value.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            output[key] = jsonValueToPlatform(value.opt(key))
        }
        return output
    }

    private fun jsonValueToPlatform(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> List(value.length()) { index ->
            jsonValueToPlatform(value.opt(index))
        }
        else -> value
    }
}
