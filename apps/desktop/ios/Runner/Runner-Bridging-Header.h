#import "GeneratedPluginRegistrant.h"

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LicoSecureMeshSecretStoreCallbacks {
  void *ctx;
  const char *backend;
  bool (*set_secret)(void *ctx, const char *namespace_, const char *key, const char *secret);
  char *(*get_secret)(void *ctx, const char *namespace_, const char *key);
  bool (*delete_secret)(void *ctx, const char *namespace_, const char *key);
  void (*string_free)(void *ctx, char *value);
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
