/* A native executable Agent for the LicoUp extension protocol, wire `extension.v1`.
 *
 * This is the smallest complete Agent written as a compiled program with no
 * runtime and no dependency, and it is deliberately not the reference
 * implementation: `sdk/agent-adapter/python/` is. The sample exists to show
 * that the contract is the wire, not the language. It implements the handshake
 * plus `agent.describe`, `agent.execute` and `agent.event`; it declares every
 * optional ability unsupported, which is a complete answer rather than a defect.
 *
 * Build:
 *
 *     cc -std=c11 -O2 -Wall -Wextra -o agent agent.c
 *
 * Then replay the recorded session:
 *
 *     ./agent < transcript.jsonl
 *
 * The JSON scanner below is intentionally a small structural one, not a
 * general parser: it walks one frame's own members, refuses anything it cannot
 * read, and never guesses a field out of a string value. Frames are bounded by
 * the negotiated bound; an oversize frame is a framing fault, not a buffer. A
 * request id is echoed in full inside a frame sized for it, and an id that
 * cannot be echoed as valid JSON or cannot fit the bound is refused with a
 * bounded `null` id rather than shortened or reflected.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PROTOCOL_MAJOR 1L
#define JSONRPC_VERSION "2.0"

#define OWN_MAX_FRAME_BYTES (64 * 1024)
#define MIN_MAX_FRAME_BYTES (4 * 1024)
#define MAX_MAX_FRAME_BYTES (8 * 1024 * 1024)

#define MAX_INVOCATION_REFERENCE_BYTES 160
#define MAX_DIAGNOSTIC_LINE_BYTES 8192
#define MAX_ADMITTED 64

/* The room a response is assumed to need beyond the echoed id itself, before
 * the frame is built. The negotiated bound is the real limit, and every frame
 * is checked against it again as it is written; this reserve only decides
 * whether the request is worth starting at all. */
#define RESPONSE_RESERVE_BYTES 512

#define AGENT_ID "dev.example.agent.sdk.native"

/* --- state ------------------------------------------------------------------ */

static size_t g_bound = OWN_MAX_FRAME_BYTES;
static int g_initialized = 0;
static long g_sequence = 0;
static char *g_admitted[MAX_ADMITTED];
static size_t g_admitted_count = 0;

static void log_line(const char *message) {
    size_t length = strlen(message);
    if (length > MAX_DIAGNOSTIC_LINE_BYTES) {
        length = MAX_DIAGNOSTIC_LINE_BYTES;
    }
    fwrite(message, 1, length, stderr);
    fputc('\n', stderr);
    fflush(stderr);
}

/* --- a bounded structural JSON scanner -------------------------------------- */

typedef struct {
    const char *key;
    size_t key_length;
    const char *value_start;
    const char *value_end;
    int is_string;
    const char *string_start;
    size_t string_length;
} member;

static const char *skip_whitespace(const char *p, const char *end) {
    while (p < end &&
           (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) {
        p++;
    }
    return p;
}

/* `p` points at an opening quote; returns the position after the closing quote. */
static const char *scan_string(const char *p, const char *end,
                               const char **start, size_t *length) {
    if (p >= end || *p != '"') {
        return NULL;
    }
    const char *content = p + 1;
    p = content;
    while (p < end) {
        if (*p == '\\') {
            p += 2;
            continue;
        }
        if (*p == '"') {
            *start = content;
            *length = (size_t)(p - content);
            return p + 1;
        }
        p++;
    }
    return NULL;
}

static const char *scan_value(const char *p, const char *end) {
    p = skip_whitespace(p, end);
    if (p >= end) {
        return NULL;
    }
    if (*p == '"') {
        const char *start;
        size_t length;
        return scan_string(p, end, &start, &length);
    }
    if (*p == '{' || *p == '[') {
        int depth = 0;
        while (p < end) {
            if (*p == '"') {
                const char *start;
                size_t length;
                p = scan_string(p, end, &start, &length);
                if (p == NULL) {
                    return NULL;
                }
                continue;
            }
            if (*p == '{' || *p == '[') {
                depth++;
            } else if (*p == '}' || *p == ']') {
                depth--;
                if (depth == 0) {
                    return p + 1;
                }
            }
            p++;
        }
        return NULL;
    }
    {
        const char *start = p;
        while (p < end && *p != ',' && *p != '}' && *p != ']' &&
               *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') {
            p++;
        }
        return p > start ? p : NULL;
    }
}

/* Fills up to `max` members of the object at `p`; returns the member count. */
static int object_members(const char *p, const char *end, member *out, int max) {
    int count = 0;
    p = skip_whitespace(p, end);
    if (p >= end || *p != '{') {
        return -1;
    }
    p++;
    for (;;) {
        p = skip_whitespace(p, end);
        if (p < end && *p == '}') {
            return count;
        }
        if (p >= end || *p != '"') {
            return -1;
        }
        const char *key;
        size_t key_length;
        p = scan_string(p, end, &key, &key_length);
        if (p == NULL) {
            return -1;
        }
        p = skip_whitespace(p, end);
        if (p >= end || *p != ':') {
            return -1;
        }
        p = skip_whitespace(p + 1, end);
        const char *value_start = p;
        const char *value_end = scan_value(p, end);
        if (value_end == NULL) {
            return -1;
        }
        if (count < max) {
            member *slot = &out[count];
            slot->key = key;
            slot->key_length = key_length;
            slot->value_start = value_start;
            slot->value_end = value_end;
            slot->is_string = (*value_start == '"');
            slot->string_start = NULL;
            slot->string_length = 0;
            if (slot->is_string) {
                (void)scan_string(value_start, value_end, &slot->string_start,
                                  &slot->string_length);
            }
        }
        count++;
        p = skip_whitespace(value_end, end);
        if (p < end && *p == ',') {
            p++;
            continue;
        }
        if (p < end && *p == '}') {
            return count;
        }
        return -1;
    }
}

static const member *find_member(const member *members, int count,
                                 const char *key) {
    size_t key_length = strlen(key);
    for (int index = 0; index < count; index++) {
        if (members[index].key_length == key_length &&
            memcmp(members[index].key, key, key_length) == 0) {
            return &members[index];
        }
    }
    return NULL;
}

static int member_long(const member *value, long *out) {
    if (value == NULL || value->is_string ||
        value->value_end <= value->value_start) {
        return -1;
    }
    char buffer[32];
    size_t length = (size_t)(value->value_end - value->value_start);
    if (length >= sizeof(buffer)) {
        return -1;
    }
    memcpy(buffer, value->value_start, length);
    buffer[length] = '\0';
    char *end = NULL;
    long parsed = strtol(buffer, &end, 10);
    if (end == NULL || *end != '\0') {
        return -1;
    }
    *out = parsed;
    return 0;
}

/* --- JSON string escaping --------------------------------------------------- */

static size_t escaped_length(const char *bytes, size_t length) {
    size_t total = 0;
    for (size_t index = 0; index < length; index++) {
        unsigned char byte = (unsigned char)bytes[index];
        if (byte == '"' || byte == '\\') {
            total += 2;
        } else if (byte < 0x20) {
            total += 6;
        } else {
            total += 1;
        }
    }
    return total;
}

static size_t escape_into(char *destination, const char *bytes, size_t length) {
    size_t out = 0;
    for (size_t index = 0; index < length; index++) {
        unsigned char byte = (unsigned char)bytes[index];
        switch (byte) {
            case '"':
                destination[out++] = '\\';
                destination[out++] = '"';
                break;
            case '\\':
                destination[out++] = '\\';
                destination[out++] = '\\';
                break;
            case '\b':
                destination[out++] = '\\';
                destination[out++] = 'b';
                break;
            case '\f':
                destination[out++] = '\\';
                destination[out++] = 'f';
                break;
            case '\n':
                destination[out++] = '\\';
                destination[out++] = 'n';
                break;
            case '\r':
                destination[out++] = '\\';
                destination[out++] = 'r';
                break;
            case '\t':
                destination[out++] = '\\';
                destination[out++] = 't';
                break;
            default:
                if (byte < 0x20) {
                    static const char *digits = "0123456789abcdef";
                    destination[out++] = '\\';
                    destination[out++] = 'u';
                    destination[out++] = '0';
                    destination[out++] = '0';
                    destination[out++] = digits[(byte >> 4) & 0x0F];
                    destination[out++] = digits[byte & 0x0F];
                } else {
                    destination[out++] = (char)byte;
                }
        }
    }
    return out;
}

static int hex_digit(char digit) {
    if (digit >= '0' && digit <= '9') {
        return digit - '0';
    }
    if (digit >= 'a' && digit <= 'f') {
        return digit - 'a' + 10;
    }
    if (digit >= 'A' && digit <= 'F') {
        return digit - 'A' + 10;
    }
    return -1;
}

/* --- request id tokens ------------------------------------------------------ */

/* Whether a raw string body stays valid JSON once the surrounding quotes are
 * present: no unescaped control byte and well-formed escapes. The scanner has
 * already found the closing quote; this keeps a token that is about to be
 * echoed from leaving as invalid JSON. */
static int json_string_body_is_valid(const char *body, size_t length) {
    size_t index = 0;
    while (index < length) {
        unsigned char byte = (unsigned char)body[index];
        if (byte < 0x20 || byte == '"') {
            return 0;
        }
        if (byte != '\\') {
            index++;
            continue;
        }
        if (index + 1 >= length) {
            return 0;
        }
        switch (body[index + 1]) {
            case '"':
            case '\\':
            case '/':
            case 'b':
            case 'f':
            case 'n':
            case 'r':
            case 't':
                index += 2;
                break;
            case 'u':
                if (index + 6 > length) {
                    return 0;
                }
                for (int digit = 0; digit < 4; digit++) {
                    if (hex_digit(body[index + 2 + digit]) < 0) {
                        return 0;
                    }
                }
                index += 6;
                break;
            default:
                return 0;
        }
    }
    return 1;
}

/* Whether a raw number token is a finite JSON number. `Infinity`, `NaN`, `+1`
 * and `01` are not JSON numbers, and a token such as `1e999` denotes a value
 * no JSON reader represents; echoing any of them would put a value on the wire
 * the host cannot hold, so they are refused. */
static int json_number_token_is_valid(const char *token, size_t length) {
    size_t index = 0;
    if (index < length && token[index] == '-') {
        index++;
    }
    if (index >= length) {
        return 0;
    }
    if (token[index] == '0') {
        index++;
    } else if (token[index] >= '1' && token[index] <= '9') {
        while (index < length && token[index] >= '0' && token[index] <= '9') {
            index++;
        }
    } else {
        return 0;
    }
    if (index < length && token[index] == '.') {
        index++;
        if (index >= length || token[index] < '0' || token[index] > '9') {
            return 0;
        }
        while (index < length && token[index] >= '0' && token[index] <= '9') {
            index++;
        }
    }
    if (index < length && (token[index] == 'e' || token[index] == 'E')) {
        index++;
        if (index < length && (token[index] == '+' || token[index] == '-')) {
            index++;
        }
        if (index >= length || token[index] < '0' || token[index] > '9') {
            return 0;
        }
        while (index < length && token[index] >= '0' && token[index] <= '9') {
            index++;
        }
    }
    if (index != length) {
        return 0;
    }
    {
        /* The token is embedded in a NUL-terminated line, so `strtod` can
         * read it in place and must stop exactly at its end. */
        char *end = NULL;
        double value = strtod(token, &end);
        return end == token + length && isfinite(value);
    }
}

/* Whether a request id token can be echoed verbatim: a valid JSON string, a
 * valid JSON number, or `null`. Anything else is answered with a null id and
 * is never reflected. */
static int id_token_is_echoable(const char *token, size_t length) {
    if (token == NULL || length == 0) {
        return 0;
    }
    if (length == 4 && memcmp(token, "null", 4) == 0) {
        return 1;
    }
    if (token[0] == '"') {
        return length >= 2 && json_string_body_is_valid(token + 1, length - 2);
    }
    return json_number_token_is_valid(token, length);
}

static size_t utf8_encode(unsigned long code_point, char *out) {
    if (code_point < 0x80) {
        out[0] = (char)code_point;
        return 1;
    }
    if (code_point < 0x800) {
        out[0] = (char)(0xC0 | (code_point >> 6));
        out[1] = (char)(0x80 | (code_point & 0x3F));
        return 2;
    }
    if (code_point < 0x10000) {
        out[0] = (char)(0xE0 | (code_point >> 12));
        out[1] = (char)(0x80 | ((code_point >> 6) & 0x3F));
        out[2] = (char)(0x80 | (code_point & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (code_point >> 18));
    out[1] = (char)(0x80 | ((code_point >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((code_point >> 6) & 0x3F));
    out[3] = (char)(0x80 | (code_point & 0x3F));
    return 4;
}

/* Decodes one JSON string body into UTF-8 bytes; caller frees on success. */
static int unescape(const char *raw, size_t length, char **out,
                    size_t *out_length) {
    char *buffer = malloc(length + 1);
    if (buffer == NULL) {
        return -1;
    }
    size_t out_index = 0;
    size_t index = 0;
    while (index < length) {
        unsigned char byte = (unsigned char)raw[index];
        if (byte != '\\') {
            buffer[out_index++] = (char)byte;
            index++;
            continue;
        }
        if (index + 1 >= length) {
            free(buffer);
            return -1;
        }
        char escape = raw[index + 1];
        index += 2;
        switch (escape) {
            case '"': buffer[out_index++] = '"'; break;
            case '\\': buffer[out_index++] = '\\'; break;
            case '/': buffer[out_index++] = '/'; break;
            case 'b': buffer[out_index++] = '\b'; break;
            case 'f': buffer[out_index++] = '\f'; break;
            case 'n': buffer[out_index++] = '\n'; break;
            case 'r': buffer[out_index++] = '\r'; break;
            case 't': buffer[out_index++] = '\t'; break;
            case 'u': {
                if (index + 4 > length) {
                    free(buffer);
                    return -1;
                }
                unsigned long code_point = 0;
                for (int digit = 0; digit < 4; digit++) {
                    int value = hex_digit(raw[index + digit]);
                    if (value < 0) {
                        free(buffer);
                        return -1;
                    }
                    code_point = code_point * 16 + (unsigned long)value;
                }
                index += 4;
                if (code_point >= 0xD800 && code_point <= 0xDBFF) {
                    if (index + 6 > length || raw[index] != '\\' ||
                        raw[index + 1] != 'u') {
                        free(buffer);
                        return -1;
                    }
                    unsigned long low = 0;
                    for (int digit = 0; digit < 4; digit++) {
                        int value = hex_digit(raw[index + 2 + digit]);
                        if (value < 0) {
                            free(buffer);
                            return -1;
                        }
                        low = low * 16 + (unsigned long)value;
                    }
                    if (low < 0xDC00 || low > 0xDFFF) {
                        free(buffer);
                        return -1;
                    }
                    index += 6;
                    code_point =
                        0x10000 + ((code_point - 0xD800) << 10) + (low - 0xDC00);
                } else if (code_point >= 0xDC00 && code_point <= 0xDFFF) {
                    free(buffer);
                    return -1;
                }
                out_index += utf8_encode(code_point, buffer + out_index);
                break;
            }
            default:
                free(buffer);
                return -1;
        }
    }
    buffer[out_index] = '\0';
    *out = buffer;
    *out_length = out_index;
    return 0;
}

/* --- wire output ------------------------------------------------------------ */

static int write_frame(const char *frame) {
    size_t length = strlen(frame);
    if (length > g_bound) {
        log_line("transport_frame_oversize");
        return -1;
    }
    fwrite(frame, 1, length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    return 0;
}

/* Whether a frame with this id and payload fits the negotiated bound. */
static int envelope_fits(size_t raw_id_length, size_t payload_length) {
    return raw_id_length + payload_length + 64 <= g_bound;
}

/* A bounded refusal that reflects neither the request id nor its content:
 * reflecting either at a size the host never agreed to carry is the failure
 * the bound exists to prevent. */
static void write_oversize_refusal(void) {
    char frame[256];
    int written = snprintf(
        frame, sizeof(frame),
        "{\"jsonrpc\":\"" JSONRPC_VERSION
        "\",\"id\":null,\"error\":{\"code\":-32001,\"message\":"
        "\"transport_frame_oversize\",\"data\":{\"maxFrameBytes\":%zu}}}",
        g_bound);
    if (written > 0 && (size_t)written < sizeof(frame)) {
        (void)write_frame(frame);
    }
}

/* One response or error frame whose only variable-length member is the id.
 * Its size comes from the id and the payload, so a legal id at the bound is
 * echoed in full instead of being shortened to fit a fixed buffer; an id that
 * cannot be echoed as valid JSON is replaced by `null`, and a frame that still
 * does not fit the negotiated bound becomes a bounded refusal. */
static int write_envelope(const char *raw_id, size_t raw_id_length,
                          const char *payload) {
    if (raw_id == NULL || !id_token_is_echoable(raw_id, raw_id_length)) {
        raw_id = "null";
        raw_id_length = 4;
    }
    size_t capacity = raw_id_length + strlen(payload) + 64;
    char *frame = malloc(capacity);
    if (frame == NULL) {
        log_line("out_of_memory");
        return -1;
    }
    int written = snprintf(frame, capacity,
                           "{\"jsonrpc\":\"" JSONRPC_VERSION
                           "\",\"id\":%.*s,%s}",
                           (int)raw_id_length, raw_id, payload);
    if (written < 0 || (size_t)written >= capacity) {
        log_line("response_frame_too_large");
        free(frame);
        return -1;
    }
    if ((size_t)written > g_bound) {
        log_line("transport_frame_oversize");
        free(frame);
        write_oversize_refusal();
        return -1;
    }
    int result = write_frame(frame);
    free(frame);
    return result;
}

static int write_error(const char *raw_id, size_t raw_id_length, long code,
                       const char *message) {
    char payload[512];
    int written = snprintf(payload, sizeof(payload),
                           "\"error\":{\"code\":%ld,\"message\":\"%s\"}", code,
                           message);
    if (written < 0 || (size_t)written >= sizeof(payload)) {
        log_line("error_payload_too_large");
        return -1;
    }
    return write_envelope(raw_id, raw_id_length, payload);
}

/* `escaped_reference` is already JSON-escaped string content, so it can be
 * embedded inside the frame's quotes as it is. */
static int emit_text(const char *escaped_reference, const char *bytes,
                     size_t length, size_t *consumed) {
    char *frame = malloc(g_bound + 1);
    if (frame == NULL) {
        return -1;
    }
    int header = snprintf(
        frame, g_bound + 1,
        "{\"jsonrpc\":\"" JSONRPC_VERSION
        "\",\"method\":\"agent.event\",\"params\":{\"invocationRef\":\"%s\","
        "\"sequence\":%ld,\"kind\":\"text\",\"body\":\"",
        escaped_reference, g_sequence + 1);
    if (header < 0 || (size_t)header >= g_bound) {
        free(frame);
        return -1;
    }
    size_t used = (size_t)header;
    size_t budget = g_bound - used - 4; /* the closing `"}}` plus slack */
    /* Largest prefix whose escaped form fits, then never split a character. */
    size_t low = 0;
    size_t high = length < budget ? length : budget;
    while (low < high) {
        size_t middle = low + (high - low + 1) / 2;
        if (escaped_length(bytes, middle) <= budget) {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    while (low > 0 && low < length && ((unsigned char)bytes[low] & 0xC0) == 0x80) {
        low--;
    }
    used += escape_into(frame + used, bytes, low);
    memcpy(frame + used, "\"}}", 3);
    used += 3;
    frame[used] = '\0';
    if (write_frame(frame) != 0) {
        free(frame);
        return -1;
    }
    free(frame);
    *consumed = low;
    return 0;
}

static int emit_terminal(const char *escaped_reference, const char *body) {
    size_t capacity = strlen(escaped_reference) + strlen(body) + 256;
    char *frame = malloc(capacity);
    if (frame == NULL) {
        return -1;
    }
    int written = snprintf(
        frame, capacity,
        "{\"jsonrpc\":\"" JSONRPC_VERSION
        "\",\"method\":\"agent.event\",\"params\":{\"invocationRef\":\"%s\","
        "\"sequence\":%ld,\"kind\":\"terminal\",\"body\":%s}}",
        escaped_reference, g_sequence + 1, body);
    if (written < 0 || (size_t)written >= capacity) {
        log_line("terminal_frame_too_large");
        free(frame);
        return -1;
    }
    int result = write_frame(frame);
    free(frame);
    return result;
}

/* --- methods ---------------------------------------------------------------- */

static int admitted(const char *reference) {
    for (size_t index = 0; index < g_admitted_count; index++) {
        if (strcmp(g_admitted[index], reference) == 0) {
            return 1;
        }
    }
    return 0;
}

static void admit(const char *reference) {
    if (g_admitted_count >= MAX_ADMITTED) {
        log_line("admitted_reference_table_full");
        return;
    }
    char *copy = malloc(strlen(reference) + 1);
    if (copy == NULL) {
        return;
    }
    strcpy(copy, reference);
    g_admitted[g_admitted_count++] = copy;
}

static void describe(const char *raw_id, size_t raw_id_length) {
    (void)write_envelope(
        raw_id, raw_id_length,
        "\"result\":{\"id\":\"" AGENT_ID
        "\",\"instanceKind\":\"executable\",\"inputKinds\":[\"text\"],"
        "\"capabilities\":[\"dev.example.agent/stream\"],"
        "\"interfaceVersion\":\"1.0.0\",\"usage\":\"unavailable\","
        "\"cancel\":\"unsupported\",\"resume\":\"unsupported\"}");
}

static void execute(const char *raw_id, size_t raw_id_length, const member *params,
                    int params_count) {
    const member *reference = find_member(params, params_count, "invocationRef");
    const member *input = find_member(params, params_count, "input");
    if (reference == NULL || !reference->is_string || input == NULL ||
        !input->is_string) {
        write_error(raw_id, raw_id_length, -32602, "invalid_request");
        return;
    }
    char *reference_text = NULL;
    size_t reference_length = 0;
    if (unescape(reference->string_start, reference->string_length,
                 &reference_text, &reference_length) != 0 ||
        reference_length == 0 ||
        reference_length > MAX_INVOCATION_REFERENCE_BYTES) {
        free(reference_text);
        write_error(raw_id, raw_id_length, -32602, "invalid_invocation_ref");
        return;
    }
    char escaped_reference[MAX_INVOCATION_REFERENCE_BYTES * 6 + 1];
    size_t escaped_length =
        escape_into(escaped_reference, reference_text, reference_length);
    escaped_reference[escaped_length] = '\0';
    char *text = NULL;
    size_t text_length = 0;
    if (unescape(input->string_start, input->string_length, &text,
                 &text_length) != 0) {
        free(reference_text);
        write_error(raw_id, raw_id_length, -32602, "invalid_input");
        return;
    }
    char payload[1200];
    /* The receipt carries the invocation reference, so its size is known
     * before any work starts. A receipt that would not fit the negotiated
     * bound is a bounded refusal, and the work is not started. */
    snprintf(payload, sizeof(payload),
             "\"result\":{\"invocationRef\":\"%s\",\"outcome\":\"accepted\"}",
             escaped_reference);
    if (!envelope_fits(raw_id_length, strlen(payload))) {
        write_oversize_refusal();
        free(reference_text);
        free(text);
        return;
    }
    if (admitted(reference_text)) {
        /* Nothing is started twice. The receipt is the answer; the recorded
         * stream is not replayed as new work. */
        snprintf(payload, sizeof(payload),
                 "\"result\":{\"invocationRef\":\"%s\","
                 "\"outcome\":\"duplicate\"}",
                 escaped_reference);
        (void)write_envelope(raw_id, raw_id_length, payload);
        free(reference_text);
        free(text);
        return;
    }
    admit(reference_text);
    g_sequence = 0;
    /* The receipt reports admission; the end of the work is an event. */
    if (write_envelope(raw_id, raw_id_length, payload) != 0) {
        free(reference_text);
        free(text);
        return;
    }
    size_t offset = 0;
    while (offset < text_length) {
        size_t consumed = 0;
        if (emit_text(escaped_reference, text + offset, text_length - offset,
                      &consumed) != 0 ||
            consumed == 0) {
            log_line("text_chunk_below_bound");
            free(reference_text);
            free(text);
            exit(2);
        }
        g_sequence++;
        offset += consumed;
    }
    if (text_length == 0) {
        /* An empty reply is still a reply; it is not an abstention. */
        size_t consumed = 0;
        (void)emit_text(escaped_reference, "", 0, &consumed);
        g_sequence++;
    }
    (void)emit_terminal(escaped_reference, "{\"outcome\":\"succeeded\"}");
    free(reference_text);
    free(text);
}

static void initialize(const char *raw_id, size_t raw_id_length,
                       const member *params, int params_count) {
    if (g_initialized) {
        write_error(raw_id, raw_id_length, -32602, "already_initialized");
        return;
    }
    const member *protocol = find_member(params, params_count, "protocol");
    long major = 0;
    if (protocol == NULL) {
        write_error(raw_id, raw_id_length, -32600, "incompatible_protocol");
        return;
    }
    member protocol_members[8];
    int protocol_count =
        object_members(protocol->value_start, protocol->value_end,
                       protocol_members, 8);
    if (protocol_count < 0 ||
        member_long(find_member(protocol_members, protocol_count, "major"),
                    &major) != 0 ||
        major != PROTOCOL_MAJOR) {
        write_error(raw_id, raw_id_length, -32600, "incompatible_protocol");
        return;
    }
    long bound = OWN_MAX_FRAME_BYTES;
    const member *requested = find_member(params, params_count, "maxFrameBytes");
    if (requested != NULL &&
        member_long(requested, &bound) != 0) {
        write_error(raw_id, raw_id_length, -32602, "invalid_frame_bound");
        return;
    }
    if (bound < MIN_MAX_FRAME_BYTES || bound > MAX_MAX_FRAME_BYTES) {
        write_error(raw_id, raw_id_length, -32602, "invalid_frame_bound");
        return;
    }
    if ((size_t)bound < g_bound) {
        g_bound = (size_t)bound;
    }
    g_initialized = 1;
    /* The extension states what it is prepared to serve, before the response. */
    (void)write_frame(
        "{\"jsonrpc\":\"" JSONRPC_VERSION
        "\",\"method\":\"extension.ready\",\"params\":{\"profiles\":"
        "[\"agent-execution\"]}}");
    char payload[256];
    snprintf(payload, sizeof(payload),
             "\"result\":{\"protocol\":{\"major\":%ld,\"minimumMinor\":0},"
             "\"maxFrameBytes\":%zu,\"profiles\":[\"agent-execution\"]}",
             PROTOCOL_MAJOR, g_bound);
    (void)write_envelope(raw_id, raw_id_length, payload);
}

/* --- main loop -------------------------------------------------------------- */

static void handle_line(const char *line, size_t length, int *stop) {
    member top[8];
    int top_count = object_members(line, line + length, top, 8);
    if (top_count < 0) {
        write_error(NULL, 0, -32602, "invalid_request");
        return;
    }
    const member *version = find_member(top, top_count, "jsonrpc");
    if (version == NULL || !version->is_string ||
        version->string_length != 3 ||
        memcmp(version->string_start, JSONRPC_VERSION, 3) != 0) {
        write_error(NULL, 0, -32600, "invalid_request");
        return;
    }
    const member *method = find_member(top, top_count, "method");
    if (method == NULL || !method->is_string) {
        write_error(NULL, 0, -32600, "invalid_request");
        return;
    }
    char method_name[64];
    if (method->string_length >= sizeof(method_name)) {
        write_error(NULL, 0, -32600, "invalid_request");
        return;
    }
    memcpy(method_name, method->string_start, method->string_length);
    method_name[method->string_length] = '\0';

    const member *raw_id = find_member(top, top_count, "id");
    const char *id_text = NULL;
    size_t id_length = 0;
    if (raw_id != NULL) {
        id_text = raw_id->value_start;
        id_length = (size_t)(raw_id->value_end - raw_id->value_start);
        if (id_length + RESPONSE_RESERVE_BYTES > g_bound) {
            /* No response that echoes this id exists inside the negotiated
             * bound, so the request is refused before any work starts. */
            write_error(NULL, 0, -32001,
                        "request_id_exceeds_negotiated_frame_bound");
            return;
        }
        if (!id_token_is_echoable(id_text, id_length)) {
            /* An id this carrier cannot echo as valid JSON — a non-finite
             * number, malformed number, control byte in a string, object,
             * array or boolean — is answered with a null id and never
             * reflected. */
            write_error(NULL, 0, -32600, "invalid_request");
            return;
        }
    }

    const member *params = find_member(top, top_count, "params");
    member params_members[8];
    int params_count = 0;
    if (params != NULL) {
        params_count = object_members(params->value_start, params->value_end,
                                      params_members, 8);
        if (params_count < 0) {
            write_error(id_text, id_length, -32602, "invalid_params");
            return;
        }
    }

    int notification = raw_id == NULL;
    if (strcmp(method_name, "extension.initialize") == 0) {
        if (!notification) {
            initialize(id_text, id_length, params_members, params_count);
        }
        return;
    }
    if (!g_initialized) {
        if (!notification) {
            write_error(id_text, id_length, -32600, "not_initialized");
        }
        return;
    }
    if (strcmp(method_name, "agent.describe") == 0) {
        if (!notification) {
            describe(id_text, id_length);
        }
        return;
    }
    if (strcmp(method_name, "agent.execute") == 0) {
        /* A notification admits no invocation: there is no receipt to answer
         * with, and work whose receipt cannot be delivered is not started. */
        if (!notification) {
            execute(id_text, id_length, params_members, params_count);
        }
        return;
    }
    if (strcmp(method_name, "extension.shutdown") == 0) {
        if (!notification) {
            (void)write_envelope(id_text, id_length,
                                 "\"result\":{\"outcome\":\"stopped\"}");
        }
        *stop = 1;
        return;
    }
    if (!notification) {
        write_error(id_text, id_length, -32601, "unsupported_method");
    }
}

int main(void) {
    char *line = malloc(OWN_MAX_FRAME_BYTES + 2);
    if (line == NULL) {
        return 2;
    }
    for (;;) {
        size_t read_size = g_bound + 2;
        if (!fgets(line, (int)read_size, stdin)) {
            break;
        }
        size_t length = strlen(line);
        int over_bound =
            length > g_bound + 1 ||
            (length == g_bound + 1 && line[length - 1] != '\n');
        if (over_bound) {
            log_line("frame_too_large");
            write_error(NULL, 0, -32600, "frame_too_large");
            free(line);
            return 2;
        }
        if (length > 0 && line[length - 1] == '\n') {
            length--;
        }
        int stop = 0;
        handle_line(line, length, &stop);
        if (stop) {
            break;
        }
    }
    free(line);
    return 0;
}
