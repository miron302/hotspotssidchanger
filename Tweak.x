// HotspotSSIDChanger — Tweak.x
//
// This file does two independent things, gated by which process it's loaded
// into (see HotspotSSIDChanger.plist's Filter):
//
//   1. Inside `wifid` / `sharingd`: hooks SCDynamicStoreCopyComputerName so
//      Personal Hotspot broadcasts a custom SSID instead of the device name.
//      See the long comment further down for why this specific function.
//
//   2. Inside `Preferences` (Settings.app): injects a "Change SSID" button
//      directly into the real Settings > Personal Hotspot page, plus a
//      warning about the AirDrop side effect, and pushes our settings UI
//      when tapped. No standalone root-level Settings tab is created or
//      needed.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <Preferences/Preferences.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>

#pragma mark - Part 1: Personal Hotspot SSID hook (wifid / sharingd)
//
// iOS does not have a dedicated "Personal Hotspot SSID" setting distinct from
// the device name — Apple's own documentation confirms the hotspot's Wi-Fi
// network name IS the device name. Every subsystem that needs "the name"
// (Settings > General > About, Bluetooth, AirDrop, and Personal Hotspot) reads
// it through the same public SystemConfiguration API:
//
//     CFStringRef SCDynamicStoreCopyComputerName(SCDynamicStoreRef store,
//                                                 CFStringEncoding *nameEncoding);
//
// Rather than touching the underlying "ComputerName" preference (which WOULD
// change Settings > General > About, Bluetooth name, etc.), this hooks that
// single function call, but ONLY inside the process(es) named in
// HotspotSSIDChanger.plist's MobileSubstrate Filter.

// NOTE ON THE "unavailable: not available on iOS" BUILD ERROR:
// The iOS SDK header declares SCDynamicStoreCopyComputerName with
// API_UNAVAILABLE(ios). The symbol genuinely exists and is used internally
// by system daemons on-device, but referencing it by name at compile time
// (which Logos's %hookf does) makes clang enforce that annotation and fail.
// Workaround: resolve the symbol at runtime via dlopen/dlsym instead of
// naming it directly, then hook the resulting pointer with MSHookFunction.

typedef CFStringRef (*SCDynamicStoreCopyComputerName_t)(SCDynamicStoreRef store,
                                                         CFStringEncoding *nameEncoding);
static SCDynamicStoreCopyComputerName_t orig_SCDynamicStoreCopyComputerName;

#define kHSSCAppID       CFSTR("com.miron302.hotspotssidchanger")
#define kHSSCEnabledKey  CFSTR("Enabled")
#define kHSSCSSIDKey     CFSTR("CustomSSID")
#define kHSSCMaxSSIDLen  32 // 802.11 SSID hard limit is 32 bytes (UTF-8)

// Returns the sanitized custom SSID to use, or nil if the tweak should
// stay out of the way and let Apple's normal behavior apply.
static NSString * _Nullable HSSCResolveCustomSSID(void) {
    CFPreferencesAppSynchronize(kHSSCAppID);

    Boolean hasValidValue = false;
    Boolean enabled = CFPreferencesGetAppBooleanValue(kHSSCEnabledKey, kHSSCAppID, &hasValidValue);
    if (!hasValidValue || !enabled) {
        return nil; // Disabled or never configured -> fall back to stock behavior.
    }

    CFPropertyListRef rawValue = CFPreferencesCopyAppValue(kHSSCSSIDKey, kHSSCAppID);
    if (!rawValue) {
        return nil;
    }

    NSString *ssid = nil;
    if (CFGetTypeID(rawValue) == CFStringGetTypeID()) {
        ssid = (__bridge_transfer NSString *)rawValue;
    } else {
        CFRelease(rawValue);
        return nil; // Malformed pref value - don't risk applying garbage.
    }

    NSString *trimmed = [ssid stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (trimmed.length == 0) {
        return nil;
    }
    if ([trimmed lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kHSSCMaxSSIDLen) {
        trimmed = [trimmed substringToIndex:MIN(trimmed.length, kHSSCMaxSSIDLen)];
        if (trimmed.length == 0) return nil;
    }

    return trimmed;
}

static CFStringRef replaced_SCDynamicStoreCopyComputerName(SCDynamicStoreRef store,
                                                             CFStringEncoding *nameEncoding) {
    NSString *customSSID = HSSCResolveCustomSSID();
    if (customSSID != nil) {
        if (nameEncoding != NULL) {
            *nameEncoding = kCFStringEncodingUTF8;
        }
        return (__bridge_retained CFStringRef)[customSSID copy];
    }
    return orig_SCDynamicStoreCopyComputerName(store, nameEncoding);
}

static void HSSCInstallSSIDHook(void) {
    void *handle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",
                           RTLD_LAZY | RTLD_NOLOAD);
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",
                         RTLD_LAZY);
    }
    if (!handle) return;

    void *sym = dlsym(handle, "SCDynamicStoreCopyComputerName");
    if (!sym) return;

    MSHookFunction(sym,
                    (void *)replaced_SCDynamicStoreCopyComputerName,
                    (void **)&orig_SCDynamicStoreCopyComputerName);
}

#pragma mark - Part 2: Inject "Change SSID" into Settings > Personal Hotspot
//
// Apple's own documented Settings URL scheme confirms the Personal Hotspot
// page's specifier identifier is the string "INTERNET_TETHERING"
// (prefs:root=MOBILE_DATA_SETTINGS_ID&path=INTERNET_TETHERING). Every
// PSListController keeps a reference to the specifier that pushed it
// (`self.specifier`), so checking that identifier reliably detects "we are
// on the real Personal Hotspot page" without needing to know Apple's
// (private, version-dependent) controller class name in advance.

#define kHSSCInjectedMarkerKey @"HSSCInjected"
#define kHSSCPrefsBundlePath   @"/Library/PreferenceBundles/HotspotSSIDChangerPrefs.bundle"
#define kHSSCPrefsClassName    @"HSSCRootListController"

// Dynamically-added button action, installed via class_addMethod onto
// whatever the real Personal Hotspot controller's class turns out to be at
// runtime - we never have to hardcode or guess that class's name.
static void HSSCChangeSSIDTapped(id self, SEL _cmd) {
    Class prefsClass = NSClassFromString(kHSSCPrefsClassName);
    if (!prefsClass) {
        // On rootless jailbreaks, plain "/Library/..." paths are
        // transparently redirected to /var/jb/Library by the jailbreak's
        // filesystem shims, so no /var/jb prefix is needed here.
        NSBundle *bundle = [NSBundle bundleWithPath:kHSSCPrefsBundlePath];
        if (![bundle load]) {
            return;
        }
        prefsClass = bundle.principalClass;
    }
    if (!prefsClass) return;

    UIViewController *pushed = [[prefsClass alloc] init];
    UIViewController *host = (UIViewController *)self;
    if (host.navigationController && pushed) {
        [host.navigationController pushViewController:pushed animated:YES];
    }
}

static void HSSCInjectChangeSSIDButton(NSMutableArray *specifiers, PSListController *host) {
    for (PSSpecifier *existing in specifiers) {
        if ([[existing propertyForKey:kHSSCInjectedMarkerKey] boolValue]) {
            return; // Already inserted (specifiers can be rebuilt repeatedly).
        }
    }

    Class hostClass = [host class];
    SEL actionSel = @selector(hssc_changeSSIDTapped);
    if (![hostClass instancesRespondToSelector:actionSel]) {
        class_addMethod(hostClass, actionSel, (IMP)HSSCChangeSSIDTapped, "v@:");
    }

    PSSpecifier *warning = [PSSpecifier preferenceSpecifierNamed:@""
                                                           target:host
                                                              set:NULL
                                                              get:NULL
                                                           detail:Nil
                                                             cell:PSGroupCell
                                                             edit:Nil];
    [warning setProperty:@"Changing the hotspot SSID also changes your AirDrop "
                          @"name. iOS shares the same underlying system process "
                          @"(sharingd) for both Personal Hotspot and AirDrop "
                          @"naming, so they can't be changed independently."
                  forKey:@"footerText"];
    [warning setProperty:@YES forKey:kHSSCInjectedMarkerKey];

    PSSpecifier *button = [PSSpecifier preferenceSpecifierNamed:@"Change SSID"
                                                          target:host
                                                             set:NULL
                                                             get:NULL
                                                          detail:Nil
                                                            cell:PSButtonCell
                                                            edit:Nil];
    [button setProperty:NSStringFromSelector(actionSel) forKey:@"action"];
    [button setProperty:@YES forKey:kHSSCInjectedMarkerKey];

    [specifiers addObject:button];
    [specifiers addObject:warning];
}

%hook PSListController

- (NSMutableArray *)specifiers {
    NSMutableArray *specifiers = %orig;
    @try {
        PSSpecifier *hostSpecifier = [self specifier];
        NSString *identifier = [hostSpecifier propertyForKey:@"id"];
        if ([identifier isEqualToString:@"INTERNET_TETHERING"] && specifiers) {
            HSSCInjectChangeSSIDButton(specifiers, self);
        }
    } @catch (NSException *exception) {
        // Never let a UI-injection hiccup take down Settings.app.
    }
    return specifiers;
}

%end

#pragma mark - Entry point

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];

        if ([proc isEqualToString:@"wifid"] || [proc isEqualToString:@"sharingd"]) {
            HSSCInstallSSIDHook();
            return;
        }

        if ([proc isEqualToString:@"Preferences"]) {
            %init;
            return;
        }
    }
}
