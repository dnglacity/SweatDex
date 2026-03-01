# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Identity

- **App name (pubspec):** `apexondeck` — displayed as "Apex On Deck" (abbreviated AOD in comments/version tags)
- **Purpose:** Roster management app for sports coaches, athletes, and guardians
- **Targets:** Android, iOS, Web (deployed to GitHub Pages)
- **Backend:** Supabase (Auth + PostgREST + Realtime + SECURITY DEFINER RPCs)
- **Dart SDK:** `^3.11.0` (Dart 3.x patterns and null-safety required)
- **Current Version** v1.12 

## Build & Run Commands

All commands require `--dart-define-from-file=config.json` to inject Supabase credentials (never use `--dart-define` individually or hardcode them).

```bash
# Run in debug mode
flutter run --dart-define-from-file=config.json

# Publish to GitHub Pages (web)
flutter build web --dart-define-from-file=config.json
# commit
git subtree push --prefix build/web origin gh-pages

# Reset (clean rebuild + republish)
flutter clean
flutter pub get
flutter build web --dart-define-from-file=config.json
# commit
git push origin --delete gh-pages
git subtree push --prefix build/web origin gh-pages

# Static analysis
flutter analyze

# Run tests
flutter test
```

`config.json` (in repo root, not committed as a secret but present locally) holds `SUPABASE_URL` and `SUPABASE_ANON_KEY`.

## Architecture

### Layer overview

```
lib/
  main.dart               — Supabase init (from --dart-define-from-file), MyApp widget, theme
  models/
    player.dart           — Player data class (fromMap/toMap/copyWith + display helpers)
    app_user.dart         — AppUser + TeamMember data classes
  services/
    auth_service.dart     — Auth operations (signUp, signIn, signOut, changeEmail, deleteAccount)
    player_service.dart   — All DB operations: players, teams, team_members, game_rosters
    offline_cache_service.dart — shared_preferences JSON cache (TTL-aware, singleton)
  screens/
    auth_wrapper.dart     — Root widget; reacts to Supabase auth stream; routes to Login or TeamSelection
    login_screen.dart     — Sign-in / sign-up / forgot-password UI
    reset_password_screen.dart — Shown on passwordRecovery auth event
    team_selection_screen.dart — Lists teams; routes coaches → RosterScreen, players → PlayerSelfViewScreen
    roster_screen.dart    — Coach-facing roster (paginated, bulk-delete, attendance tracking)
    add_player_screen.dart
    manage_members_screen.dart — Add/remove team members; link players to user accounts
    game_roster_screen.dart   — Game-day lineup builder (starters + substitutes, tab lazy-loading)
    saved_roster_screen.dart  — Lists saved game rosters
    player_self_view_screen.dart — Athlete-facing self-view
    account_settings_screen.dart
  widgets/
    sport_autocomplete_field.dart — Shared StatefulWidget for sport search (used in 2+ screens)
```

### Auth & routing

`AuthWrapper` (a `StatelessWidget` using `StreamBuilder<AuthState>`) is the app's `home`. It reacts to `Supabase.instance.client.auth.onAuthStateChange` and renders:
- `CircularProgressIndicator` while waiting
- `ResetPasswordScreen` on `AuthChangeEvent.passwordRecovery`
- `TeamSelectionScreen` when session exists
- `LoginScreen` when unauthenticated

**No manual `Navigator` calls** are made at auth transition boundaries — routing is driven entirely by the reactive stream.

### Service patterns

- **`PlayerService`** is the single service for all database interactions except auth. It holds an in-memory team list cache (`_teamsCache`) and a Completer-deduped user-ID resolver (`_getCurrentUserId()`). Call `clearCache()` on sign-out.
- **`AuthService`** wraps Supabase auth SDK calls with typed error handling and domain-only logging (never logs full email addresses).
- **`OfflineCacheService`** is a singleton backed by `shared_preferences`. It caches player lists and game rosters (default TTL: 60 min) for offline/poor-signal gym use. Key builders: `OfflineCacheService.playersKey(teamId)` and `OfflineCacheService.gameRostersKey(teamId)`.

### Database & Supabase conventions

- Explicit column lists (`_kPlayerColumns`, `_kUserColumns`, `_kTeamMemberColumns` in `player_service.dart`) are used instead of `select('*')` — keep them in sync with the DB schema in `supabase_blueprint.json`.
- Sensitive operations go through **SECURITY DEFINER RPCs**: `create_team`, `add_member_to_team`, `delete_account`, `change_user_email`, `link_player_to_user`, `link_guardian_to_player`, `lookup_user_by_email`.
- The DB trigger `handle_new_user` populates `public.users` from `raw_user_meta_data` on sign-up. A separate trigger `fn_sync_player_membership_on_link` upserts a `team_members` row (role = `player`) when `players.user_id` changes from NULL to a value.

### Roles

Valid `team_members.role` values: `owner` | `coach` | `player` | `team_parent` | `team_manager`

- `isCoach` convenience getter: true for `coach`, `owner`, and `team_manager`.
- `isGuardian`: `team_parent`.

### Theme

Brand colors defined in `main.dart`:
- Primary (AppBar, filled buttons): Deep Navy Blue `#1A3A6B`
- Secondary (FABs, chips): Championship Gold `#F4C430`

### Import style

All imports within `lib/` use **relative paths** (`../models/player.dart`), not package-name imports.

### Instructions

- Provide script by replacing supabase_script.md if Supabase requires modification.
- Commit with the following format example using version, date and time: "[version] 01.01.2026 1524".
- Add comments to changelog.txt using the commit message as the section header (format: `[version] MM.DD.YYYY HHMM description`). Describe what was added, removed, changed, or fixed.