---
name: bump-version
description: "Bump app version across all Xcode targets (iOS, Watch, extensions). Supports explicit version, semver keywords (patch/minor/major), or auto mode that infers from git history."
---

# Bump Version

Bump the marketing version and build number across all Xcode targets in the project. Ensures the parent app, Watch app, and all extensions stay in sync (required by Apple).

## Usage Modes

### Explicit version
```
/bump-version 2.3.0
```
Sets all targets to the specified version.

### Semver keyword
```
/bump-version patch   → 2.1.1 → 2.1.2
/bump-version minor   → 2.1.1 → 2.2.0
/bump-version major   → 2.1.1 → 3.0.0
```
Reads the current version from the main app target, bumps the specified component, syncs all targets.

### Auto mode (default when no argument)
```
/bump-version
/bump-version auto
```
Analyzes git commits since the last version bump commit and infers the bump type:
- Any commit with `BREAKING CHANGE` or `!:` in message → **major**
- Any commit starting with `feat` → **minor**
- All other commits (`fix`, `chore`, `refactor`, etc.) → **patch**
- No commits since last bump → no action

## Process

**Step 1: Find the Xcode project**

Look for `*.xcodeproj/project.pbxproj` in the current working directory or one level down. If multiple exist, use the one in the iOS app directory.

**Step 2: Read current version**

Parse `MARKETING_VERSION` from the main app target's build settings in `project.pbxproj`. The main app target is identified by `productType = "com.apple.product-type.application"` that is NOT a Watch app (no `WATCHOS_DEPLOYMENT_TARGET`).

**Step 3: Determine new version**

- **Explicit**: use the provided version string
- **Keyword**: parse current as `major.minor.patch`, bump the specified component
- **Auto**: run `git log --oneline` from the last commit containing "bump version" or "bump-version" in the message. Classify each commit's prefix and pick the highest bump level.

**Step 4: Update project.pbxproj**

Replace ALL `MARKETING_VERSION = <old>;` entries with the new version using sed. This covers Debug and Release configurations for all targets (main app, Watch, extensions).

Also increment `CURRENT_PROJECT_VERSION` by 1 for all targets.

```bash
# Update marketing version
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${NEW_VERSION};/g" project.pbxproj

# Increment build number
OLD_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' project.pbxproj | tr -dc '0-9')
NEW_BUILD=$((OLD_BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" project.pbxproj
```

**Step 5: Verify and report**

- Grep the updated file to confirm all targets show the new version
- Report: `Bumped version: X.Y.Z → A.B.C (build N) across N targets`
- Do NOT commit automatically — the user decides when to commit

## Auto Mode Classification Rules

Read commits since the last version bump:
```bash
git log --oneline $(git log --all --oneline --grep="bump.*version\|version.*bump" -1 --format="%H")..HEAD
```

If no version bump commit exists, read the last 20 commits.

Classification (check in this order):
1. **major**: message contains `BREAKING CHANGE`, `BREAKING:`, or `type!:` (e.g. `feat!:`)
2. **minor**: message starts with `feat` (e.g. `feat:`, `feat(ios):`)
3. **patch**: everything else (`fix`, `chore`, `refactor`, `docs`, `test`, `style`, `perf`, `ci`)

The highest classification wins. If there are 5 fixes and 1 feat, bump minor.

## Important

- ALL targets must have the same `MARKETING_VERSION` — Apple rejects archives where extensions don't match
- Build number (`CURRENT_PROJECT_VERSION`) should also be consistent across targets
- Do NOT commit the change — just update the file and report
