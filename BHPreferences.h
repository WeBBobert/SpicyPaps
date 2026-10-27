#pragma once
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static inline id BHRead(NSString *key, id fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.example.batteryhide"));
    return value ? CFBridgingRelease(value) : fallback;
}
static inline void BHNotify(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.example.batteryhide/changed"), NULL, NULL, true);
}
static inline void BHWrite(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR("com.example.batteryhide"));
    CFPreferencesAppSynchronize(CFSTR("com.example.batteryhide"));
    BHNotify();
}
static inline NSArray<NSString *> *BHNames(NSString *key) {
    id value = BHRead(key, @[]);
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    NSUInteger limit = ([key isEqualToString:@"Diagnostics"] || [key isEqualToString:@"CellDiagnostics"]) ? 2048 : ([key isEqualToString:@"HiddenBundleIDs"] ? 512 : 150);
    for (id name in value) {
        if (![name isKindOfClass:NSString.class]) continue;
        NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length && trimmed.length <= limit) [names addObject:trimmed];
    }
    return names.array;
}
