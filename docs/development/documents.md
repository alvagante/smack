# Documents

Work has two views: Recent and Browse. A selected document opens its own Detail Page, participates in Page History and keeps Documents selected in the sidebar. The Direct Build provides these pages.

## Available data

Recent uses Spotlight file paths, types, sizes, content-change and creation dates, last-opened dates, titles, authors, tags and page counts. Metadata is optional and may lag behind the actual file. Modified is an indexed content-change date, not a recorded save event. [Apple's last-opened metadata](https://developer.apple.com/documentation/coreservices/kmditemlastuseddate) is maintained separately by LaunchServices.

Existing Project paths provide links to the deepest already discovered containing Project. Documents does not trigger repository discovery, Git inspection or process File Activity. User Home already supplies bounded directory listings and stat information; Browse and the Document Detail Page reuse those readers.

## Recent

A single-line table shows Name, Kind, Location, Modified, Created, Last opened and Size. Every header sorts its column and toggles direction. Unavailable dates and sizes remain last in either direction. Icons come from content types, with extension fallbacks for office documents, spreadsheets, presentations, source files, images, audio, video and archives.

Search matches name/path, kind, title, author, tags and location. Filters select kind, location and modification within 7, 30 or 90 days. Scope shortcuts cover Home, Documents, Desktop, Downloads, Pictures and iCloud Drive; a folder picker covers other providers, project folders and mounted volumes. The chosen view, filters, scope and order stay in memory across Detail Page navigation.

Counts and known size describe the loaded sample. The bounded discovery warning remains explicit: this is not necessarily the globally newest 500 files. Narrowing the scope or date range changes the Spotlight query; other filters operate on the loaded sample.

## Browse

Documents, Projects/Files and User Home render the same `FolderBrowserView`, extracted from User Home. It provides parent navigation, the current path, filtering, entry counts, Finder actions, file sizes and symbolic-link labels. Documents, User Home and Projects also share `FileInspectionView`: a full-path heading, toolbar, stat fields and bounded text contents (or directory listing). Documents adds Open, Preview, Open With, Reveal in Finder, Share, Copy Contents/Path/File URL and Document Details. Its horizontal file column stays between 230 and 320 points so the inspection pane receives the remaining width. Narrow windows use the vertical split.

The shared native SwiftUI List supports selection, double-click to enter folders or open files, context menus, URL drag-out and Space for Quick Look. A resizable split view shows the selected file and its actions; a vertical split is used at narrow widths. Locations and parent navigation cover ordinary folders independently of Spotlight, its date filter and its result cap. Dotfiles are hidden.

Quick Look is explicit: select a file and press Space or Preview. Quick Look does not start on selection. Selection reads stat information and bounded text through the same reader used by Projects and User Home. Its native view disables media autoplay, releases the preview on dismantling, and disappears when the Panel hides or the selection changes.

## Document Detail Page

The identity header shows the type icon, full name, path, kind, tags, known size and page count. Created, Modified and Last opened provide a compact chronology.

Document fields retain exact dates and descriptive metadata. File on disk adds current stat information: type, size, allocated bytes, owner/group, permissions, creation/modification/access/change times, links, inode, device, flags and symbolic-link target when present. A failed stat remains an explicit unavailable result.

Additional indexed fields appear only when available: description, comment, subject, keywords, languages, organizations, creator, version, pixel dimensions, duration, codecs, audio bit rate and download origins. Text values are capped at 2,048 characters and arrays at 16 values. Download origins are displayed as text; they are not fetched.

Actions are Open, Preview, Open With, Reveal in Finder, Share, Copy Path, Copy File URL and the related Project link. Open With queries the available applications only when clicked. Open errors are surfaced. Sharing uses the native share picker and requires the user's choice.

## Cost

Recent discovery is unchanged: one fixed /usr/bin/mdfind call per uncached request, capped at 8 seconds and 512 KiB stdout/stderr, followed by at most 2,000 metadata candidates and a two-second cooperative inspection deadline. At most 500 records are retained. Complete NUL framing, deduplication, cancellation and the existing slow Inventory Cache apply. There are no timers, watchers or history writes.

Browse reads only its current directory through UserHomeCollector: at most 5,000 entries, with existing cooperative one-second budgets for reading names and metadata. One listing is held while Browse is mounted. Changing folder or Refresh replaces the listing; hiding the Panel or leaving the view cancels work. It performs no recursive scan and launches no subprocess.

A Document Detail Page performs one stat and a fixed set of local metadata reads for one file on entry, Refresh or resuming visibility. It retains one inspection and launches no subprocess. Individual filesystem or metadata operations can exceed cooperative deadlines, particularly on external/network volumes.

Estimated incremental cost of the two-view revision: a few MB for one bounded folder listing, a small per-file inspection, no scheduled wakeups and no added history bytes. Quick Look has one explicit preview at a time; macOS and installed providers control its rendering memory, helper processes and caches. Preview, Open and sharing can read file contents and download cloud files. Smack does not start Quick Look, Open or sharing during discovery or selection alone. The selected-item text reader can read file contents and trigger cloud-provider downloads, as in Projects and User Home.

## Validation and measurement

Tests cover type-specific icons, sortable optional metadata, search, locations, complete-path parsing, deduplication, unavailable results, cache reuse, cancellation, explicit reader invocation and Document Detail Page navigation. Rendering exercises Recent, selected-file Browse and full Document details at 480, 620 and 1100 point widths in light and dark appearances.

The initial release discovery benchmark on 2026-11-10 took 4.439 seconds for Home over 30 days: 500 files, sample limit reached, no error. This revision does not change that collector.

The ten-minute whole-app before/after measurement remains pending. An existing Smack instance was not replaced or duplicated. Quick Look provider resource use has not been characterized by that discovery-only benchmark.

Final two-view validation: 694 serial tests passed in a clean HEAD snapshot with only Documents changes applied. After the last preview-selection and layout refinements, 35 focused tests passed, including the opt-in native Quick Look test with a generated RTF file. App Store compilation passed. Isolated validation excluded concurrent Summary and window changes that temporarily broke the shared build.

Visual review: Recent, Browse and Detail Pages were inspected at 480, 620 and 1100 points in both appearances. The view selector moves below the title to preserve readability in narrow windows. Functional alignment 8/10, hierarchy 8/10, craft 8/10, functionality 8/10 and originality 7/10, using the existing app components and native browser controls.

## Summary tile

The Direct Build Summary includes an arrangeable Documents tile, two columns by default. It displays up to five files from the last Documents inventory, most recently modified first, with type icons, relative dates and links to Document Detail Pages. Its heading opens Recent. Before discovery it offers Explore documents; visiting Documents loads the inventory through the existing page task. Summary does not start discovery or previews, add timers, read files or write history. It retains only five references to already collected records during rendering. Limited inventories are labelled as samples.

Summary tile validation: 30 Documents/navigation/layout tests passed; 10 tile/layout checks passed after removing redundant sorting. Empty and populated tiles were rendered at one- and two-column widths in both appearances. App Store product compilation passed. The tile does not change collection behavior.

Shared browser validation: 37 focused Documents, User Home and resource-budget tests passed. The shared list was rendered from 230 to 480 points, and Documents at 480, 620 and 1100 points in light and dark appearances. Visual inspection confirmed the compact vertical split and wide horizontal split. The full serial suite passed all 716 tests, and the App Store product build passed. Browser extraction leaves listing, inspection and preview collection unchanged.

The stat/content revision adds one selection-driven UserHomeMonitor inspection in Documents, reusing the existing 1 MiB text limit and bounded directory long-listing reader. One inspection is retained, replaced on selection, and cleared when hidden. CPU and disk reads occur only on selection, with no periodic work, subprocesses, history writes or scheduled wakeups. The ten-minute whole-app release comparison is still pending.

Stat/content pane validation: all 718 serial tests passed, including 39 focused Documents, User Home and resource-budget tests. App Store product compilation passed. Populated stat/content panes and action toolbars were inspected at 480 and 1100 points in light/dark appearances; rendering tests also cover 620 points. The selected-item inspector cancels before reading when its task is already cancelled.
