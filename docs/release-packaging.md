# Desktop preview packaging and release status

## Run the current development build

Install the repository dependencies from the repository root and start both the local Hub and desktop renderer:

```sh
npm ci
npm run dev
```

The desktop renderer is available at `http://127.0.0.1:5173/` while the Vite development server is running. The Hub uses `http://127.0.0.1:4317/` by default and keeps its database, local snapshots and school documents in `~/.school-erp`. Set `SCHOOL_ERP_DATA_DIR` before launching the root command to use another data folder. Stop both development processes before manually copying that folder.

To compile the Hub and desktop renderer/main process without opening the UI:

```sh
npm run build
```

The workspace build output is not an installer. Preview installers can be built with `npm run package:win` and `npm run package:mac`. They include Electron, the desktop UI, and the local Hub runtime; the Hub starts with the desktop app and stores its database and school files under `~/.school-erp` (Windows: the current user's profile). The Hub does not run as an OS service and is not available while the desktop app is closed.

## Current release boundary

The repository configures unsigned preview installer targets: Windows x64 NSIS EXE and universal macOS DMG. The universal DMG can be built on macOS with `npm run package:mac`. Build the Windows EXE on a Windows machine with `npm run package:win`; cross-building it from macOS is not supported by this preview workflow. They are for manual QA, not distribution to schools without technical support. Windows SmartScreen and macOS Gatekeeper may warn or block them. Production distribution still needs code signing (and Apple notarization), supported OS/version declaration, clean-machine install/upgrade/uninstall tests, recovery testing, and operational support procedures. Automatic updates and boot-time Hub operation are not configured.

The packaged app starts and supervises the Hub process while it is running, shuts it down when the desktop app exits, and applies database migrations on Hub startup. It does not start the Hub at login/boot or restart it independently from the desktop app. Confirm data-folder behavior on clean installs and upgrades before any school pilot.

The app does not yet include a Google sign-in flow to provision Firebase projects. The Firebase project and OAuth client must be owned/configured by the school; mobile app registrations are deferred. Any future setup flow must restrict provisioning to Spark-eligible services and never enable billing, Cloud Functions, or Firebase Storage. Android emulator builds and iOS builds remain skipped under the owner's earlier instruction; Android release signing remains deferred.

## Linux PHP backend bundle

The source deploy bundle is prepared separately as `school-erp-backend-linux.zip` (see `docs/linux-backend-deployment.md`). It contains the Laravel app, production Composer dependencies, `.env.example` and migrations; it intentionally contains no school database or secrets. Create the MySQL database and user on the Linux host, configure `.env`, set the web root to `Backend/public`, and run migrations there.

## School-data safety before a release test

- Use synthetic data for test installs.
- Keep an encrypted `.schoolbackup` and its passphrase separate from the computer before an upgrade drill. That transfer format omits uploaded documents and credentials; preserve local recovery snapshots and document files separately when testing a migration.
- Verify the supported Node runtime and SQLite behavior on each target OS before adopting this development workflow for schools.
- Read [backup and recovery](user-guides/recovery-and-privacy.md), [school desktop](user-guides/school-desktop.md), and [Phase 10 acceptance](phase10-acceptance.md) before testing.
