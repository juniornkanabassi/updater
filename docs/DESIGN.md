# Updater design

The app should feel calm and dependable. Its main job is to show which apps need attention, explain where each update happens, and preserve the user's control over installations.

## Structure

The main window uses a native two-column NavigationSplitView. The sidebar contains the installed app list and standard search. Selecting an app opens its update details. The sidebar can be hidden, resized and restored from View; Find reveals it. Settings uses native tabs for General, Locations and Permissions. About and Licenses remain separate windows.

The standard list owns keyboard navigation, range selection and context-menu targeting. Individual update actions keep their existing explicit behaviour. Bulk actions only include eligible automatic updates, including after helper repair. Search and selection never start an update.

## Commands and feedback

Find uses Command-F and Option-Command-F. Refresh and Update All remain in the toolbar and menus. Selected rows expose actions through their context menu. Progress, failures and hand-offs use text as well as symbols. Failed updates retain their reason and a recovery action. Existing appearance preferences remain available.

## Visual rules

Use system text styles and semantic colours. Space provides the 4, 8, 12, 16, 20 and 24 point spacing scale; VisualMetrics contains shared component dimensions. Native lists, forms and toolbars own their material, control sizes and alignment. Do not position the title or rows with offsets. Icons are rasterised at display size on a serial background queue and cached by path, modification date and size.

## Verification

`script/check.sh` runs the normal three correctness lanes, the full-app grid lint and the light/dark snapshot inventory check. Snapshot fixtures render production views with injected data and services. Test windows are transparent and never activate. Each test host has a disposable home and temporary directory; no real app is updated. Native material and active-window appearance remain distinct from offscreen rendering evidence.
