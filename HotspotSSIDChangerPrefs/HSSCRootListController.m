#import "HSSCRootListController.h"

#define kHSSCAppID      CFSTR("com.miron302.hotspotssidchanger")
#define kHSSCNotifyName CFSTR("com.miron302.hotspotssidchanger/prefschanged")
#define kHSSCMaxSSIDLen 32

@implementation HSSCRootListController

// Explicit load so this works correctly whether it's reached as a pushed
// sub-page (via the injected Personal Hotspot button) or, if you choose to
// also register it as a standalone bundle later, as a root Settings page.
- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
    }
    return _specifiers;
}

// We override read/write explicitly rather than relying on the framework's
// undocumented default persistence path, so we are certain Settings.app
// writes to exactly the same CFPreferences app ID that Tweak.x reads from.

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    CFPreferencesAppSynchronize(kHSSCAppID);

    if ([key isEqualToString:@"Enabled"]) {
        Boolean valid = false;
        Boolean value = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, kHSSCAppID, &valid);
        return @(valid ? value : NO);
    }

    if ([key isEqualToString:@"CustomSSID"]) {
        CFPropertyListRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)key, kHSSCAppID);
        if (raw && CFGetTypeID(raw) == CFStringGetTypeID()) {
            return (__bridge_transfer NSString *)raw;
        }
        if (raw) CFRelease(raw);
        return @"";
    }

    return [super readPreferenceValue:specifier];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];

    if ([key isEqualToString:@"Enabled"]) {
        BOOL enabled = [value boolValue];
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFBooleanRef)@(enabled), kHSSCAppID);
        CFPreferencesAppSynchronize(kHSSCAppID);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                              kHSSCNotifyName, NULL, NULL, TRUE);
        return;
    }

    if ([key isEqualToString:@"CustomSSID"]) {
        // Gracefully handle invalid/oversized input at save time too, in
        // addition to the tweak's own runtime sanitization.
        NSString *trimmed = [[value description] stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kHSSCMaxSSIDLen) {
            trimmed = [trimmed substringToIndex:MIN(trimmed.length, (NSUInteger)kHSSCMaxSSIDLen)];
        }
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)trimmed, kHSSCAppID);
        CFPreferencesAppSynchronize(kHSSCAppID);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                              kHSSCNotifyName, NULL, NULL, TRUE);
        return;
    }

    [super setPreferenceValue:value specifier:specifier];
}

- (void)restoreDefaultTapped {
    CFPreferencesSetAppValue(CFSTR("Enabled"), (__bridge CFBooleanRef)@NO, kHSSCAppID);
    CFPreferencesSetAppValue(CFSTR("CustomSSID"), CFSTR(""), kHSSCAppID);
    CFPreferencesAppSynchronize(kHSSCAppID);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          kHSSCNotifyName, NULL, NULL, TRUE);

    // Refresh the visible switch/text field to reflect the reset values.
    [self.tableView reloadData];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restored"
                                 message:@"Personal Hotspot will use your device's normal name again."
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
