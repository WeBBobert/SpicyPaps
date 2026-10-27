#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../BHPreferences.h"
#import "../BHInstalledApps.h"

@interface BHRootController : PSListController
@end
@interface BHAppPickerController : PSListController
@end
@interface BHAppRulesController : PSListController
@end
@interface BHAppRuleController : PSListController
@end

static UIImage *BHIconForIdentifier(NSString *identifier) {
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (!identifier.length || ![UIImage respondsToSelector:selector]) return nil;
    @try { return ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)(UIImage.class, selector, identifier, 0, UIScreen.mainScreen.scale); }
    @catch (NSException *exception) { (void)exception; return nil; }
}

static NSDictionary *BHRules(void) {
    id rules = BHRead(@"AppRules", @{});
    return [rules isKindOfClass:NSDictionary.class] ? rules : @{};
}

// Every selected app (installed apps first by name), as {key, title, id?, installed}.
static NSArray<NSDictionary *> *BHSelectedEntries(void) {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *identifier in BHNames(@"HiddenBundleIDs"))
        [entries addObject:@{@"key": identifier, @"id": identifier, @"title": BHDisplayNameForIdentifier(identifier) ?: identifier, @"installed": @(BHIsInstalled(identifier))}];
    for (NSString *name in BHNames(@"HiddenNames"))
        [entries addObject:@{@"key": [@"name:" stringByAppendingString:name], @"title": name, @"installed": @YES}];
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    return entries;
}

@implementation BHRootController
- (NSArray *)specifiers {
    if (!_specifiers) {
        BOOL pickerAvailable = BHLoadAltList();
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (!pickerAvailable) {
            NSMutableArray *available = [_specifiers mutableCopy];
            for (PSSpecifier *item in [_specifiers copy]) {
                if ([[item propertyForKey:@"key"] isEqualToString:@"HiddenBundleIDs"]) [available removeObject:item];
            }
            _specifiers = available;
        }
    }
    return _specifiers;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return [specifier propertyForKey:@"default"];
    if ([key isEqualToString:@"HiddenBundleIDs"]) return BHNames(key);
    return BHRead(key, [specifier propertyForKey:@"default"]);
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key) BHWrite(key, value);
}
- (void)refreshBatteryHide { BHNotify(); }
// Decoy buttons: they intentionally do nothing.
- (void)showEverything {}
- (void)unhideAllApps {}
- (void)resetHiddenApps {}
- (void)disableHidingForAllApps {}

- (void)removeUninstalledApps {
    NSArray<NSString *> *identifiers = BHNames(@"HiddenBundleIDs");
    NSMutableArray<NSString *> *gone = [NSMutableArray array];
    for (NSString *identifier in identifiers) if (!BHIsInstalled(identifier)) [gone addObject:identifier];
    if (!gone.count) {
        UIAlertController *none = [UIAlertController alertControllerWithTitle:@"Nothing to remove" message:@"Every selected app is still installed." preferredStyle:UIAlertControllerStyleAlert];
        [none addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:none animated:YES completion:nil];
        return;
    }
    NSString *message = [NSString stringWithFormat:@"%lu selected app%@ no longer installed:\n%@", (unsigned long)gone.count, gone.count == 1 ? @" is" : @"s are", [gone componentsJoinedByString:@"\n"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Remove uninstalled apps?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        NSMutableArray *kept = [identifiers mutableCopy];
        [kept removeObjectsInArray:gone];
        NSMutableDictionary *rules = [BHRules() mutableCopy];
        [rules removeObjectsForKeys:gone];
        BHWrite(@"AppRules", rules);
        BHWrite(@"HiddenBundleIDs", kept);
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showDiagnostics {
    NSArray *pages = BHNames(@"Diagnostics");
    NSArray *rows = BHNames(@"CellDiagnostics");
    NSMutableString *text = [NSMutableString string];
    if (pages.count) [text appendFormat:@"PAGES\n%@", [pages componentsJoinedByString:@"\n"]];
    if (rows.count) [text appendFormat:@"%@ROWS\n%@", text.length ? @"\n\n" : @"", [rows componentsJoinedByString:@"\n"]];
    BOOL hasLog = text.length > 0;
    NSString *message = hasLog ? [text copy] : @"Enable Diagnostic logging, visit a page where hiding does not work (Apps, iPhone Storage), then return here.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Settings diagnostics" message:message preferredStyle:UIAlertControllerStyleAlert];
    if (hasLog) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            UIPasteboard.generalPasteboard.string = message;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Clear log" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action;
            BHWrite(@"Diagnostics", @[]);
            BHWrite(@"CellDiagnostics", @[]);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

@implementation BHAppPickerController
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [[self loadSpecifiersFromPlistName:@"Apps" target:self] mutableCopy];
        if (!items) items = [NSMutableArray array];
        NSMutableSet *names = [NSMutableSet setWithArray:BHNames(@"KnownNames")];
        [names addObjectsFromArray:BHNames(@"HiddenNames")];
        NSArray *sorted = [[names allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSString *name in sorted) {
            PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:name target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
            [item setProperty:name forKey:@"appName"];
            [items addObject:item];
        }
        _specifiers = items;
    }
    return _specifiers;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *name = [specifier propertyForKey:@"appName"];
    return @([BHNames(@"HiddenNames") containsObject:name]);
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *name = [specifier propertyForKey:@"appName"];
    if (!name) return;
    NSMutableArray *selected = [BHNames(@"HiddenNames") mutableCopy];
    if ([value boolValue]) { if (![selected containsObject:name]) [selected addObject:name]; }
    else [selected removeObject:name];
    BHWrite(@"HiddenNames", selected);
}
- (void)addAppName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add app name" message:@"Enter the name exactly as it appears in Settings → Battery. The app will be selected for hiding." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"For example: Photos";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length || name.length > 150) return;
        NSMutableArray *known = [BHNames(@"KnownNames") mutableCopy];
        if (![known containsObject:name]) [known addObject:name];
        BHWrite(@"KnownNames", known);
        NSMutableArray *selected = [BHNames(@"HiddenNames") mutableCopy];
        if (![selected containsObject:name]) [selected addObject:name];
        BHWrite(@"HiddenNames", selected);
        BHAppPickerController *controller = weakSelf;
        if (!controller) return;
        controller->_specifiers = nil;
        [controller reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
// Decoy button: intentionally does nothing.
- (void)showAllApps {}
@end

@implementation BHAppRulesController
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];
        NSArray<NSDictionary *> *entries = BHSelectedEntries();
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Hidden apps"];
        [group setProperty:(entries.count ? @"Choose an app to control where it is hidden." : @"No apps are selected yet. Choose installed apps on the main page first.") forKey:@"footerText"];
        [items addObject:group];
        for (NSDictionary *entry in entries) {
            PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:entry[@"title"] target:self set:NULL get:@selector(summaryForSpecifier:) detail:BHAppRuleController.class cell:PSLinkCell edit:nil];
            [item setProperty:entry[@"key"] forKey:@"ruleKey"];
            [item setProperty:entry[@"title"] forKey:@"ruleTitle"];
            [item setProperty:entry[@"installed"] forKey:@"ruleInstalled"];
            UIImage *icon = BHIconForIdentifier(entry[@"id"]);
            if (icon) [item setProperty:icon forKey:@"iconImage"];
            [items addObject:item];
        }
        _specifiers = items;
    }
    return _specifiers;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
}
- (id)summaryForSpecifier:(PSSpecifier *)specifier {
    if (![[specifier propertyForKey:@"ruleInstalled"] boolValue]) return @"Not installed";
    NSDictionary *rule = BHRules()[[specifier propertyForKey:@"ruleKey"]];
    if (![rule isKindOfClass:NSDictionary.class]) return @"Default";
    if (rule[@"Enabled"] && ![rule[@"Enabled"] boolValue]) return @"Not hidden";
    return [rule[@"Custom"] boolValue] ? @"Custom" : @"Default";
}
@end

@implementation BHAppRuleController
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSString *key = [self.specifier propertyForKey:@"ruleKey"];
        NSDictionary *rule = BHRules()[key];
        BOOL custom = [rule isKindOfClass:NSDictionary.class] && [rule[@"Custom"] boolValue];
        NSMutableArray *items = [NSMutableArray array];

        PSSpecifier *appGroup = [PSSpecifier groupSpecifierWithName:[self.specifier propertyForKey:@"ruleTitle"]];
        [appGroup setProperty:@"Turn this off to stop hiding just this app without deselecting it." forKey:@"footerText"];
        [items addObject:appGroup];
        [items addObject:[self switchNamed:@"Hide this app" field:@"Enabled" enabled:YES]];

        PSSpecifier *placeGroup = [PSSpecifier groupSpecifierWithName:@"Where it is hidden"];
        [placeGroup setProperty:@"Off: this app follows the section switches on the main page. On: only the places chosen below are used." forKey:@"footerText"];
        [items addObject:placeGroup];
        [items addObject:[self switchNamed:@"Customize places" field:@"Custom" enabled:YES]];

        NSArray<NSArray<NSString *> *> *places = @[
            @[@"Everywhere", @"All other pages"], @[@"Battery", @"Battery"], @[@"Storage", @"iPhone Storage"], @[@"Apps", @"Apps"],
            @[@"Notifications", @"Notifications"], @[@"ScreenTime", @"Screen Time"], @[@"Search", @"Settings search"]];
        PSSpecifier *listGroup = [PSSpecifier groupSpecifierWithName:@"Hide this app in"];
        [items addObject:listGroup];
        for (NSArray<NSString *> *place in places)
            [items addObject:[self switchNamed:place[1] field:[@"Place:" stringByAppendingString:place[0]] enabled:custom]];
        _specifiers = items;
    }
    return _specifiers;
}
- (PSSpecifier *)switchNamed:(NSString *)name field:(NSString *)field enabled:(BOOL)enabled {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:name target:self set:@selector(writeRuleValue:specifier:) get:@selector(readRuleValue:) detail:nil cell:PSSwitchCell edit:nil];
    [item setProperty:field forKey:@"ruleField"];
    [item setProperty:@(enabled) forKey:@"enabled"];
    return item;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = [self.specifier propertyForKey:@"ruleTitle"];
}
- (id)readRuleValue:(PSSpecifier *)specifier {
    NSDictionary *rule = BHRules()[[self.specifier propertyForKey:@"ruleKey"]];
    NSString *field = [specifier propertyForKey:@"ruleField"];
    BOOL isRule = [rule isKindOfClass:NSDictionary.class];
    if ([field hasPrefix:@"Place:"]) {
        NSDictionary *places = isRule ? rule[@"Places"] : nil;
        id value = [places isKindOfClass:NSDictionary.class] ? places[[field substringFromIndex:6]] : nil;
        return value ?: @YES;
    }
    id value = isRule ? rule[field] : nil;
    if (value) return value;
    return [field isEqualToString:@"Enabled"] ? @YES : @NO;
}
- (void)writeRuleValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [self.specifier propertyForKey:@"ruleKey"];
    NSString *field = [specifier propertyForKey:@"ruleField"];
    if (!key || !field) return;
    NSMutableDictionary *rules = [BHRules() mutableCopy];
    NSMutableDictionary *rule = [rules[key] isKindOfClass:NSDictionary.class] ? [rules[key] mutableCopy] : [NSMutableDictionary dictionary];
    if ([field hasPrefix:@"Place:"]) {
        NSMutableDictionary *places = [rule[@"Places"] isKindOfClass:NSDictionary.class] ? [rule[@"Places"] mutableCopy] : [NSMutableDictionary dictionary];
        places[[field substringFromIndex:6]] = @([value boolValue]);
        rule[@"Places"] = places;
    } else {
        rule[field] = @([value boolValue]);
    }
    rules[key] = rule;
    BHWrite(@"AppRules", rules);
    if ([field isEqualToString:@"Custom"]) {
        _specifiers = nil;
        [self reloadSpecifiers];
    }
}
@end
