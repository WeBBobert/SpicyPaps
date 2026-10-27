#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "BHPreferences.h"

// AltList supplies the application picker and compatibility categories. Load it
// from its installed framework rather than requiring its link stub on the CI SDK.
static inline BOOL BHLoadAltList(void) {
    if (NSClassFromString(@"ATLApplicationListMultiSelectionController")) return YES;
    for (NSString *path in @[@"/var/jb/Library/Frameworks/AltList.framework/AltList", @"/Library/Frameworks/AltList.framework/AltList"])
        if (dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) return YES;
    return NO;
}

static inline id BHObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || (signature.methodReturnType[0] != '@' && signature.methodReturnType[0] != '#')) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (NSException *exception) { (void)exception; return nil; }
}

static inline id BHObjectWithArgument(id object, NSString *name, id argument) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 3 || signature.methodReturnType[0] != '@') return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(object, selector, argument); }
    @catch (NSException *exception) { (void)exception; return nil; }
}

static inline NSSet<NSString *> *BHSelectedDisplayNames(void) {
    NSMutableSet *names = [NSMutableSet setWithArray:BHNames(@"HiddenNames")];
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    for (NSString *identifier in BHNames(@"HiddenBundleIDs")) {
        id proxy = BHObjectWithArgument(proxyClass, @"applicationProxyForIdentifier:", identifier);
        for (NSString *selector in @[@"localizedName", @"atl_nameToDisplay", @"localizedShortName"]) {
            id name = BHObject(proxy, selector);
            if ([name isKindOfClass:NSString.class] && [name length]) [names addObject:name];
        }

    }
    return names;
}

// Rule keys identify an app in per-app settings: its bundle ID, or "name:<Name>" for legacy name selections.
static inline NSString *BHDisplayNameForIdentifier(NSString *identifier) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    id proxy = BHObjectWithArgument(proxyClass, @"applicationProxyForIdentifier:", identifier);
    for (NSString *selector in @[@"localizedName", @"atl_nameToDisplay", @"localizedShortName"]) {
        id name = BHObject(proxy, selector);
        if ([name isKindOfClass:NSString.class] && [name length]) return name;
    }
    return nil;
}

// Conservative: anything we cannot positively identify as uninstalled counts as installed.
static inline BOOL BHIsInstalled(NSString *identifier) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass) return YES;
    id proxy = BHObjectWithArgument(proxyClass, @"applicationProxyForIdentifier:", identifier);
    if (!proxy) return NO;
    SEL installed = NSSelectorFromString(@"isInstalled");
    if (![proxy respondsToSelector:installed]) return YES;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(proxy, installed); }
    @catch (NSException *exception) { (void)exception; return YES; }
}

// Maps every name an app can appear under in Settings to its rule key. Bundle IDs win over legacy names.
static inline NSDictionary<NSString *, NSString *> *BHNameToRuleKey(void) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    for (NSString *name in BHNames(@"HiddenNames")) map[name] = [@"name:" stringByAppendingString:name];
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    for (NSString *identifier in BHNames(@"HiddenBundleIDs")) {
        id proxy = BHObjectWithArgument(proxyClass, @"applicationProxyForIdentifier:", identifier);
        for (NSString *selector in @[@"localizedName", @"atl_nameToDisplay", @"localizedShortName"]) {
            id name = BHObject(proxy, selector);
            if ([name isKindOfClass:NSString.class] && [name length]) map[name] = identifier;
        }
    }
    return map;
}
