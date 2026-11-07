// Signing on the device (spsign.h). research/dlopentest's sign experiment is where this was worked out: on
// iOS 27 and visionOS 27 an image signed this way with a team certificate that an installed profile lists
// loads from Library/, with library validation passing, and the prepare treats it like the bundle's own.
#import "spsign.h"
#import <Security/Security.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/stat.h>
#include <unistd.h>

// spzsign.cpp. 0 on success; zsign's own messages (what failed, never a value) go to `logfd`.
int sp_zsign(const char *path, const char *identifier, const void *p12, size_t p12_len, const char *password,
             const void *profile, size_t profile_len, int logfd);

// The keychain items: the .p12 and its password, under one service (splogin.m's sign-in has its own).
static NSString *const service = @"Slashplayed signing identity";
static NSString *const pushedP12 = @"Library/spidentity.p12", *const pushedPassword = @"Library/spidentity.pass";
// The companion's request to forget (it turned Update Games on This Device off), and the line for it to read.
static NSString *const pushedForget = @"Library/spidentity.forget", *const statusFile = @"Library/spidentity.txt";
// Set when the Settings sheet forgot the identity, cleared by the next import: the status says "forgotten"
// meanwhile, so the companion turns its setting off rather than push the identity straight back.
static NSString *const forgottenKey = @"sp_identity_forgotten";

// The whole file through write(), created 0600, never through a mapping. NO (and the file gone) on a short write.
static BOOL write_file(NSString *path, NSData *data) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return NO;
    const uint8_t *p = data.bytes;
    size_t left = data.length;
    while (left) {
        ssize_t n = write(fd, p, left);
        if (n <= 0) break;
        p += n;
        left -= (size_t)n;
    }
    BOOL ok = !left && !fsync(fd);
    ok = !close(fd) && ok;
    if (!ok) {
        int e = errno;
        unlink(path.fileSystemRepresentation);
        errno = e;
    }
    return ok;
}

BOOL sp_sign(NSString *source, NSString *dest, NSString *identifier, NSData *p12, NSString *password, NSData *profile,
             NSString **problem) {
    NSString *why = nil;
    // Both beside `dest`, so the rename stays on one volume.
    NSString *work = [dest stringByAppendingString:@".signing"], *out = [dest stringByAppendingString:@".signed"];
    NSData *orig = [NSData dataWithContentsOfFile:source];
    NSMutableData *pw = [[password dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [pw appendBytes:"" length:1];  // zsign takes it as a C string
    if (!orig) why = [@"there's nothing to sign at " stringByAppendingString:source.lastPathComponent];
    else if (!write_file(work, orig)) why = [@"couldn't copy it to sign: " stringByAppendingString:@(strerror(errno))];
    else if (sp_zsign(work.fileSystemRepresentation, identifier.UTF8String, p12.bytes, p12.length, pw.bytes, profile.bytes,
                      profile.length, STDERR_FILENO))
        why = @"zsign couldn't sign it (its message is above)";
    memset(pw.mutableBytes, 0, pw.length);
    // The signed bytes, read back with read() (dataWithContentsOfFile: doesn't map without being asked to),
    // into a file no mapping has touched.
    NSData *signedBytes = why ? nil : [NSData dataWithContentsOfFile:work];
    unlink(work.fileSystemRepresentation);
    if (!why && !signedBytes) why = @"couldn't read the signed copy back";
    if (!why && !write_file(out, signedBytes)) why = [@"couldn't write the signed image: " stringByAppendingString:@(strerror(errno))];
    if (!why && rename(out.fileSystemRepresentation, dest.fileSystemRepresentation))
        why = [@"couldn't move the signed image into place: " stringByAppendingString:@(strerror(errno))];
    if (why) {
        unlink(out.fileSystemRepresentation);
        if (problem) *problem = why;
        return NO;
    }
    return YES;
}

static NSData *keychain_get(NSString *account) {
    CFTypeRef out = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account, (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    }, &out);
    return st == errSecSuccess ? (__bridge_transfer NSData *)out : nil;
}

static OSStatus keychain_put(NSString *account, NSData *value) {
    SecItemDelete((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                (__bridge id)kSecAttrService: service, (__bridge id)kSecAttrAccount: account});
    return SecItemAdd((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account, (__bridge id)kSecValueData: value,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        (__bridge id)kSecAttrSynchronizable: @NO,
    }, NULL);
}

static OSStatus keychain_forget(void) {
    return SecItemDelete((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                       (__bridge id)kSecAttrService: service});
}

// The password as a string, without a trailing line ending (a .pass file written with echo has one).
static NSString *password_string(NSData *data) {
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

// SecPKCS12Import's identities in `p12`: how many, and the first one's certificate's end of validity and,
// when asked, its DER.
static OSStatus open_p12(NSData *p12, NSString *password, NSUInteger *count, NSDate **notAfter, NSData **der) {
    CFArrayRef items = NULL;
    OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12,
                                  (__bridge CFDictionaryRef) @{(__bridge id)kSecImportExportPassphrase: password ?: @""}, &items);
    NSArray *list = (__bridge_transfer NSArray *)items;
    *count = 0;
    for (NSDictionary *item in list) {
        SecIdentityRef identity = (__bridge SecIdentityRef)item[(__bridge id)kSecImportItemIdentity];
        if (!identity) continue;
        if (!*count && notAfter) {
            SecCertificateRef cert = NULL;
            if (SecIdentityCopyCertificate(identity, &cert) == errSecSuccess) {
                *notAfter = (__bridge_transfer NSDate *)SecCertificateCopyNotValidAfterDate(cert);
                if (der) *der = (__bridge_transfer NSData *)SecCertificateCopyData(cert);
                CFRelease(cert);
            }
        }
        (*count)++;
    }
    return st;
}

static NSString *day(NSDate *date) {
    if (!date) return @"an unknown date";
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:date];
}

// Zeros, then unlink: the file's blocks don't keep the credential. YES if there was a file.
static BOOL wipe(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY);
    if (fd < 0) return NO;
    struct stat st;
    if (!fstat(fd, &st)) {
        static const char zero[4096];
        for (off_t o = 0; o < st.st_size; o += sizeof zero) pwrite(fd, zero, sizeof zero, o);
        fsync(fd);
    }
    close(fd);
    unlink(path.fileSystemRepresentation);
    return YES;
}

static NSString *home(NSString *relative) { return [NSHomeDirectory() stringByAppendingPathComponent:relative]; }
static NSString *app_dir(void);

NSString *sp_identity_import(void) {
    NSData *p12 = [NSData dataWithContentsOfFile:home(pushedP12)];
    NSMutableData *pass = [[NSData dataWithContentsOfFile:home(pushedPassword)] mutableCopy];
    BOOL any = wipe(home(pushedP12));
    any = wipe(home(pushedPassword)) || any;
    if (!any) return nil;
    NSString *line;
    if (!p12.length || !pass.length) {
        line = @"identity: only part of a pushed identity was there; deleted, nothing imported";
    } else {
        NSUInteger count = 0;
        NSDate *notAfter = nil;
        double t = CFAbsoluteTimeGetCurrent();
        OSStatus st = open_p12(p12, password_string(pass), &count, &notAfter, NULL);
        double seconds = CFAbsoluteTimeGetCurrent() - t;
        if (st != errSecSuccess || count != 1) {
            line = [NSString stringWithFormat:@"identity: the pushed one wasn't imported (SecPKCS12Import %d, %lu identities); "
                                              @"the pushed files are deleted", (int)st, (unsigned long)count];
        } else {
            OSStatus a = keychain_put(@"p12", p12), b = keychain_put(@"password", pass);
            if (a != errSecSuccess || b != errSecSuccess) keychain_forget();
            else [NSUserDefaults.standardUserDefaults removeObjectForKey:forgottenKey];
            line = a == errSecSuccess && b == errSecSuccess
                       ? [NSString stringWithFormat:@"identity: imported into the keychain (this device only), certificate valid until %@, "
                                                    @"checked in %.3f s; the pushed files are deleted", day(notAfter), seconds]
                       : [NSString stringWithFormat:@"identity: the keychain refused it (%d, %d); the pushed files are deleted", (int)a, (int)b];
        }
    }
    if (pass.length) memset(pass.mutableBytes, 0, pass.length);
    return line;
}

// Imports the selected P12 without writing it or its password to disk. A signing
// identity only works when a currently installed profile lists its certificate.
BOOL sp_identity_import_selected(NSData *p12, NSString *password, NSString **problem) {
    if (!p12.length || p12.length > 1024 * 1024 || !password.length) {
        if (problem) *problem = @"Select a P12 (under 1 MB) and enter its password.";
        return NO;
    }
    NSUInteger count = 0;
    NSDate *until = nil;
    NSData *der = nil;
    OSStatus st = open_p12(p12, password, &count, &until, &der);
    if (st != errSecSuccess || count != 1 || !der) {
        if (problem) *problem = @"The P12 password is incorrect or the file does not contain exactly one signing identity.";
        return NO;
    }
    if (!until || until.timeIntervalSinceNow <= 0) {
        if (problem) *problem = @"The certificate is expired.";
        return NO;
    }
    if (!sp_certificates_listed(@[der], sp_listed_certificates())) {
        if (problem) *problem = @"This certificate is not listed by an unexpired installed provisioning profile. Re-sign the IPA and helper with a profile containing this certificate.";
        return NO;
    }
    NSData *oldP12 = keychain_get(@"p12"), *oldPass = keychain_get(@"password");
    OSStatus a = keychain_put(@"p12", p12);
    OSStatus b = a == errSecSuccess ? keychain_put(@"password", [password dataUsingEncoding:NSUTF8StringEncoding]) : a;
    if (a != errSecSuccess || b != errSecSuccess) {
        keychain_forget();
        if (oldP12 && oldPass) {
            keychain_put(@"p12", oldP12);
            keychain_put(@"password", oldPass);
        }
        if (problem) *problem = @"The device Keychain rejected the identity.";
        return NO;
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:forgottenKey];
    sp_identity_describe();
    return YES;
}

// The keychain's identity and anything pushed and not yet imported, gone: a line for the log, after `who`.
static NSString *forget_identity(NSString *who) {
    OSStatus st = keychain_forget();
    BOOL pushed = wipe(home(pushedP12));
    pushed = wipe(home(pushedPassword)) || pushed;
    NSString *what = st == errSecSuccess ? [NSString stringWithFormat:@"forgot the signing identity (%@)", who]
                   : st == errSecItemNotFound ? [NSString stringWithFormat:@"no signing identity to forget (%@)", who]
                                              : [NSString stringWithFormat:@"couldn't forget the signing identity: keychain %d", (int)st];
    return [NSString stringWithFormat:@"identity: %@%@", what, pushed ? @"; a pushed one not yet imported is deleted too" : @""];
}

NSString *sp_identity_forget_if_asked(void) {
    // devicectl can't delete, so the companion's marker is deleted here; any content means forget.
    return wipe(home(pushedForget)) ? forget_identity(@"the companion") : nil;
}

NSString *sp_identity_forget(void) {
    NSString *line = forget_identity(@"Settings");
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:forgottenKey];
    // At once, not at the next start: the companion may read it before the app starts again.
    sp_identity_describe();
    return line;
}

@implementation SPIdentityReading
- (instancetype)initWithState:(SPIdentityState)state notAfter:(NSDate *)notAfter listed:(BOOL)listed line:(NSString *)line {
    if ((self = [super init])) {
        _state = state;
        _notAfter = notAfter;
        _listed = listed;
        _line = line;
    }
    return self;
}

- (NSString *)status {
    switch (self.state) {
    case SPIdentityStateNone: return @"none";
    case SPIdentityStateForgotten: return @"forgotten";
    case SPIdentityStatePresent: return [@"present " stringByAppendingString:day(self.notAfter)];
    case SPIdentityStateExpired: return [@"expired " stringByAppendingString:day(self.notAfter)];
    case SPIdentityStateUnreadable: return @"unreadable";
    }
}
@end

SPIdentityReading *sp_identity_read(NSData *p12, NSData *pass, BOOL forgotten, NSArray<NSData *> *listed, NSDate *now) {
    if (!p12 || !pass)
        return [[SPIdentityReading alloc] initWithState:forgotten ? SPIdentityStateForgotten : SPIdentityStateNone notAfter:nil listed:NO
                                                   line:forgotten ? @"identity: none (forgotten in Settings)" : @"identity: none"];
    NSUInteger count = 0;
    NSDate *notAfter = nil;
    NSData *der = nil;
    OSStatus st = open_p12(p12, password_string(pass), &count, &notAfter, &der);
    if (st != errSecSuccess || count != 1 || !notAfter)
        return [[SPIdentityReading alloc] initWithState:SPIdentityStateUnreadable notAfter:nil listed:NO
            line:[NSString stringWithFormat:@"identity: in the keychain but unreadable (%d, %lu identities)", (int)st, (unsigned long)count]];
    BOOL expired = [notAfter compare:now] != NSOrderedDescending;
    // Whether a profile lists it decides whether what it signs loads (sp_identity_usable).
    BOOL isListed = der && sp_certificates_listed(@[der], listed);
    NSString *line = [NSString stringWithFormat:@"identity: present, certificate valid until %@%@, %@", day(notAfter), expired ? @" (expired)" : @"",
                                                isListed ? @"listed in the app's profiles" : @"not listed in any profile the app can see"];
    return [[SPIdentityReading alloc] initWithState:expired ? SPIdentityStateExpired : SPIdentityStatePresent notAfter:notAfter
                                             listed:isListed line:line];
}

SPIdentityReading *sp_identity_reading(void) {
    return sp_identity_read(keychain_get(@"p12"), keychain_get(@"password"), [NSUserDefaults.standardUserDefaults boolForKey:forgottenKey],
                            sp_listed_certificates(), [NSDate date]);
}

NSString *sp_identity_describe(void) {
    SPIdentityReading *r = sp_identity_reading();
    // Library/spidentity.txt, for the companion's choice whether to push one (DeviceIdentity.Status): one
    // word, and the certificate's last valid day (UTC), which is how it tells its own identity from another.
    [[r.status stringByAppendingString:@"\n"] writeToFile:home(statusFile) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return r.line;
}

// The keychain identity: its certificate's DER and end of validity. NO without one that opens.
static BOOL identity_certificate(NSData **der, NSDate **notAfter) {
    NSData *p12 = keychain_get(@"p12"), *pass = keychain_get(@"password");
    if (!p12 || !pass) return NO;
    NSUInteger count = 0;
    return open_p12(p12, password_string(pass), &count, notAfter, der) == errSecSuccess && count == 1 && *der;
}

NSData *sp_identity_certificate(void) {
    NSData *der = nil;
    NSDate *notAfter = nil;
    return identity_certificate(&der, &notAfter) ? der : nil;
}

BOOL sp_identity_usable(void) {
    NSData *der = nil;
    NSDate *notAfter = nil;
    return identity_certificate(&der, &notAfter) && notAfter.timeIntervalSinceNow > 0 && sp_certificates_listed(@[der], sp_listed_certificates());
}

BOOL sp_sign_with_identity(NSString *source, NSString *dest, NSString **problem) {
    NSData *p12 = keychain_get(@"p12"), *pass = keychain_get(@"password");
    // The app's own bundle ID, never the image's name: a free team's local profile matches an image from
    // outside the bundle by identifier (spsign.h). Still no entitlements: the identifier alone matches it.
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    // The profile zsign takes the team from: the one this app was installed with.
    NSString *app = app_dir();
    NSData *profile = app ? [NSData dataWithContentsOfFile:[app stringByAppendingPathComponent:@"embedded.mobileprovision"]] : nil;
    if (!p12 || !pass) {
        if (problem) *problem = @"there's no signing identity on this device";
        return NO;
    }
    if (!profile) {
        if (problem) *problem = @"the app has no embedded.mobileprovision";
        return NO;
    }
    if (!identifier.length) {
        if (problem) *problem = @"the app has no bundle identifier";
        return NO;
    }
    return sp_sign(source, dest, identifier, p12, password_string(pass), profile, problem);
}

// ---- Which certificate an image is signed with, and which ones the profiles list

// The app's bundle, from the executable's path (NSBundle would do on the device; the Mac's tests have none).
static NSString *app_dir(void) {
    char exe[PATH_MAX];
    uint32_t size = sizeof exe;
    return _NSGetExecutablePath(exe, &size) ? nil : @(exe).stringByDeletingLastPathComponent;
}

// One DER element at p (single-byte tags, definite lengths: CMS from codesign and zsign is DER): its tag,
// and its contents' range. NO if it runs past `end`.
static BOOL der_element(const uint8_t *p, const uint8_t *end, uint8_t *tag, const uint8_t **body, size_t *length) {
    if (end - p < 2) return NO;
    *tag = p[0];
    size_t n = p[1], header = 2;
    if (n & 0x80) {
        size_t bytes = n & 0x7F;
        if (!bytes || bytes > 4 || (size_t)(end - p) < 2 + bytes) return NO;  // 0x80 is indefinite: not DER
        n = 0;
        for (size_t i = 0; i < bytes; i++) n = n << 8 | p[2 + i];
        header += bytes;
    }
    if ((size_t)(end - p) - header < n) return NO;
    *body = p + header;
    *length = n;
    return YES;
}

// A CMS ContentInfo's SignedData certificates ([0] IMPLICIT SET OF Certificate), each one's whole DER.
static NSArray<NSData *> *cms_certificates(NSData *cms) {
    const uint8_t *p = cms.bytes, *end = p + cms.length, *body;
    size_t length;
    uint8_t tag;
    // ContentInfo ::= SEQUENCE { contentType OID, content [0] EXPLICIT SignedData }
    if (!der_element(p, end, &tag, &body, &length) || tag != 0x30) return @[];
    end = body + length;
    if (!der_element(body, end, &tag, &body, &length) || tag != 0x06) return @[];
    if (!der_element(body + length, end, &tag, &body, &length) || tag != 0xA0) return @[];
    // SignedData ::= SEQUENCE { version, digestAlgorithms SET, encapContentInfo SEQUENCE, certificates [0] OPTIONAL, ... }
    if (!der_element(body, body + length, &tag, &body, &length) || tag != 0x30) return @[];
    end = body + length;
    p = body;
    for (int field = 0; p < end; field++) {
        if (!der_element(p, end, &tag, &body, &length)) return @[];
        if (field == 3) {
            if (tag != 0xA0) return @[];  // no certificates
            NSMutableArray<NSData *> *certs = [NSMutableArray array];
            for (const uint8_t *c = body, *stop = body + length; c < stop;) {
                const uint8_t *inner;
                size_t n;
                if (!der_element(c, stop, &tag, &inner, &n) || tag != 0x30) return @[];
                [certs addObject:[NSData dataWithBytes:c length:(size_t)(inner + n - c)]];
                c = inner + n;
            }
            return certs;
        }
        p = body + length;
    }
    return @[];
}

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

NSArray<NSData *> *sp_image_certificates(NSString *path) {
    NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!f) return @[];
    NSData *head = [f readDataUpToLength:sizeof(struct mach_header_64) error:nil];
    if (head.length < sizeof(struct mach_header_64)) return @[];
    const struct mach_header_64 *mh = head.bytes;
    if (mh->magic != MH_MAGIC_64 || mh->sizeofcmds > 16 << 20) return @[];
    NSData *cmds = [f readDataUpToLength:mh->sizeofcmds error:nil];
    if (cmds.length < mh->sizeofcmds) return @[];
    uint32_t dataoff = 0, datasize = 0;
    for (uint32_t i = 0, off = 0; i < mh->ncmds && off + sizeof(struct load_command) <= cmds.length; i++) {
        const struct load_command *lc = (const void *)((const uint8_t *)cmds.bytes + off);
        if (lc->cmdsize < sizeof *lc || off + lc->cmdsize > cmds.length) return @[];
        if (lc->cmd == LC_CODE_SIGNATURE && lc->cmdsize >= sizeof(struct linkedit_data_command)) {
            dataoff = ((const struct linkedit_data_command *)lc)->dataoff;
            datasize = ((const struct linkedit_data_command *)lc)->datasize;
        }
        off += lc->cmdsize;
    }
    if (!datasize || datasize > 16 << 20) return @[];
    NSError *error = nil;
    if (![f seekToOffset:dataoff error:&error]) return @[];
    NSData *sig = [f readDataUpToLength:datasize error:nil];
    if (sig.length < 12) return @[];
    // The embedded signature: a superblob (big-endian) indexing its blobs by slot; 0x10000 is the CMS one.
    const uint8_t *s = sig.bytes;
    if (be32(s) != 0xFADE0CC0) return @[];
    uint32_t count = be32(s + 8);
    for (uint32_t i = 0; i < count && 12 + (size_t)i * 8 + 8 <= sig.length; i++) {
        if (be32(s + 12 + i * 8) != 0x10000) continue;
        uint32_t blob = be32(s + 16 + i * 8);
        if ((size_t)blob + 8 > sig.length || be32(s + blob) != 0xFADE0B01) return @[];
        uint32_t length = be32(s + blob + 4);
        if (length < 8 || (size_t)blob + length > sig.length) return @[];
        return cms_certificates([sig subdataWithRange:NSMakeRange(blob + 8, length - 8)]);
    }
    return @[];
}

NSArray<NSData *> *sp_profile_certificates(NSData *profile, NSDate *now) {
    if (!profile) return @[];
    NSRange start = [profile rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, profile.length)];
    if (start.location == NSNotFound) return @[];
    NSRange end = [profile rangeOfData:[@"</plist>" dataUsingEncoding:NSUTF8StringEncoding] options:0
                                 range:NSMakeRange(start.location, profile.length - start.location)];
    if (end.location == NSNotFound) return @[];
    NSDictionary *plist = [NSPropertyListSerialization
        propertyListWithData:[profile subdataWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)]
                     options:NSPropertyListImmutable format:NULL error:nil];
    if (![plist isKindOfClass:NSDictionary.class]) return @[];
    NSDate *expires = plist[@"ExpirationDate"];
    if (![expires isKindOfClass:NSDate.class] || [expires compare:now] != NSOrderedDescending) return @[];
    NSMutableArray<NSData *> *certs = [NSMutableArray array];
    for (id c in plist[@"DeveloperCertificates"])
        if ([c isKindOfClass:NSData.class]) [certs addObject:c];
    return certs;
}

NSArray<NSData *> *sp_listed_certificates(void) {
    NSMutableArray<NSData *> *listed = [NSMutableArray array];
    NSString *app = app_dir();
    for (NSString *path in @[app ? [app stringByAppendingPathComponent:@"embedded.mobileprovision"] : @"",
                             home(@"Library/spprofile.mobileprovision")])
        if (path.length) [listed addObjectsFromArray:sp_profile_certificates([NSData dataWithContentsOfFile:path], [NSDate date])];
    return listed;
}

BOOL sp_certificates_listed(NSArray<NSData *> *certificates, NSArray<NSData *> *listed) {
    for (NSData *c in certificates)
        if ([listed containsObject:c]) return YES;
    return NO;
}
