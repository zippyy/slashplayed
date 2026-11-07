// Signing on the device (spsign.m): a development identity the companion pushed, kept in the app's
// keychain, signs a client image the launcher made (spassemble.m) so it loads from Library/. zsign does the
// signing (spzsign.cpp, scripts/build-zsign.sh). The signer itself (sp_sign) is Foundation and Security
// only, so the companion's tests build it for the Mac and check its signatures with codesign.
//
// The identity is a credential: nothing here logs or returns its password, its key, its certificate's
// subject, or its hash. The lines these return say whether there is one and until when it's valid.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Signs a copy of `source` (a Mach-O: a client image, or a fixture) into `dest` with the identity in `p12`
// (opened by `password`) and the app's `profile` (its embedded.mobileprovision, for the team), as
// `identifier`. Never a non-executable's entitlements (iOS refuses a library or bundle that has them).
// The file zsign writes isn't the one that ends up at `dest`: zsign writes through a shared writable
// mapping, and loading such a file killed the app in dlopen (CODESIGNING, Invalid Page), so the signed
// bytes go into a new file with write() and that is renamed onto `dest`. `source` is left alone. NO and
// *problem (no values in it) when it can't: nothing is left at `dest` then, and nothing beside it.
BOOL sp_sign(NSString *source, NSString *dest, NSString *identifier, NSData *p12, NSString *password, NSData *profile,
             NSString *_Nullable *_Nullable problem);

// The launcher's: sp_sign with the identity in the keychain and the app's own embedded.mobileprovision, as
// the app's own bundle ID. Callers don't choose the identifier, because only that one loads everywhere: a free
// team's profiles are local ones, and for code from outside the app bundle amfid only takes a local profile
// whose application-identifier is <team>.<the signature's identifier> (anything else is "non-matching
// application-identifier", then -415). A paid team's profiles don't look at it, so a wrong one passes there
// and fails only for free teams (research/isideload). NO and *problem when there's no identity, no profile,
// or no bundle ID, or it can't sign.
BOOL sp_sign_with_identity(NSString *source, NSString *dest, NSString *_Nullable *_Nullable problem);

// What the companion pushed into Library/ (spidentity.p12 and spidentity.pass, both 0600), into the keychain
// (this device only, never synced), after SecPKCS12Import says the password opens it and it holds one
// identity. Both files are zeroed and deleted whatever happens. A line for the log, or nil when nothing was
// pushed. Every launcher start.
NSString *_Nullable sp_identity_import(void);

// Imports a user-picked P12 directly into this device's Keychain after verifying its
// certificate is listed by an installed provisioning profile. No secrets are logged.
BOOL sp_identity_import_selected(NSData *p12, NSString *password, NSString *_Nullable *_Nullable problem);

// The companion's Library/spidentity.forget (Update Games on This Device turned off): deletes the identity
// from the keychain, and anything pushed and not yet imported, and the marker. A line for the log, or nil when
// it didn't ask. Every launcher start, before sp_identity_import.
NSString *_Nullable sp_identity_forget_if_asked(void);

// The Settings sheet's Forget Signing Identity (spstart.m), at the tap: deletes the identity from the keychain
// and anything pushed and not yet imported, remembers it was forgotten here (so the status says "forgotten",
// and the companion turns its setting off rather than push it straight back), and rewrites
// Library/spidentity.txt at once. A line for the log.
NSString *sp_identity_forget(void);

// What the keychain's identity is, worked out once for the log line, the companion's status file, and the
// sheet. Dates only: never the certificate's subject, its key, or its password.
typedef NS_ENUM(NSInteger, SPIdentityState) {
    SPIdentityStateNone,        // nothing in the keychain
    SPIdentityStateForgotten,   // nothing, since the sheet's Forget (until the next import)
    SPIdentityStatePresent,     // opens, and its certificate is valid
    SPIdentityStateExpired,     // opens, and its certificate has expired
    SPIdentityStateUnreadable,  // something's there, but it doesn't open as one identity
};

@interface SPIdentityReading : NSObject
@property (nonatomic, readonly) SPIdentityState state;
// The certificate's end of validity (present and expired only).
@property (nonatomic, readonly, nullable) NSDate *notAfter;
// Whether a profile the app can see lists the certificate (present and expired only): what an update on the
// device can sign with only when it's present too (sp_identity_usable).
@property (nonatomic, readonly) BOOL listed;
// The log's line ("identity: ...").
@property (nonatomic, readonly) NSString *line;
// Library/spidentity.txt's word and date: "present <yyyy-MM-dd>", "expired <yyyy-MM-dd>" (the certificate's
// last valid day, UTC), "none", "forgotten", or "unreadable".
@property (nonatomic, readonly) NSString *status;
@end

// The reading of an identity's .p12 and its password (nil for none), at `now`, against the certificates the
// app's profiles list; `forgotten` is whether the sheet forgot one since the last import. No keychain: the
// companion's tests run it on the Mac.
SPIdentityReading *sp_identity_read(NSData *_Nullable p12, NSData *_Nullable password, BOOL forgotten,
                                    NSArray<NSData *> *listed, NSDate *now);

// The keychain identity's reading, now: the sheet's Game Updates section.
SPIdentityReading *sp_identity_reading(void);

// sp_identity_reading's line for the log, after writing its status for the companion as
// Library/spidentity.txt (one line). Every launcher start.
NSString *sp_identity_describe(void);

// Whether the keychain holds an identity that opens, whose certificate is still valid, and that a profile
// the app can see lists (sp_listed_certificates): what an update on the device signs with (sppatch.m offers
// Update only then). An image signed with a certificate no installed profile lists is refused like an ad hoc
// one (research/dlopentest, 5.3), so an identity that isn't listed would only make updates that don't load.
BOOL sp_identity_usable(void);

// ---- Which certificate an image is signed with, and which ones the device's profiles list

// The certificates (each one's DER) in a thin 64-bit Mach-O's code signature: its CMS blob's certificate set,
// the signer's and its issuers'. Empty for an unsigned or ad hoc image, or one that can't be read. Reads the
// header and the signature only, never through a mapping.
NSArray<NSData *> *sp_image_certificates(NSString *path);

// A provisioning profile's DeveloperCertificates (the file as installed: its plist inside a CMS envelope).
// Empty when it can't be read or has expired by `now`. The envelope's own signature isn't checked: this only
// predicts what the system decides at dlopen, which still has the last word.
NSArray<NSData *> *sp_profile_certificates(NSData *profile, NSDate *now);

// The certificates the profiles this app can see list: its own embedded.mobileprovision's, and those of
// Library/spprofile.mobileprovision, a copy of the profile the companion installed on the device for the
// Slashplayed certificate (a paid team's, B; the app's own profile lists it only once Xcode has made one since
// that certificate existed). The system's list is device-wide, but the app can't read it.
NSArray<NSData *> *sp_listed_certificates(void);

// Whether any of `certificates` is in `listed`. An image's set holds its issuers too, which no profile lists,
// so this is whether its signer is.
BOOL sp_certificates_listed(NSArray<NSData *> *certificates, NSArray<NSData *> *listed);

// The keychain identity's certificate (DER), nil without one that opens.
NSData *_Nullable sp_identity_certificate(void);

NS_ASSUME_NONNULL_END
