# Supernote Plugin Template

A simple template for Supernote plugins. Ships with cross-platform scripts (bash + PowerShell) that automate bundling, deploying, and launching plugins on a connected device via ADB.

The default generated plugin has no UI — just a single button on the NOTE sidebar.

## Setup

```bash
python3 setup.py MyPlugin   # Mac / Linux
python setup.py MyPlugin    # Windows
```

During setup, `setup.py` automatically detects your local development tools (JDK, Android SDK, ADB) and creates a `devconfig.json` in the project root.

## Local Configuration (`devconfig.json`)

Each generated project contains a `devconfig.json` file for machine-specific tool paths. This file is ignored by Git and only affects the plugin project scripts without changing your global environment.

```json
{
  "javaHome": "/path/to/compatible/jdk",
  "androidSdk": "/path/to/android/sdk",
  "adb": "/path/to/platform-tools/adb"
}
```

- **`javaHome`**: Path to a compatible JDK (JDK 17–23 supported by Gradle 8.13; JDK 17 preferred).
- **`androidSdk`**: Path to Android SDK installation. Automatically updates `sdk.dir` in `android/local.properties`.
- **`adb`**: Path to the ADB executable used by deploy, run, send, and diagnostic scripts.

If any path is `null` or missing, the scripts will fall back to your system `PATH` and environment variables (`JAVA_HOME`, `ANDROID_HOME`, `ADB_BIN`). You can edit `devconfig.json` at any time to point to specific tools.

## Scripts

| Command | What it does |
|---|---|
| `npm run build` | Build the `.snplg` package |
| `npm run send` | Bundle JS and push to device |
| `npm run run` | Launch the plugin on device via UI automation |
| `npm run deploy` | Full install through the Supernote Plugin Manager also via UI automation |
| `npm run send:run` | Send + run |
| `npm run deploy:run` | Deploy + run |
| `npm run verify` | Validate `.snplg` structure and native libraries |
| `npm run diagnostics` | Collect PluginHost logs, screenshots, and window state |
| `npm run recover` | Force-clear PluginHost data (use if stuck in a crash loop. deletes all plugins aside from stickers, the stickers themselves are deleted, and resets to default) |

