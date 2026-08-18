# Supernote Plugin Template

A simple template for Supernote plugins for automated testing. It has no UI and provides a single button on the side.

## Setup

Create a new project from this template by running the `setup.py` script:

```bash
python3 setup.py <project-name>
```

This will bootstrap a new React Native project properly configured for Supernote plugin development.

## Scripts

Inside your generated project, you can use the following cross-platform scripts (works on both Mac and Windows):

* `npm run build` - Build the plugin package
* `npm run send` - Push the package to a connected Supernote device
* `npm run run` - Launch the plugin on the device via UI automation
* `npm run deploy` - Install the plugin directly via the Supernote Plugin Manager
* `npm run send:run` - Bundle, push, and run
* `npm run deploy:run` - Bundle, deploy, and run
* `npm run verify` - Validate the structure of your generated `.snplg`
* `npm run diagnostics` - Collect logs and window state from the PluginHost
* `npm run recover` - Wipe PluginHost data if it gets stuck in a crash loop
