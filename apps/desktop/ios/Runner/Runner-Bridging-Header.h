#import "GeneratedPluginRegistrant.h"

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  LICO_SECURE_MESH_SECRET_GET_ERROR = -1,
  LICO_SECURE_MESH_SECRET_GET_NOT_FOUND = 0,
  LICO_SECURE_MESH_SECRET_GET_FOUND = 1,
};

typedef struct LicoSecureMeshSecretStoreCallbacks {
  void *ctx;
  const char *backend;
  bool (*set_secret)(
    void *ctx,
    const char *namespace_,
    const char *key,
    const uint8_t *secret,
    size_t secret_len
  );
  int32_t (*get_secret)(
    void *ctx,
    const char *namespace_,
    const char *key,
    uint8_t **value_out,
    size_t *value_len_out
  );
  bool (*delete_secret)(void *ctx, const char *namespace_, const char *key);
  void (*bytes_zeroize_and_free)(void *ctx, uint8_t *value, size_t value_len);
} LicoSecureMeshSecretStoreCallbacks;

int32_t lico_secure_mesh_runtime_self_test(void);
int32_t lico_secure_mesh_runtime_feature_flags(void);
int32_t lico_secure_mesh_runtime_protocol_hash(void);
char *lico_secure_mesh_json(const char *request_json, const char *files_dir);
char *lico_secure_mesh_json_with_secret_store(
  const char *request_json,
  const char *files_dir,
  const LicoSecureMeshSecretStoreCallbacks *callbacks
);
void lico_secure_mesh_string_free(char *value);

#ifdef __cplusplus
}
#endif
