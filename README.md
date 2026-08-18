# Supernote Plugin Template

A simple template for Supernote plugins. Ships with cross-platform scripts (bash + PowerShell) that automate bundling, deploying, and launching plugins on a connected device via ADB.

The generated plugin has no UI — just a single button on the NOTE sidebar.

## Setup

```bash
python3 setup.py MyPlugin   # Mac / Linux
python setup.py MyPlugin    # Windows
```

## Scripts

| Command | What it does |
|---|---|
| `npm run build` | Build the `.snplg` package |
| `npm run send` | Bundle JS and push to device |
| `npm run run` | Launch the plugin on device via UI automation |
| `npm run deploy` | Full install through the Supernote Plugin Manager |
| `npm run send:run` | Send + run |
| `npm run deploy:run` | Deploy + run |
| `npm run verify` | Validate `.snplg` structure and native libraries |
| `npm run diagnostics` | Collect PluginHost logs, screenshots, and window state |
| `npm run recover` | Force-clear PluginHost data (use when stuck in a crash loop) |
