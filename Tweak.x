#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "BHPreferences.h"
#import "BHInstalledApps.h"

static NSSet<NSString *> *hiddenNames;
static NSMutableSet<NSString *> *knownNames;
static NSHashTable<UIView *> *trackedCells;
static NSMutableDictionary<NSString *, NSNumber *> *cellLogCounts;
static BOOL enabled;
static NSDictionary<NSString *, NSNumber *> *sectionFlags;
static NSSet<NSString *> *hiddenIDs;
static NSDictionary<NSString *, NSString *> *nameToKey;   // display name -> rule key
static NSDictionary *appRules;                            // rule key -> per-app settings
static BOOL anyCustomRules;
static BOOL diagnosticLogging;
static BOOL discoveryQueued;
static char savedHiddenKey;
static char invalidatedKey;
static const CGFloat kCollapsedHeight = 0.01;
static NSMutableSet<NSString *> *heightWrapped;

// Runtime placeholder for SwiftUI's private list row class (hooked by name at startup).
@interface BHListCell : UICollectionViewCell
@end

#pragma mark - Section detection

static NSString *SectionForTitle(NSString *title) {
    NSString *t = [[title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!t.length) return nil;
    if ([t isEqualToString:@"battery"]) return @"Battery";
    if ([t isEqualToString:@"storage"] || [t hasSuffix:@" storage"]) return @"Storage";
    if ([t isEqualToString:@"apps"]) return @"Apps";
    if ([t isEqualToString:@"notifications"]) return @"Notifications";
    if ([t isEqualToString:@"screen time"]) return @"ScreenTime";
    return nil;
}

static NSString *TitleForController(UIViewController *controller) {
    NSString *title = controller.title;
    if (!title.length) title = controller.navigationItem.title;
    return title;
}

static NSString *ClassSectionForController(UIViewController *controller) {
    NSString *name = NSStringFromClass(controller.class).lowercaseString;
    NSString *bundle = [NSBundle bundleForClass:controller.class].bundlePath.lastPathComponent.lowercaseString;
    if ([bundle containsString:@"batteryhide"] || [bundle containsString:@"settingshide"] || [name hasPrefix:@"atl"] || [name hasPrefix:@"bh"]) return @"OwnSettings";
    if ([bundle containsString:@"battery"] || [bundle containsString:@"powerusage"] || [name containsString:@"battery"]) return @"Battery";
    if ([bundle containsString:@"screentime"] || [name containsString:@"screentime"] || [name hasPrefix:@"stusagereport"] || [name hasPrefix:@"stappusage"]) return @"ScreenTime";
    if ([bundle containsString:@"storage"] || [name containsString:@"storage"] || [name hasPrefix:@"psusage"]) return @"Storage";
    if ([bundle containsString:@"notificationssettings"] || [bundle containsString:@"bulletinboardsettings"] || [name hasPrefix:@"bbsettings"] || [name containsString:@"notificationssettings"]) return @"Notifications";
    if ([bundle containsString:@"appssettings"] || [bundle containsString:@"applicationsettings"] || [name containsString:@"applist"] || [name containsString:@"appssettings"] || [name containsString:@"applicationlist"]) return @"Apps";
    return nil;
}

// Class names and bundle paths never change, so the class-based answer is cached per class.
static NSString *SectionForController(UIViewController *controller) {
    static NSMutableDictionary<NSString *, NSString *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *className = NSStringFromClass(controller.class);
    NSString *section = cache[className];
    if (!section) {
        section = ClassSectionForController(controller) ?: @"";
        cache[className] = section;
    }
    if (section.length) return section;
    // SwiftUI pages are generic hosting controllers, so fall back to the navigation title.
    NSString *title = TitleForController(controller);
    NSString *lower = title.lowercaseString;
    if ([lower containsString:@"settingshide"] || [lower containsString:@"spicypaps"] || [lower isEqualToString:@"choose installed apps"]) return @"OwnSettings";
    return SectionForTitle(title);
}

static BOOL IsSearchName(NSString *name) {
    NSString *n = name.lowercaseString;
    return [n containsString:@"searchcontroller"] || [n containsString:@"searchresults"];
}

// Returns the section a row belongs to. Our own pages always win; a recognized page wins over
// search; rows inside a search controller that is not part of a recognized page are "Search".
static NSString *SectionForViewEx(UIView *view, BOOL *own) {
    if (own) *own = NO;
    NSString *found = nil;
    BOOL inSearch = NO;
    NSString *nearestTitle = nil;
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if (r != view && [r isKindOfClass:UIView.class] && IsSearchName(NSStringFromClass(r.class))) inSearch = YES;
        if (![r isKindOfClass:UIViewController.class]) continue;
        if ([r isKindOfClass:UISearchController.class] || IsSearchName(NSStringFromClass(r.class))) inSearch = YES;
        if (!nearestTitle) nearestTitle = TitleForController((UIViewController *)r) ?: @"";
        NSString *section = SectionForController((UIViewController *)r);
        if ([section isEqualToString:@"OwnSettings"]) { if (own) *own = YES; return nil; }
        if (section && !found) found = section;
    }
    if (found) return found;
    // SwiftUI .searchable shows results inside the root "Settings" page itself.
    if (inSearch || [[nearestTitle lowercaseString] isEqualToString:@"settings"]) return @"Search";
    return @"Everywhere";
}

static NSString *SectionForView(UIView *view) { return SectionForViewEx(view, NULL); }

// A section is active when its own switch is on or "every page" is on.
static BOOL SectionActive(NSString *section) {
    return section && ([sectionFlags[section] boolValue] || [sectionFlags[@"Everywhere"] boolValue]);
}

// Per-app rule: follows the global section switches unless the app has "Custom" places, and can be switched off.
static BOOL AppRuleHides(NSString *key, NSString *section) {
    NSDictionary *rule = appRules[key];
    if (![rule isKindOfClass:NSDictionary.class]) return SectionActive(section);
    id enabledValue = rule[@"Enabled"];
    if (enabledValue && ![enabledValue boolValue]) return NO;
    if (![rule[@"Custom"] boolValue]) return SectionActive(section);
    NSDictionary *places = rule[@"Places"];
    id place = [places isKindOfClass:NSDictionary.class] ? places[section] : nil;
    return place ? [place boolValue] : YES;
}

static BOOL SectionMayHide(NSString *section) {
    return section && (SectionActive(section) || anyCustomRules);
}

#pragma mark - Reading row text (UIKit labels and SwiftUI accessibility)

static void CollectStrings(id node, NSMutableArray<NSString *> *out, int depth) {
    if (!node || depth > 6 || out.count >= 12) return;
    @try {
        if ([node respondsToSelector:@selector(accessibilityLabel)]) {
            NSString *label = [node accessibilityLabel];
            if ([label isKindOfClass:NSString.class] && label.length && ![out containsObject:label]) [out addObject:label];
        }
        if ([node isKindOfClass:UILabel.class]) {
            NSString *text = ((UILabel *)node).text;
            if (text.length && ![out containsObject:text]) [out addObject:text];
        }
        if ([node isKindOfClass:UIView.class]) {
            for (UIView *child in ((UIView *)node).subviews) CollectStrings(child, out, depth + 1);
        }
        if ([node respondsToSelector:@selector(accessibilityElements)]) {
            NSArray *elements = [node accessibilityElements];
            if ([elements isKindOfClass:NSArray.class])
                for (id element in elements) CollectStrings(element, out, depth + 1);
        }
        if ([node respondsToSelector:@selector(accessibilityElementCount)] && [node respondsToSelector:@selector(accessibilityElementAtIndex:)]) {
            NSInteger count = [node accessibilityElementCount];
            if (count != NSNotFound && count > 0 && count <= 12)
                for (NSInteger i = 0; i < count; i++) CollectStrings([node accessibilityElementAtIndex:i], out, depth + 1);
        }
    } @catch (NSException *exception) { (void)exception; }
}

// Returns the rule key of the selected app whose name matches the string, if any.
static NSString *KeyForString(NSString *string) {
    NSCharacterSet *trim = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *text = [string stringByTrimmingCharactersInSet:trim];
    if (!text.length) return nil;
    NSString *key = nameToKey[text];
    if (key) return key;
    // Accessibility labels often read "App name, 1.2 GB".
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",;\n"]];
    if (parts.count > 1)
        for (NSString *part in parts) {
            key = nameToKey[[part stringByTrimmingCharactersInSet:trim]];
            if (key) return key;
        }
    return nil;
}

static NSString *KeyForRow(UIView *cell) {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    CollectStrings(cell, strings, 0);
    for (NSString *string in strings) {
        NSString *key = KeyForString(string);
        if (key) return key;
    }
    return nil;
}

#pragma mark - Hiding

static NSArray<NSString *> *IdentifierKeys(void) {
    return @[@"applicationIdentifier", @"bundleIdentifier", @"appBundleID", @"bundleID", @"applicationBundleIdentifier"];
}

static BOOL ShouldHideRow(UIView *cell) {
    if (!enabled || (!hiddenNames.count && !hiddenIDs.count)) return NO;
    NSString *section = SectionForView(cell);
    if (!SectionMayHide(section)) return NO;
    NSString *appKey = nil;
    if ([cell isKindOfClass:UITableViewCell.class]) {
        id specifier = BHObject(cell, @"specifier");
        for (NSString *key in IdentifierKeys()) {
            id identifier = BHObjectWithArgument(specifier, @"propertyForKey:", key);
            if ([identifier isKindOfClass:NSString.class] && [identifier length] && [hiddenIDs containsObject:identifier]) { appKey = identifier; break; }
        }
    }
    // Rows without a matching identifier (including SwiftUI rows) fall back to their visible/accessibility text.
    if (!appKey) appKey = KeyForRow(cell);
    return appKey && AppRuleHides(appKey, section);
}

static void RestoreCell(UIView *cell) {
    NSNumber *original = objc_getAssociatedObject(cell, &savedHiddenKey);
    if (!original) return;
    objc_setAssociatedObject(cell, &savedHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.hidden = original.boolValue;
}

static void InvalidateCollectionLayout(UIView *cell) {
    for (UIView *v = cell.superview; v; v = v.superview) {
        if ([v isKindOfClass:UICollectionView.class]) {
            [((UICollectionView *)v).collectionViewLayout invalidateLayout];
            return;
        }
    }
}

static void HideRow(UIView *cell) {
    objc_setAssociatedObject(cell, &savedHiddenKey, @(cell.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.hidden = YES;
    // Ask collection layouts to re-measure once so the row collapses instead of leaving a gap.
    if ([cell isKindOfClass:UICollectionViewCell.class] && !objc_getAssociatedObject(cell, &invalidatedKey)) {
        objc_setAssociatedObject(cell, &invalidatedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{
            [cell invalidateIntrinsicContentSize];
            [((UICollectionViewCell *)cell).contentView invalidateIntrinsicContentSize];
            InvalidateCollectionLayout(cell);
        });
    }
}

// A row counts as collapsed if it is already hidden or matches now (text may not be ready at first sizing).
static BOOL RowIsCollapsed(UIView *cell) {
    return objc_getAssociatedObject(cell, &savedHiddenKey) != nil || ShouldHideRow(cell);
}

// Collapses a hidden collection row's measured size so the list does not keep a blank gap.
static void CollapseAttributes(UIView *cell, UICollectionViewLayoutAttributes *attributes) {
    if (!attributes || !RowIsCollapsed(cell)) return;
    CGRect frame = attributes.frame;
    frame.size.height = kCollapsedHeight;
    attributes.frame = frame;
    attributes.hidden = YES;
}

// UIKit Settings pages (PSListController) size rows from their delegate, so hidden rows are collapsed there
// by looking the row's PSSpecifier up by index path (no cell is needed).
static BOOL ShouldHideSpecifierAt(id controller, NSIndexPath *indexPath) {
    if (!enabled || !indexPath || (!hiddenNames.count && !hiddenIDs.count)) return NO;
    if (![controller isKindOfClass:UIViewController.class] || ![(UIViewController *)controller isViewLoaded]) return NO;
    BOOL own = NO;
    NSString *section = SectionForViewEx(((UIViewController *)controller).view, &own);
    if (own || !SectionMayHide(section)) return NO;
    id specifier = BHObjectWithArgument(controller, @"specifierAtIndexPath:", indexPath);
    if (!specifier) return NO;
    for (NSString *key in IdentifierKeys()) {
        id identifier = BHObjectWithArgument(specifier, @"propertyForKey:", key);
        if ([identifier isKindOfClass:NSString.class] && [identifier length] && [hiddenIDs containsObject:identifier]) return AppRuleHides(identifier, section);
    }
    id name = BHObject(specifier, @"name");
    NSString *appKey = [name isKindOfClass:NSString.class] ? KeyForString(name) : nil;
    return appKey && AppRuleHides(appKey, section);
}

typedef CGFloat (*BHHeightIMP)(id, SEL, UITableView *, NSIndexPath *);

static BOOL ClassOwnsMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    BOOL owns = NO;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) if (method_getName(methods[i]) == selector) { owns = YES; break; }
    free(methods);
    return owns;
}

static BOOL GenericRowHidden(UITableView *table, NSIndexPath *indexPath);

static void EnsureHeightHook(Class cls) {
    SEL selector = @selector(tableView:heightForRowAtIndexPath:);
    if (!heightWrapped) heightWrapped = [NSMutableSet set];
    NSString *key = NSStringFromClass(cls);
    if ([heightWrapped containsObject:key]) return;
    [heightWrapped addObject:key];
    BOOL wrappedAny = NO;
    for (Class c = cls; c && c != NSObject.class; c = class_getSuperclass(c)) {
        if (!ClassOwnsMethod(c, selector)) continue;
        if (c != cls) {
            NSString *superKey = NSStringFromClass(c);
            if ([heightWrapped containsObject:superKey]) { wrappedAny = YES; continue; }
            [heightWrapped addObject:superKey];
        }
        Method method = class_getInstanceMethod(c, selector);
        BHHeightIMP original = (BHHeightIMP)method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^CGFloat(id controller, UITableView *tableView, NSIndexPath *indexPath) {
            if (ShouldHideSpecifierAt(controller, indexPath) || GenericRowHidden(tableView, indexPath)) return kCollapsedHeight;
            return original(controller, selector, tableView, indexPath);
        }));
        wrappedAny = YES;
    }
    if (!wrappedAny) {
        class_addMethod(cls, selector, imp_implementationWithBlock(^CGFloat(id controller, UITableView *tableView, NSIndexPath *indexPath) {
            return (ShouldHideSpecifierAt(controller, indexPath) || GenericRowHidden(tableView, indexPath)) ? kCollapsedHeight : tableView.rowHeight;
        }), "d@:@@");
    }
}

static UITableView *TableViewFor(UIView *cell);
static char hiddenRowsKey;
static char updatePendingKey;

static BOOL GenericRowHidden(UITableView *table, NSIndexPath *indexPath) {
    NSSet *rows = objc_getAssociatedObject(table, &hiddenRowsKey);
    return indexPath && [rows containsObject:indexPath];
}

static void RequeryHeights(UITableView *table) {
    if (objc_getAssociatedObject(table, &updatePendingKey)) return;
    objc_setAssociatedObject(table, &updatePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(table, &updatePendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [table beginUpdates];
        [table endUpdates];
    });
}

static void MarkTableRow(UITableViewCell *cell, BOOL hidden) {
    UITableView *table = TableViewFor(cell);
    NSIndexPath *indexPath = table ? [table indexPathForCell:cell] : nil;
    if (!indexPath) return;
    NSMutableSet *rows = objc_getAssociatedObject(table, &hiddenRowsKey);
    if (hidden) {
        if (!rows) { rows = [NSMutableSet set]; objc_setAssociatedObject(table, &hiddenRowsKey, rows, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        if ([rows containsObject:indexPath]) return;
        [rows addObject:indexPath];
        if (table.delegate) EnsureHeightHook(object_getClass(table.delegate));
        RequeryHeights(table);
    } else if ([rows containsObject:indexPath]) {
        [rows removeObject:indexPath];
        RequeryHeights(table);
    }
}

static void PrepareController(UIViewController *controller) {
    if ([controller respondsToSelector:NSSelectorFromString(@"specifierAtIndexPath:")]) EnsureHeightHook(controller.class);
}

static UITableView *TableViewFor(UIView *cell) {
    for (UIView *v = cell.superview; v; v = v.superview) if ([v isKindOfClass:UITableView.class]) return (UITableView *)v;
    return nil;
}

#pragma mark - Learning and diagnostics

static void QueueKnownName(NSString *name) {
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || name.length > 150 || knownNames.count >= 2000 || [knownNames containsObject:name]) return;
    [knownNames addObject:name];
    if (discoveryQueued) return;
    discoveryQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        discoveryQueued = NO;
        [knownNames addObjectsFromArray:BHNames(@"KnownNames")];
        BHWrite(@"KnownNames", [[knownNames allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]);
    });
}

static void ReadLabels(UIView *root, NSMutableArray<NSString *> *labels, BOOL *hasImage) {
    if (root.hidden || root.alpha < 0.01) return;
    if ([root isKindOfClass:UIImageView.class] && ((UIImageView *)root).image) *hasImage = YES;
    if ([root isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)root).text;
        if (text.length) [labels addObject:text];
    }
    for (UIView *child in root.subviews) ReadLabels(child, labels, hasImage);
}

static void LearnRow(UITableViewCell *cell) {
    BOOL hasImage = cell.imageView.image != nil;
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    ReadLabels(cell.contentView, labels, &hasImage);
    if (!hasImage) return; // Only learn icon-bearing rows, not chart/section labels.
    NSString *candidate = cell.textLabel.text;
    if (!candidate.length) {
        for (NSString *label in labels) {
            if ([label rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound &&
                ![label containsString:@"%"] && ![label containsString:@"\n"]) { candidate = label; break; }
        }
    }
    if (candidate.length) QueueKnownName(candidate);
}

// Logs a few sample rows per (cell class, controller, title) so unsupported pages can be identified.
// Written without a change notification so logging can never trigger a refresh loop.
static void LogCell(UIView *cell, NSString *section) {
    NSString *title = nil, *controllerName = nil;
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    BOOL inSearch = NO;
    for (UIResponder *r = cell; r; r = r.nextResponder) {
        if (IsSearchName(NSStringFromClass(r.class))) inSearch = YES;
        if (![r isKindOfClass:UIViewController.class]) continue;
        NSString *className = NSStringFromClass(r.class);
        if (chain.count < 8) [chain addObject:className.length > 40 ? [className substringToIndex:40] : className];
        if (!controllerName) controllerName = className;
        if (!title.length) title = TitleForController((UIViewController *)r);
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%d", NSStringFromClass(cell.class), controllerName, title, inSearch];
    NSUInteger seen = [cellLogCounts[key] unsignedIntegerValue];
    if (seen >= 6) return;
    cellLogCounts[key] = @(seen + 1);
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    CollectStrings(cell, strings, 0);
    NSString *line = [NSString stringWithFormat:@"%@ | %@ | title=%@ | %@%@ | %@ | chain=%@", NSStringFromClass(cell.class), controllerName ?: @"-", title ?: @"-", section ?: @"Unrecognized", inSearch ? @" [search]" : @"",
        strings.count ? [strings componentsJoinedByString:@" ¦ "] : @"(no text found)", [chain componentsJoinedByString:@" > "]];
    if (line.length > 700) line = [line substringToIndex:700];
    NSMutableArray *lines = [BHNames(@"CellDiagnostics") mutableCopy];
    if ([lines containsObject:line]) return;
    [lines addObject:line];
    if (lines.count > 40) [lines removeObjectAtIndex:0];
    CFPreferencesSetAppValue(CFSTR("CellDiagnostics"), (__bridge CFArrayRef)lines, CFSTR("com.example.batteryhide"));
    CFPreferencesAppSynchronize(CFSTR("com.example.batteryhide"));
}

#pragma mark - Refresh

static void RefreshVisibleRows(void) {
    CFPreferencesAppSynchronize(CFSTR("com.example.batteryhide"));
    enabled = [BHRead(@"Enabled", @YES) boolValue];
    nameToKey = BHNameToRuleKey();
    hiddenNames = [NSSet setWithArray:nameToKey.allKeys];
    hiddenIDs = [NSSet setWithArray:BHNames(@"HiddenBundleIDs")];
    id storedRules = BHRead(@"AppRules", @{});
    appRules = [storedRules isKindOfClass:NSDictionary.class] ? storedRules : @{};
    anyCustomRules = NO;
    for (id rule in appRules.allValues)
        if ([rule isKindOfClass:NSDictionary.class] && [rule[@"Custom"] boolValue]) { anyCustomRules = YES; break; }
    diagnosticLogging = [BHRead(@"DiagnosticLogging", @NO) boolValue];
    [cellLogCounts removeAllObjects];
    NSMutableDictionary *flags = [NSMutableDictionary dictionary];
    for (NSString *section in @[@"Battery", @"Storage", @"Apps", @"Notifications", @"ScreenTime", @"Search", @"Everywhere"])
        flags[section] = @([BHRead([@"Hide" stringByAppendingString:section], ([section isEqualToString:@"Battery"] || [section isEqualToString:@"Search"] || [section isEqualToString:@"Everywhere"]) ? @YES : @NO) boolValue]);
    sectionFlags = [flags copy];
    [knownNames addObjectsFromArray:BHNames(@"KnownNames")];
    NSMutableSet<UITableView *> *tables = [NSMutableSet set];
    for (UIView *cell in trackedCells.allObjects) {
        RestoreCell(cell);
        objc_setAssociatedObject(cell, &invalidatedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BOOL hide = ShouldHideRow(cell);
        if (hide) HideRow(cell);
        if ([cell isKindOfClass:UITableViewCell.class]) MarkTableRow((UITableViewCell *)cell, hide);
        [cell setNeedsLayout];
        if ([cell isKindOfClass:UICollectionViewCell.class]) InvalidateCollectionLayout(cell);
        UITableView *table = TableViewFor(cell);
        if (table) [tables addObject:table];
    }
    // Re-ask the delegate for row heights so hidden rows collapse (or come back) without a reload.
    for (UITableView *table in tables) { [table beginUpdates]; [table endUpdates]; }
}

static void Changed(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{ RefreshVisibleRows(); });
}

#pragma mark - Hooks

%hook UIViewController
- (void)viewDidLoad {
    %orig;
    PrepareController(self);
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    PrepareController(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!diagnosticLogging) return;
    NSString *section = SectionForController(self);
    if ([section isEqualToString:@"OwnSettings"]) return;
    NSString *bundle = [NSBundle bundleForClass:self.class].bundlePath.lastPathComponent ?: @"unknown";
    if ([bundle isEqualToString:@"UIKitCore.framework"] || [bundle isEqualToString:@"StickerKit.framework"]) return;
    NSString *line = [NSString stringWithFormat:@"%@ | %@ | %@ | title=%@", NSStringFromClass(self.class), bundle, section ?: @"Unrecognized", TitleForController(self) ?: @"-"];
    NSMutableArray *lines = [BHNames(@"Diagnostics") mutableCopy];
    if (![lines containsObject:line]) {
        [lines addObject:line];
        if (lines.count > 60) [lines removeObjectAtIndex:0];
        CFPreferencesSetAppValue(CFSTR("Diagnostics"), (__bridge CFArrayRef)lines, CFSTR("com.example.batteryhide"));
        CFPreferencesAppSynchronize(CFSTR("com.example.batteryhide"));
    }
}
%end

%hook UITableViewCell
- (void)layoutSubviews {
    RestoreCell(self);
    %orig;
    BOOL own = NO;
    NSString *section = SectionForViewEx(self, &own);
    if (own) return;
    if (diagnosticLogging) LogCell(self, section);
    if (!section) return;
    [trackedCells addObject:self];
    if ([section isEqualToString:@"Battery"]) LearnRow(self);
    if (ShouldHideRow(self)) { HideRow(self); MarkTableRow(self, YES); }
    else MarkTableRow(self, NO);
}
- (void)prepareForReuse {
    RestoreCell(self);
    objc_setAssociatedObject(self, &invalidatedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [trackedCells removeObject:self];
    %orig;
}
%end

%hook UITableView
- (void)reloadData {
    objc_setAssociatedObject(self, &hiddenRowsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
%end

// SwiftUI List rows (iOS 16+) are UICollectionView cells.
%hook UICollectionViewCell
- (void)layoutSubviews {
    RestoreCell(self);
    %orig;
    BOOL own = NO;
    NSString *section = SectionForViewEx(self, &own);
    if (own) return;
    if (diagnosticLogging) LogCell(self, section);
    if (!section) return;
    [trackedCells addObject:self];
    if (ShouldHideRow(self)) HideRow(self);
}
- (void)prepareForReuse {
    RestoreCell(self);
    objc_setAssociatedObject(self, &invalidatedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [trackedCells removeObject:self];
    %orig;
}
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)layoutAttributes {
    UICollectionViewLayoutAttributes *result = %orig;
    CollapseAttributes(self, result);
    return result;
}
- (CGSize)systemLayoutSizeFittingSize:(CGSize)targetSize withHorizontalFittingPriority:(UILayoutPriority)horizontalPriority verticalFittingPriority:(UILayoutPriority)verticalPriority {
    CGSize size = %orig;
    if (RowIsCollapsed(self)) size.height = kCollapsedHeight;
    return size;
}
%end

// SwiftUI's own row class overrides self-sizing, so the base-class hook above can be bypassed.
%group SwiftUIList
%hook BHListCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)layoutAttributes {
    UICollectionViewLayoutAttributes *result = %orig;
    CollapseAttributes(self, result);
    return result;
}
- (CGSize)systemLayoutSizeFittingSize:(CGSize)targetSize withHorizontalFittingPriority:(UILayoutPriority)horizontalPriority verticalFittingPriority:(UILayoutPriority)verticalPriority {
    CGSize size = %orig;
    if (RowIsCollapsed(self)) size.height = kCollapsedHeight;
    return size;
}
%end
%end

%ctor {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Preferences"]) return;
        knownNames = [NSMutableSet setWithArray:BHNames(@"KnownNames")];
        trackedCells = [NSHashTable weakObjectsHashTable];
        cellLogCounts = [NSMutableDictionary dictionary];
        RefreshVisibleRows();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, Changed,
            CFSTR("com.example.batteryhide/changed"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init;
        Class swiftUIRow = NSClassFromString(@"SwiftUI.ListCollectionViewCell") ?: objc_getClass("SwiftUI.ListCollectionViewCell");
        if (swiftUIRow) { %init(SwiftUIList, BHListCell = swiftUIRow); }
    }
}
