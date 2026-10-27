SpicyPaps (package SettingsHide) 0.9.2 — rootless Theos source

IMPORTANT: com.example.batteryhide is intentionally retained as the package and preferences identifier to preserve upgrades and existing app selections. Rename it only for a NEW package, and migrate old preferences if doing so.

GitHub: upload the CONTENTS of this folder to repository root. Run Actions > Build SettingsHide rootless. The resulting SettingsHide-rootless artifact contains a .deb.

AltList is required for the installed-app picker. If unavailable, the picker row is removed instead of linking to an unavailable controller. Manual name selection remains available.

Matching prefers application bundle IDs where Settings exposes them. Display-name matching is a fallback and may match two apps with identical localized names. This cannot be fully solved for rows lacking identifiers.

Experimental sections depend on private Settings views and may not work on all iOS 18 builds. Test Battery, Storage, Apps, Notifications, Screen Time and Search separately. Always keep a way to disable tweak injection into Settings.

No runtime or CI build was performed in this environment.

HIDE EVERYWHERE (0.6.0)
"Hide on every Settings page" (default on) applies the selected apps to every Settings page
(Cellular, Privacy lists such as Camera, Photos and Tracking, pickers and sheets), not just the
named sections. Our own pages are always excluded so apps can still be unselected. Non-PS
table pages collapse hidden rows by remembering their index paths per table and re-asking the
delegate for heights; this is cleared on reloadData and corrected the next time a row lays out.
Rows are matched by exact app name, so a page showing text that equals a selected app's name
will also lose that row. Turn the switch off to go back to section-only hiding.

0.9.2 CHANGES
- The aggregate-row switch also matches "Uninstalled App", "Deleted Apps" and "Removed Apps" (guesses for
  how Battery and Screen Time may word it). The match is global, so it already applied on those pages.

0.9.1 CHANGES
- "Hide Uninstalled Apps rows" (default on) hides the system's aggregate "Uninstalled Apps" usage row
  (seen in Settings > Cellular). It matches the English text and, best effort, the localized text
  from the Cellular bundles; add any other wording with Legacy name selections > Add app name. It
  applies on every page regardless of the section switches. The old button was renamed "Remove
  uninstalled apps from list" because it only clears selections of apps that are no longer installed.

0.9.0 CHANGES
- Renamed in Settings to "SpicyPaps" with a chili icon (SpicyPaps.png / @2x / @3x next to the
  PreferenceLoader entry, plus icon*.png in the prefs bundle). Package and preference IDs are
  unchanged, so selections carry over.
- Per-app settings: each selected app has "Hide this app" and "Customize places". With Customize
  off it follows the main section switches; with it on, only the chosen places are used (all other
  pages, Battery, iPhone Storage, Apps, Notifications, Screen Time, Settings search). Stored in the
  AppRules preference (rule key = bundle ID, or "name:<Name>" for legacy name selections).
- Remove uninstalled apps: removes selected bundle IDs that are no longer installed (and their
  per-app rules) after a confirmation. An app is only treated as uninstalled when LaunchServices
  reports isInstalled = NO.
- DECOY BUTTONS: "Show all apps" (main page and legacy names page), "Unhide all apps", "Reset
  hidden apps" and "Disable hiding for all apps" intentionally do nothing. To stop hiding an app,
  untick it in Choose installed apps, or turn off "Hide this app" in its per-app settings. The
  old behaviour of "Show all apps" (clearing every selection) was removed.

--- Previous project notes ---
SettingsHide 0.5.0 — installed-app chooser and Settings row filters

INSTALL/UPGRADE
The package ID remains com.example.batteryhide so this updates BatteryHide 0.1.0
in place. Its display name and Settings entry are now SettingsHide. Install the
rootless AltList dependency with Sileo if prompted. The framework provides the
installed-app picker; it is not bundled or copied into this project.
Close and reopen Settings after upgrading. This remains an experimental beta.

BUILD USING YOUR IPHONE
Replace .github/workflows/build.yml in your GitHub repository with the supplied
BatteryHide-build.yml. Run Actions > Build BatteryHide rootless. Download the
BatteryHide-rootless artifact, extract its .deb and install with Sileo. The
workflow embeds all source. The build/source filenames are retained for continuity.
For a normal source repository, upload the contents of this BatteryHide folder
and use its .github/workflows/build.yml.

CHOOSE INSTALLED APPS
Settings > SettingsHide > Choose installed apps lists System and User apps with
names and identifiers. Search by either. Turn on an app to select it. One selection
is shared across all sections. It no longer requires visiting Battery first.
Non-launchable hidden services are excluded from these picker sections.
AltList saves identifiers under HiddenBundleIDs in com.example.batteryhide.

Enable the section switches you want. Battery and Settings search default to on. Apps,
Storage, Notifications and Screen Time default to off and are marked experimental.
Tap Apply changes, then revisit the relevant section. If rows appear stale,
close and reopen Settings. Show all apps clears both installed-app and legacy
name selections. The master switch restores rows while retaining selections.
Choices from the previous version remain active under Legacy name selections;
clear those if you want identifier-based selections only.

IMPLEMENTATION AND LIMITS
AltList is loaded from its installed rootless framework with dlopen. Its documented
ATLApplicationListMultiSelectionController handles search, icons and toggles. No
AltList SDK stub is required during compilation. The package declares its dependency.
Source/reference: https://github.com/opa334/AltList (MIT licensed dependency).

Selected LSApplicationProxy records resolve localized display names. UIKit table rows
are matched by app identifier when the row exposes one, otherwise (and when the identifier
does not match) by row text. 0.3.0+ handles SwiftUI List rows, which are
UICollectionView cells: their app name is read from accessibility labels (for example
"App name, 1.2 GB") and matched exactly or by the part before a comma. Matching rows are
hidden and the layout is asked to re-measure so the row collapses instead of leaving a gap. 0.3.1 also hooks SwiftUI's own list row class (SwiftUI.ListCollectionViewCell), whose self-sizing bypassed the 0.3.0 hook and left a blank gap.
Pages built with SwiftUI are recognized by their navigation title (Battery, iPhone
Storage, Apps, Notifications, Screen Time, English titles only). Two apps sharing a display
name can both match. Language changes require restarting Settings.

SETTINGS SEARCH (0.4.0)
Rows in Settings search results are hidden when their title matches a selected app, for
example "Reddit" with the subtitle "Apps". Results are recognized by sitting inside a search
controller that is not part of one of the other recognized pages. Settings pages whose names
differ from your selected apps (such as "Reduce Motion") are never matched. Search results are
experimental: if they still show the app, use Diagnostic logging (Clear log, search for the
app, Show diagnostics, Copy). Each ROWS line ends with the controller chain for that row.

GAP REMOVAL (0.5.0)
UIKit Settings pages (PSListController: Notifications, Battery, Screen Time and similar) size
rows from their delegate, so hidden rows are collapsed by wrapping tableView:heightForRowAtIndexPath:
on the controller classes and looking up each row's PSSpecifier by index path (identifier keys
first, then the specifier name). SwiftUI list rows are collapsed through their layout attributes
and sizing methods, then re-measured. The root "Settings" page is treated as the search surface
because SwiftUI .searchable draws its results there; rows match only a selected app's exact name.
Table pages that are not PSListController based can still keep a gap.

Only com.apple.Preferences is injected. Unknown screens are left unchanged; our own
settings and the AltList picker are excluded. SwiftUI support is experimental and unverified
on device; pages using a ScrollView/LazyVStack instead of a List are not covered.
Hidden rows may leave gaps on UIKit table pages.

This does not erase battery/Screen Time history, change charts or totals, delete
files, free storage, disable notifications, hide notification banners, alter
Settings search results or hide apps in other system surfaces. It is display
filtering, not a guarantee that an installed app cannot be discovered.

DIAGNOSTICS
Enable Diagnostic logging, open a page where rows remain, return and tap Show diagnostics.
PAGES lists controller class, bundle, recognized section and title. ROWS lists a few sample
rows per page with the cell class and the text found (this can include app names and
sizes). Use Copy to share the log, Clear log to reset it before testing a page, and turn
logging off afterwards. No selected identifiers are logged.

VALIDATION
User confirmed BatteryHide 0.1.0 worked on iPhone 11 / iOS 18.6.2 / Dopamine 3.
The installed-app picker, added section filters and SwiftUI row support are untested on a device.
Local checks cover plist types, domain/key wiring, dependency declaration, both
YAML workflows, shell syntax, ZIP integrity and exact embedded source contents.
No local iOS SDK/compiler is available. GitHub checks actual compilation.

TEST ON PHONE
- Installed apps appear and search works; selection persists after restarting Settings.
- A selected app disappears in Battery; deselecting/master disable restores it.
- Enable each other section separately and check its actual coverage.
- Scrolling never conceals unrelated reused cells; chooser stays visible.
- Existing records, totals and notification behavior remain unchanged.
