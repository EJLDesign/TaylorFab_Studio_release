# TaylorFab Studio

TaylorFab Studio frame generator plugin for AutoCAD 2025+ (formerly BMFrameGenCAD). Generates full multi-wall modular framing towers, cabinets, elevations, plan views, and composed sheets.

Releases ship two runtime flavors in one package — .NET 8 for AutoCAD 2025/2026 and .NET 10 for AutoCAD 2027+ — and each AutoCAD version automatically loads the right one. (AutoCAD 2024 and earlier: use release v9.x, the final version supporting them.)

## Quick Install

Open **PowerShell** and paste:

```powershell
iex (irm https://raw.githubusercontent.com/EJLDesign/TaylorFab_Studio_release/main/install.ps1)
```

This runs the installer directly in memory — no temp script file, so antivirus scan locks on a downloaded file can't interrupt it.

The installer will:
- Detect your installed AutoCAD version(s)
- Download the latest release
- Install the plugin with automatic loading
- Install the current license file (imported silently on first load)
- Set up the model library

No admin rights required.

## Manual Install

The installer is strongly recommended (it writes the version-gated bundle manifest). If installing by hand:

1. Download the latest `.zip` from [Releases](https://github.com/EJLDesign/TaylorFab_Studio_release/releases/latest)
2. Create folder `%APPDATA%\Autodesk\ApplicationPlugins\TaylorFabStudio.bundle\Contents\`
3. Create `Contents\net8\` and `Contents\net10\`; into EACH, copy that flavor's `TaylorFabStudio.dll` plus a copy of `license.lic`, `EULA.txt`, and the `assets\` folder (the plugin resolves these beside the loaded DLL)
4. Copy `Models\` to `Contents\Models\` — the plugin finds the model library there, beside its own flavor folder; it is not a setting and cannot be pointed anywhere else (the palette shows a red banner if it is missing)
5. Copy a `PackageContents.xml` from a previous installer run (or run the installer once) — it gates `net8` to AutoCAD 2025/2026 and `net10` to 2027+
6. Launch AutoCAD — the plugin loads automatically via the bundle

Close AutoCAD before installing or upgrading: the installer refuses to run while the plugin is loaded, and never touches the previous install until the new one is complete.

## Usage

1. Launch AutoCAD
2. Type `TFAB` in the command line
3. Build towers from the palette and edit them with the Tower and Wall editors

## Uninstall

Delete the folder:
```
%APPDATA%\Autodesk\ApplicationPlugins\TaylorFabStudio.bundle
```

## Requirements

- AutoCAD 2025 or later (2025/2026 use the bundled .NET 8 build; 2027+ uses the bundled .NET 10 build — no separate .NET install needed, AutoCAD ships its own runtime)
- Windows 10/11
- A valid license file (contact evanl@taylorinc.com)
