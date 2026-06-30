# macOS Mail Import Operations

Relevant implementation:

- `apps/desktop/lib/src/services/macos_mail_importer.dart`
- `apps/desktop/macos/Runner/MacOSMailImporter.swift`
- `apps/desktop/lib/src/controllers/app_controller.dart`

Operational paths:

- Imported mail workspace: `portable-data/mail-imports/`
- Diagnostics: `portable-data/mail-imports/mail-*/diagnostics.json`
- Client log: `portable-data/logs/client.log`
- Knowledge index: `mail-imports/.../index/docs.tsv`
- Cloud taxonomy cache: `mail-imports/.../index/cloud-taxonomy.json`

Checklist:

- Confirm macOS Mail permission or guide authorization activation.
- Check diagnostics JSON before changing parser logic.
- Refresh index stats before judging whether import is empty.
- Use evidence open action to verify message ids still resolve.
- Keep raw `.eml` files available for server ingestion.
