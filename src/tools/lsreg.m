/*
 * lsreg APP.app ...: an application of this image told to LaunchServices as one of the system's, so that it has an
 * icon and starts -- for applications the image carries itself (share/system-apps: the Metal test application), which
 * are on the boot volume and not in the system volume's /Applications, where nobody can add one. What LaunchServices
 * gets is what it would have read from the bundle there: the path, the identifier, the type "System".
 * lsreg -u IDENTIFIER takes one away again; -o IDENTIFIER opens one; -q IDENTIFIER ... says what LaunchServices holds
 * of each (its place, its kind, its data container).
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dictionary;
- (BOOL)unregisterApplication:(NSURL *)url;
- (BOOL)openApplicationWithBundleID:(NSString *)identifier;
- (BOOL)installApplication:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error;
@end
@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (readonly) NSURL *bundleURL;
@property (readonly) NSURL *dataContainerURL;
@property (readonly) NSString *applicationType;
@property (readonly) BOOL isInstalled;
@end
@interface LSApplicationRecord : NSObject
- (instancetype)initWithBundleIdentifier:(NSString *)identifier allowPlaceholder:(BOOL)placeholder error:(NSError **)error;
@property (readonly) NSURL *dataContainerURL;
@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
		int failed = 0, tries = 1;

		/* -w SECONDS APP.app ... (11-20, com.hakios.apps at every start): wait that long first, and try a registration
		 * that fails again every 5 s, five times -- LaunchServices may not be up yet */
		if (argc >= 4 && strcmp(argv[1], "-w") == 0) {
			sleep((unsigned)atoi(argv[2]));
			argv += 2;
			argc -= 2;
			tries = 6;
		}

		if (argc == 3 && strcmp(argv[1], "-u") == 0) {
			LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:@(argv[2])];
			BOOL ok = proxy.bundleURL != nil && [workspace unregisterApplication:proxy.bundleURL];

			printf("lsreg: %s: %s\n", argv[2], ok ? "taken away" : "not registered, or not taken away");
			return !ok;
		}
		if (argc >= 3 && strcmp(argv[1], "-q") == 0) {
			/* -q IDENTIFIER ...: what LaunchServices holds of each -- where it is, its kind, its data container */
			for (int i = 2; i < argc; i++) {
				LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:@(argv[i])];
				NSError *error = nil;
				LSApplicationRecord *record = [[NSClassFromString(@"LSApplicationRecord") alloc] initWithBundleIdentifier:@(argv[i])
														       allowPlaceholder:NO error:&error];

				printf("lsreg: %s: %s, type %s, at %s; data container (proxy) %s, (record) %s\n", argv[i],
				    proxy.isInstalled ? "installed" : "NOT installed", proxy.applicationType.UTF8String ?: "?",
				    proxy.bundleURL.path.UTF8String ?: "-", proxy.dataContainerURL.path.UTF8String ?: "NONE",
				    record != nil ? (record.dataContainerURL.path.UTF8String ?: "NONE") : "no record");
			}
			return 0;
		}
		/*
		 * -i APP.app (11-28): installed the way a developer's app is (installd, "Developer" package -- Xcode's and
		 * ideviceinstaller's way); iOS 27's LaunchServices refuses registerApplicationDictionary without a word.
		 * installd takes a copy of the bundle into its own container.
		 */
		if (argc == 3 && strcmp(argv[1], "-i") == 0) {
			NSError *error = nil;
			BOOL ok = [workspace installApplication:[NSURL fileURLWithPath:@(argv[2])]
						    withOptions:@{ @"PackageType": @"Developer" } error:&error];

			printf("lsreg: %s: %s%s\n", argv[2], ok ? "installed" : "NOT installed: ",
			    ok ? "" : error.description.UTF8String ?: "(no error)");
			return !ok;
		}
		/*
		 * -I APP.app [DOMAIN] (11-28): installd's own client (MobileInstallation's MIInstallerClient, as
		 * MobileInstallationInstallApp uses it): -installURL:identity:targetingDomain:withOptions:returningResultInfo:
		 * completion:. The domain's numbers are not public (default 2); the completion's arguments are printed as they come.
		 */
		if (argc >= 3 && strcmp(argv[1], "-I") == 0) {
			NSString *path = @(argv[2]);
			NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
			unsigned long domain = argc >= 4 ? strtoul(argv[3], NULL, 0) : 2;
			dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW);
			Class ic = NSClassFromString(@"MIInstallerClient"), idc = NSClassFromString(@"MIAppIdentity");
			dispatch_semaphore_t done = dispatch_semaphore_create(0);
			__block int result = 1;

			if (ic == Nil || idc == Nil || info[@"CFBundleIdentifier"] == nil) {
				printf("lsreg: -I: no MIInstallerClient/MIAppIdentity, or no identifier\n");
				return 1;
			}
			id client = ((id (*)(Class, SEL, id))objc_msgSend)(ic, sel_registerName("installerWithProgressBlock:"),
			    ^(id progress) { printf("lsreg: progress %s\n", [[progress description] UTF8String]); });
			id identity = ((id (*)(id, SEL, id))objc_msgSend)([idc alloc], sel_registerName("initWithBundleID:"),
			    info[@"CFBundleIdentifier"]);
			/* (installd decodes an MIInstallOptions, not a dictionary: an NSDictionary there and it drops the connection) */
			id options = ((id (*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"MIInstallOptions") alloc],
			    sel_registerName("initWithLegacyOptionsDictionary:"), @{ @"PackageType": @"Developer" });
			((void (*)(id, SEL, BOOL))objc_msgSend)(options, sel_registerName("setDeveloperInstall:"), YES);
			((void (*)(id, SEL, id))objc_msgSend)(options, sel_registerName("setBundleIdentifier:"), info[@"CFBundleIdentifier"]);
			((void (*)(id, SEL, id, id, unsigned long, id, BOOL, id))objc_msgSend)(client,
			    sel_registerName("installURL:identity:targetingDomain:withOptions:returningResultInfo:completion:"),
			    [NSURL fileURLWithPath:path], identity, domain, options, YES,
			    ^(unsigned long a, id b, id c, id d) {
				printf("lsreg: completion: %#lx (%s) (%s) (%s)\n", a, [[b description] UTF8String] ?: "nil",
				    [[c description] UTF8String] ?: "nil", [[d description] UTF8String] ?: "nil");
				result = (a != 0 && ![b isKindOfClass:[NSError class]] && ![c isKindOfClass:[NSError class]] &&
				    ![d isKindOfClass:[NSError class]]) ? 0 : 1;
				dispatch_semaphore_signal(done);
			});
			dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC));
			return result;
		}
		if (argc == 3 && strcmp(argv[1], "-o") == 0) {
			BOOL ok = [workspace openApplicationWithBundleID:@(argv[2])];

			printf("lsreg: %s: %s\n", argv[2], ok ? "opened" : "NOT opened");
			return !ok;
		}
		for (int i = 1; i < argc; i++) {
			NSString *path = @(argv[i]);
			NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
			NSString *identifier = info[@"CFBundleIdentifier"];
			LSApplicationProxy *proxy;
			BOOL ok;

			if (identifier == nil) {
				printf("lsreg: %s: no Info.plist with an identifier\n", argv[i]);
				failed++;
				continue;
			}
			proxy = [LSApplicationProxy applicationProxyForIdentifier:identifier];
			if (proxy.isInstalled && [proxy.bundleURL.path isEqualToString:path]) {
				printf("lsreg: %s: registered already (%s)\n", identifier.UTF8String, argv[i]);
				continue;
			}
			for (int t = 0; t < tries; t++) {
				if (t > 0)
					sleep(5);
				ok = [workspace registerApplicationDictionary:@{
					@"ApplicationType": @"System",
					@"CFBundleIdentifier": identifier,
					@"CodeInfoIdentifier": identifier,
					@"CompatibilityState": @0,
					@"IsDeletable": @NO,
					@"IsAdHocSigned": @YES,
					@"Path": path,
					@"_LSBundlePlugins": @{},
				}];
				if (ok)
					break;
			}
			printf("lsreg: %s at %s: %s\n", identifier.UTF8String, argv[i], ok ? "registered" : "NOT registered");
			failed += !ok;
		}
		return failed != 0;
	}
}
