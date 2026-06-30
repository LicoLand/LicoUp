# Flutter Client Config Map

Primary files:

- `apps/desktop/lib/src/services/runtime_services.dart`
- `apps/desktop/lib/src/controllers/app_controller.dart`
- `apps/desktop/README.md`

Portable data resolution:

1. `LICO_PORTABLE_DIR`
2. sibling `portable-data` for packaged app or executable
3. platform Application Support root

Important files under portable data:

- `settings.json`
- `recent-runs.json`
- `checkpoints.json`
- `logs/client.log`
- `exports/`
- `mail-imports/`

Important client APIs:

- `GET /api/bootstrap`
- `POST /api/discovery/check-in`
- `POST /api/upload-sessions`
- `PUT /api/upload-sessions/:id/files/:index`
- `POST /api/jobs`
- `GET /api/jobs/:id`
- `GET /api/jobs/:id/result`
- `GET /api/jobs/:id/normalized-documents`
- `GET /api/jobs/:id/normalized-documents/:documentId`
- `GET /api/knowledge/export/docx`
- `GET /api/knowledge/export/markdown`
