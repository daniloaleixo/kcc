# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

KCC (Kindle Comic Converter) is a PySide6/Qt6 desktop app plus two CLIs that convert comics to
e-reader formats. Single Python package (`kindlecomicconverter/`), no monorepo, `setup.py` only.

## Environment

Conda `base` is auto-activated on this machine and there is no venv in the repo. Create and
activate one before installing anything, or the deps land in conda base:

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python kcc.py            # GUI; kcc-c2e.py / kcc-c2p.py are the CLIs
```

Runtime deps that are **not** pip packages and are resolved from `PATH`:
`kindlegen` (MOBI/AZW3 output — not installed here, so MOBI conversions will fail locally),
`7z`, `bsdtar`, `unar`, `unrar`. On Linux `comicarchive.py` tries `bsdtar` first, which resolves to
conda's copy — a deactivated conda shell changes which binary extracts archives.

## Building

`setup.py` overrides these commands to shell out to PyInstaller and then `sys.exit(0)`; they do not
behave like normal setuptools commands:

```bash
python setup.py build_binary   # GUI binary
python setup.py build_c2e      # comic2ebook CLI
python setup.py build_c2p      # comic2panel CLI
```

## Generated files — never hand-edit

`kindlecomicconverter/KCC_ui.py`, `KCC_ui_editor.py`, and `KCC_rc.py` are pyside6-uic/rcc output and
are committed to the repo. Edit `gui/*.ui` (or `gui/KCC.qrc`), then regenerate and commit both the
`.ui` and the generated file in the same change:

```bash
./gen_ui_files.sh        # gen_ui_files.bat on Windows
```

After editing a `.ui`, verify tab order in Qt Designer's Tab Order Editing Mode.

## No tests, linter, or formatter

There is no pytest/tox, no ruff/flake8/black, no mypy, no pre-commit, and no `.editorconfig` —
don't go looking for them or invent a "run the tests" step. CI only builds and releases. Verify
changes by running the app. Note that changes here can silently affect file splitting/chunking and
chapter alignment.

Style is unenforced and mixed: legacy code is camelCase (`getImageFileName`, `buildHTML`), newer
code is snake_case (`subprocess_run`, `erase_rainbow_artifacts`). Match the surrounding file rather
than normalizing.

## Cross-platform invariants

- **All subprocess calls must go through `shared.subprocess_run`** — it adds
  `CREATE_NO_WINDOW` on Windows. A bare `subprocess.run` flashes a console window for Windows users.
- Multiprocessing uses `spawn` (set in the launchers before anything else, alongside
  `modify_path()`). Worker functions must be top-level and picklable; module-level state is not
  inherited.
- Windows MAX_PATH: paths over 220 chars are guarded in `comic2ebook.py`. Keep that in mind when
  building output paths.
- `kcc-c2e.py` imports `modify_path` from the root `kcc.py`, so the CLIs depend on being run from
  the repo root.

## Things that are load-bearing

- `__version__` in `kindlecomicconverter/__init__.py` is the single source of truth for the version,
  and the Dockerfile greps that line — keep the format intact. Release commits are exactly
  `bump to X.Y.Z`, touching only that line.
- `QSettings('ciromattia', 'kcc10')` in `KCC_gui.py` — the org/app keys are stale but changing them
  silently wipes every user's saved settings.

## Repo etiquette

Default branch is `master`. This clone's `origin` is a personal fork (`daniloaleixo/kcc`); changes
here are local patches, not upstream PRs. If syncing from `ciromattia/kcc`, use GitHub's "Sync fork"
button rather than `git merge`, per the upstream README. Commit subjects are lowercase and
descriptive; upstream appends `(#NNN)` on squash-merge, which doesn't apply to local commits.
