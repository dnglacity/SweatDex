Apex On Deck (AOD) — Security & Compliance Overview
                             **Version:** v1.12 | **Date:** 2026-02-28

                             ---

                             ## 1. Application Overview

                             Apex On Deck (AOD) is a Flutter-based roster management application for sports coaches, athletes, and guardians. It targets Android, iOS, and Web (GitHub Pages). The backend is  
                             Supabase (PostgreSQL + PostgREST + Realtime + Auth). The app stores and processes personally identifiable information (PII) for minors (student athletes) and adults (coaches,    
                             guardians), which places it squarely within the scope of several privacy and data-protection frameworks.

                             ---

                             ## 2. Application Functions

                             ### 2.1 Authentication & Identity

                             | Function | Description |
                             |---|---|
                             | `signUp` | Creates a new auth user; embeds profile metadata in `raw_user_meta_data`; validated against null-user failure states |
                             | `signIn` | Email/password authentication via Supabase Auth |
                             | `signOut` | Terminates the session; triggers in-memory and on-disk cache wipe |
                             | `resetPassword` | Sends a password-reset email via Supabase magic-link flow |
                             | `changePassword` | Re-authenticates the user before updating the credential |
                             | `changeEmail` | Re-authenticates, then cascades the change across `public.users`, `players.athlete_email`, and `players.guardian_email` via a SECURITY DEFINER RPC, then updates
                              the Supabase Auth record |
                             | `deleteAccount` | Invokes the `delete_account` SECURITY DEFINER RPC to remove all user data; signs out afterward |
                             | `updateProfile` | Allows in-session profile edits (name, nickname, organization, athlete ID) |

                             ### 2.2 Team Management

                             | Function | Description |
                             |---|---|
                             | `createTeam` | Creates a team and automatically assigns the creator the `owner` role via the `create_team` RPC |
                             | `updateTeam` | Edits team name and sport (owner-only, enforced by RLS) |
                             | `deleteTeam` | Cascading delete of a team, its players, and member records (owner-only) |
                             | `getTeams` | Returns the teams the authenticated user belongs to with role context; uses a 5-minute in-memory TTL cache |
                             | `transferOwnership` | Atomically promotes a new owner and demotes the current owner via a SECURITY DEFINER RPC |

                             ### 2.3 Roster & Player Management

                             | Function | Description |
                             |---|---|
                             | `addPlayerAndReturnId` | Inserts a new player row with full PII (name, email, grade, jersey, position) |
                             | `getPlayers` / `getPlayersPaginated` | Retrieves the roster for a team; falls back to on-device cache on network failure |
                             | `getPlayerStream` | Real-time Supabase channel subscription to the player table |
                             | `updatePlayer` | Updates all mutable fields of a player record |
                             | `updatePlayerStatus` / `bulkUpdateStatus` | Sets attendance status (present, absent, late, excused) on one or all players |
                             | `bulkDeletePlayers` / `deletePlayer` | Permanently removes player records |
                             | `getAttendanceSummary` | Returns per-status counts for a team for reporting |

                             ### 2.4 Team Member Management

                             | Function | Description |
                             |---|---|
                             | `addMemberToTeam` | Adds a registered user to a team by email via the `add_member_to_team` RPC |
                             | `removeMemberFromTeam` | Removes a user from a team; un-links their player record first; prevents removing the sole owner |
                             | `updateMemberRole` | Changes a member's role; blocks direct promotion to owner (must use `transferOwnership`) |
                             | `getTeamMembers` | Lists all members of a team with joined user profiles |
                             | `lookupUserByEmail` | Searches the `public.users` table by email via RPC (used for adding members and linking players) |
                             | `linkPlayerToAccount` | Associates a player row with a registered user account via the `link_player_to_user` RPC |
                             | `linkGuardianToPlayer` | Stores a guardian email against a player record via RPC |

                             ### 2.5 Game Roster Management

                             | Function | Description |
                             |---|---|
                             | `createGameRoster` | Creates a named game-day lineup with starter slots and attribution |
                             | `updateGameRosterLineup` | Saves starters/substitutes arrays to a roster row |
                             | `duplicateGameRoster` | Clones an existing roster under a new title |
                             | `deleteGameRoster` | Permanently removes a saved game roster |
                             | `getGameRosters` / `getGameRosterStream` | Retrieves or subscribes to game rosters for a team; uses offline cache fallback |

                             ### 2.6 Team Invite System

                             | Function | Description |
                             |---|---|
                             | `getOrCreateTeamInvite` | Generates or retrieves an active 6-character invite code with an expiry timestamp |
                             | `redeemTeamInvite` | Validates a code and adds the authenticated user to the associated team |
                             | `revokeTeamInvite` | Deactivates the current invite code for a team |

                             ### 2.7 Offline Cache

                             | Function | Description |
                             |---|---|
                             | `writeList` / `readList` | Persists player and game roster data to `shared_preferences` with a configurable TTL (default 60 min) |
                             | `clearAll` | Wipes all on-device cache entries on sign-out to prevent cross-account data leakage on shared devices |
                             | `evictExpired` | Background cleanup of stale cache entries on app launch |

                             ---

                             ## 3. Data Inventory

                             ### 3.1 Personal Data Collected

                             | Data Element | Subject | Sensitivity |
                             |---|---|---|
                             | First name, last name | Coach, athlete, guardian, team manager | PII |
                             | Email address | All user types | PII |
                             | Password (hashed by Supabase Auth) | All user types | Credential |
                             | Athlete ID / Student ID | Athlete | PII — may be a school record identifier |
                             | Grade level (9-12) | Athlete | PII — educational record |
                             | Guardian email | Guardian | PII |
                             | Jersey number, position, nickname | Athlete | PII (low sensitivity) |
                             | Attendance status | Athlete | Behavioral record |
                             | Organization / school / club name | Coach/user | Institutional PII |
                             | Game roster lineups (JSONB) | Athlete | Derived record |
                             | `created_at` timestamps | All records | Metadata |

                             ### 3.2 Data at Rest

                             - Supabase PostgreSQL database (hosted on Supabase cloud infrastructure)
                             - `shared_preferences` device-local storage (JSON, unencrypted by default on Android/iOS)

                             ### 3.3 Data in Transit

                             - All Supabase API calls use HTTPS (TLS 1.2+)
                             - Realtime subscriptions use WSS (WebSocket Secure)

                             ---

                             ## 4. Security Controls — Current Implementation

                             ### 4.1 Authentication

                             - **Email/password authentication** via Supabase Auth (bcrypt password hashing server-side)
                             - **Re-authentication before sensitive operations:** `changeEmail` and `changePassword` both require the current password before allowing the change
                             - **Email normalization:** All email addresses are trimmed and lowercased before use, preventing duplicate accounts from case variations
                             - **Null-user validation on sign-up:** Guards against silent Supabase failures (rate-limit, trigger errors) returning HTTP 200 with no user object
                             - **Password-recovery flow:** Handled by `ResetPasswordScreen` reacting to the `passwordRecovery` auth event from Supabase

                             ### 4.2 Authorization & Row-Level Security (RLS)

                             - **Role-based access model:** Five roles — `owner`, `coach`, `player`, `team_parent`, `team_manager`
                             - **RLS on all tables:** Team and player queries are filtered server-side by the authenticated user's membership in `team_members`
                             - **SECURITY DEFINER RPCs for privileged operations:** `create_team`, `add_member_to_team`, `delete_account`, `change_user_email`, `link_player_to_user`,
                             `link_guardian_to_player`, `transfer_ownership`, `get_or_create_team_invite`, `redeem_team_invite`, `revoke_team_invite` — these run as the function owner, bypassing
                             client-supplied JWTs for operations that require elevated trust
                             - **Sole-owner guard:** `removeMemberFromTeam` checks for at least two owners before allowing the removal of an owner role
                             - **Client-side role checks** (defense-in-depth): `_isTeamOwner()` verifies caller role before destructive team operations; `updateMemberRole()` blocks direct promotion to       
                             `owner`

                             ### 4.3 Logging & Observability

                             - **Domain-only email logging:** `signIn` logs only the email domain on auth failure — never the full address
                             - **No full PII in logs:** Debug logs reference user IDs or domains, not names or full email addresses
                             - **Structured error messages:** RPCs surface user-readable Postgres RAISE EXCEPTION messages; internal details are caught and replaced with safe strings before display

                             ### 4.4 Offline Cache Security

                             - **Cache wipe on sign-out:** `clearCache()` calls `_cache.clearAll()` to remove all on-device data, preventing stale data exposure on shared devices (e.g., gym iPads)
                             - **TTL enforcement:** Cache entries expire after 60 minutes by default; eviction runs in the background at app launch
                             - **Key namespacing:** Cache keys use the `aod_cache_` prefix to prevent accidental overlap with other libraries

                             ### 4.5 Secrets Management

                             - Supabase credentials (`SUPABASE_URL`, `SUPABASE_ANON_KEY`) are injected at build time via `--dart-define-from-file=config.json` and are never hardcoded in source
                             - `config.json` is excluded from version control

                             ---

                             ## 5. Security & Compliance Hurdles

                             ### 5.1 COPPA (Children's Online Privacy Protection Act)

                             **Risk Level: HIGH**

                             The app collects PII from student athletes, many of whom are likely under 18 and potentially under 13. COPPA applies to operators of online services directed at children under 13
                              (or with actual knowledge they are collecting data from children under 13).

                             **Concerns:**
                             - The app collects names, email addresses, grade levels, athlete IDs, and guardian emails for minors
                             - Grade levels of 9-12 imply ages of roughly 14-18, reducing but not eliminating the COPPA risk window (e.g., a 12-year-old in 9th grade is theoretically possible; future        
                             expansion to lower grades would trigger COPPA directly)
                             - There is no age-gate or parental consent flow at sign-up
                             - Guardian email is collected but there is no formal parental consent verification mechanism

                             **Recommendations:**
                             - Add an age-verification or grade-restriction disclaimer on sign-up
                             - Implement a parental consent workflow for users under 13 if the app is ever extended to lower grades
                             - Clearly document that the app is intended for grades 9-12 (ages 14+) in the privacy policy and App Store listings

                             ---

                             ### 5.2 FERPA (Family Educational Rights and Privacy Act)

                             **Risk Level: MEDIUM-HIGH**

                             FERPA protects educational records of students at schools receiving federal funding. If AOD is used by public school coaches and stores athlete IDs, grade levels, or attendance  
                             records linked to students, it may fall under FERPA's definition of an "educational record" or a system that processes such records on behalf of a school.

                             **Concerns:**
                             - `athlete_id` fields may map directly to school-issued student IDs
                             - `grade` and `grade_updated_at` fields constitute academic-level data
                             - Attendance records (status: present/absent/late/excused) may be considered educational records if used in conjunction with school operations
                             - If coaches are school employees and AOD is used on behalf of the school, AOD could be classified as a "school official" with legitimate educational interest — requiring a      
                             formal data-sharing agreement

                             **Recommendations:**
                             - Add a terms-of-service clause clarifying the scope of data use and the relationship between AOD and educational institutions
                             - Consider a data-processing agreement (DPA) template for schools that adopt AOD formally
                             - Ensure student records can be exported and/or deleted on request (right of access and correction under FERPA)

                             ---

                             ### 5.3 GDPR / CCPA (General Data Protection / California Consumer Privacy)

                             **Risk Level: MEDIUM**

                             If any users or athletes are located in the EU or California, GDPR and/or CCPA requirements apply.

                             **Concerns:**
                             - No explicit privacy policy or consent banner is present in the current UI
                             - No mechanism to export all personal data on user request (GDPR Article 20 — data portability)
                             - Account deletion (`deleteAccount`) removes auth and public data, but it is unclear whether all derived data (game roster JSONB blobs containing player names/IDs, cache entries,
                              logs) are fully purged
                             - `shared_preferences` on-device data is not encrypted; if a device is compromised, cached PII (names, emails, roster data) may be exposed
                             - No documented data retention policy

                             **Recommendations:**
                             - Add a privacy policy accessible from the login screen
                             - Implement a "Download my data" export feature
                             - Audit what the `delete_account` RPC removes; ensure game roster JSONB entries referencing the deleted player are also scrubbed
                             - Consider encrypting `shared_preferences` data using `flutter_secure_storage` for sensitive fields
                             - Document and enforce a data retention policy (e.g., inactive accounts deleted after 2 years)

                             ---

                             ### 5.4 On-Device Cache Exposure

                             **Risk Level: MEDIUM**

                             The `OfflineCacheService` persists player PII and game roster data to `shared_preferences`, which is stored in plaintext on the device file system.

                             **Concerns:**
                             - On Android, `shared_preferences` data is stored in an XML file accessible to root users and via ADB backup on unprotected devices
                             - On iOS, `NSUserDefaults`-backed storage is generally protected by the iOS sandbox but is not encrypted at the NSFileProtection level
                             - On Web (GitHub Pages), `shared_preferences` uses `localStorage`, which is accessible to any JavaScript running on the same origin and is not encrypted
                             - Cached data includes full player names, emails, guardian emails, and athlete IDs

                             **Recommendations:**
                             - For mobile, use `flutter_secure_storage` or encrypt the cache envelope before writing to `shared_preferences`
                             - For Web, evaluate whether offline caching is necessary; if so, use IndexedDB with encryption or limit what PII is cached
                             - Reduce PII in cached payloads to the minimum necessary (e.g., cache name and jersey number but not email or athlete ID)

                             ---

                             ### 5.5 Invite Code Security

                             **Risk Level: LOW-MEDIUM**

                             Team invite codes are 6-character alphanumeric codes with an expiry time.

                             **Concerns:**
                             - A 6-character code from a typical [A-Z0-9] charset has approximately 2.2 billion combinations; without rate-limiting on the `redeem_team_invite` RPC, brute-force enumeration is
                              theoretically possible
                             - It is unclear whether the RPC enforces a single-use-per-code constraint or allows multiple members to join with the same code before it expires
                             - Anyone with the code (e.g., a forwarded group chat message) can join the team without the coach's explicit approval of each individual

                             **Recommendations:**
                             - Confirm and document rate-limiting on the `redeem_team_invite` RPC (ideally at the Supabase edge or PostgREST level)
                             - Consider adding an `accepted_by` audit log on invite redemptions
                             - Add an optional coach-approval step before the redeemed user gains full team access

                             ---

                             ### 5.6 Role Escalation

                             **Risk Level: LOW-MEDIUM**

                             **Concerns:**
                             - `updateMemberRole()` blocks client-side promotion to `owner` and requires `transferOwnership()`, but enforcement is an application-level check rather than a SECURITY DEFINER   
                             RPC
                             - A modified client could potentially bypass this check and issue a direct `UPDATE team_members SET role='owner'` if RLS does not explicitly block self-promotion or
                             promotion-to-owner by non-owners
                             - The `removeMemberFromTeam` sole-owner guard is implemented client-side (counts owners with a SELECT) rather than inside an atomic RPC, creating a potential TOCTOU
                             (time-of-check/time-of-use) race condition if two requests fire simultaneously

                             **Recommendations:**
                             - Move the owner-promotion block and the sole-owner guard into SECURITY DEFINER RPCs so they are enforced at the database layer
                             - Add an RLS policy that prevents any user from directly setting `role = 'owner'` on `team_members` without going through the `transfer_ownership` RPC

                             ---

                             ### 5.7 Supabase Anon Key Exposure (Web Target)

                             **Risk Level: LOW-MEDIUM**

                             The Supabase `ANON_KEY` is embedded in the compiled web bundle (JavaScript) at build time via `--dart-define-from-file`. On the Web target (GitHub Pages), this key is visible to 
                             anyone who inspects the JavaScript bundle.

                             **Concerns:**
                             - The anon key is designed to be public-facing and is scoped by RLS, but if RLS policies have gaps, the anon key provides a direct entry point to the Supabase API from outside   
                             the app
                             - Any user can open DevTools, extract the anon key, and make arbitrary PostgREST queries against the Supabase project's public schema

                             **Recommendations:**
                             - Regularly audit all RLS policies on every table (`players`, `teams`, `team_members`, `game_rosters`, `users`) to ensure no row is accessible without a valid authenticated      
                             session
                             - Enable Supabase's built-in rate limiting and consider adding custom rate-limit rules for auth endpoints
                             - Confirm the service role key is never present in client code or build artifacts

                             ---

                             ### 5.8 Error Message Information Leakage

                             **Risk Level: LOW**

                             **Concerns:**
                             - Some error messages passed to the UI include raw exception text: e.g., `throw Exception('Database update failed: $msg')` in `changeEmail`, and `throw Exception('Error linking  
                             player: $e')` in `linkPlayerToAccount`
                             - Raw Postgres error text can disclose schema names, constraint names, or other internal structure to end users

                             **Recommendations:**
                             - Audit all `throw Exception(... $e ...)` paths that surface raw error strings to the UI
                             - Replace with user-friendly static messages; log the raw exception only to `debugPrint` (which is stripped in release builds)

                             ---

                             ### 5.9 Missing Input Validation

                             **Risk Level: LOW**

                             **Concerns:**
                             - Email fields are normalized (trim + lowercase) but not validated against an email regex before being sent to the database
                             - Free-text fields (`firstName`, `lastName`, `organization`, `teamName`, `position`) have no maximum-length constraint enforced client-side, relying entirely on the database     
                             column constraints
                             - `jerseyNumber` is stored as a string without sanitization; if rendered in HTML (Web target), it could be a minor XSS vector

                             **Recommendations:**
                             - Add client-side email format validation before submitting auth or member-lookup requests
                             - Enforce reasonable character limits on text inputs (e.g., max 50 chars for names, max 10 for jersey numbers)
                             - Sanitize or constrain jersey number input to alphanumeric characters only

                             ---

                             ## 6. Compliance Summary Table

                             | Framework | Applicability | Current Status | Priority |
                             |---|---|---|---|
                             | COPPA | High — minor athletes likely in user base | No age gate or parental consent flow | **High** |
                             | FERPA | Medium-High — school athlete data, grade/attendance records | No DPA; no data-export feature | **High** |
                             | GDPR | Medium — EU users possible | No privacy policy; no data portability | **Medium** |
                             | CCPA | Medium — California users likely | No privacy policy; no opt-out mechanism | **Medium** |
                             | General data security | All deployments | Strong RLS + SECURITY DEFINER RPCs; cache wipe on logout | **Ongoing** |

                             ---

                             ## 7. Recommended Remediation Priorities

                             1. **Add a privacy policy** accessible from the login screen before public launch (addresses GDPR, CCPA, and App Store requirements)
                             2. **Implement parental consent or age-gate** for users under 13 (COPPA)
                             3. **Audit the `delete_account` RPC** to ensure full data deletion, including JSONB roster entries that reference the deleted player
                             4. **Encrypt on-device cache** or reduce PII stored in `shared_preferences` / `localStorage`
                             5. **Move role-enforcement logic into SECURITY DEFINER RPCs** (sole-owner guard, promotion-to-owner block)
                             6. **Audit all raw error strings** passed to the UI and replace with user-friendly messages
