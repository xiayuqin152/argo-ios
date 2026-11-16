#!/usr/bin/env python3
"""Linux integration check: compile the real PhoneNotifications with inert OS adapters.

ArgoConnection and ArgoHostStore are the production Swift package. The UIKit /
UserNotifications stand-ins only replace OS calls; no socket or push is opened.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
STUBS = {
    'UIKit': '''
@MainActor public final class UIApplication {
    public static let shared = UIApplication()
    public func registerForRemoteNotifications() {}
}
''',
    'UserNotifications': '''
import Foundation
public enum UNAuthorizationStatus: Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral
}
public struct UNAuthorizationOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let alert = Self(rawValue: 1), sound = Self(rawValue: 2)
}
public struct UNNotificationSettings: Sendable {
    public let authorizationStatus = UNAuthorizationStatus.authorized
}
public struct UNNotificationContent {
    public var userInfo: [AnyHashable: Any] = [:]
}
public struct UNNotificationRequest {
    public var content = UNNotificationContent()
    public var identifier = "synthetic"
}
public struct UNNotification { public var request = UNNotificationRequest() }
public final class UNUserNotificationCenter: Sendable {
    public static func current() -> UNUserNotificationCenter { .init() }
    public func notificationSettings() async -> UNNotificationSettings { .init() }
    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    public func getDeliveredNotifications(completionHandler: ([UNNotification]) -> Void) { completionHandler([]) }
    public func getPendingNotificationRequests(completionHandler: ([UNNotificationRequest]) -> Void) { completionHandler([]) }
    public func removeDeliveredNotifications(withIdentifiers: [String]) {}
    public func removePendingNotificationRequests(withIdentifiers: [String]) {}
}
''',
}


def run(cmd, **kwargs):
    subprocess.run([str(x) for x in cmd], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift', default='swift', help='Linux Swift executable (default: PATH)')
    parser.add_argument('--scratch-path', type=Path, default=ROOT / '.build/notification-unregister-check')
    parser.add_argument('--phone-source', type=Path,
                        default=ROOT / 'ios/Argo/Notifications/PhoneNotifications.swift')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('This check uses inert Linux OS adapters; run it with Linux Swift.')
    swift = shutil.which(args.swift)
    if not swift:
        parser.error('Linux Swift is required; select it with --swift.')
    swiftc = Path(swift).with_name('swiftc')
    scratch = args.scratch_path.resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    core = scratch / 'core'
    run([swift, 'build', '--package-path', ROOT / 'ios/Packages/ArgoMobileKit',
         '--scratch-path', core, '--jobs', '2'])
    for name, source in STUBS.items():
        path = scratch / (name + '.swift')
        path.write_text(source)
        run([swiftc, '-swift-version', '6', '-j2', '-emit-module', '-emit-library',
             '-module-name', name, path, '-emit-module-path', scratch / (name + '.swiftmodule'),
             '-o', scratch / ('lib' + name + '.so')])
    debug = next(core.glob('*/debug/Modules/ArgoMobileKit.swiftmodule')).parents[1]
    executable = scratch / 'NotificationUnregisterCheck'
    run([swiftc, '-swift-version', '6', '-parse-as-library', '-j2',
         '-I', debug / 'Modules', '-I', scratch, '-L', scratch, '-lUIKit', '-lUserNotifications',
         '-Xlinker', '-rpath', '-Xlinker', scratch,
         args.phone_source.resolve(), ROOT / 'ios/Argo/Verification/NotificationUnregisterCheck.swift',
         *sorted((debug / 'ArgoMobileKit.build').glob('*.swift.o')), '-o', executable])
    scenarios = [
        ('revoked-token', 'remove'), ('revoked-open', 'remove'),
        ('revoked-token', 'repair'), ('revoked-open', 'repair'),
        ('success', 'remove'), ('success', 'repair'),
        ('fingerprint', 'remove'), ('offline', 'remove'), ('timeout', 'repair'),
        ('banned', 'remove'), ('device-table-unreadable', 'repair'),
        ('http401', 'remove'), ('http403', 'repair'), ('http503', 'remove'),
        ('cancelled', 'repair'), ('missing-token', 'remove'),
    ]
    results = []
    for scenario, action in scenarios:
        config = scratch / ('defaults-' + scenario + '-' + action)
        config.mkdir(exist_ok=True)
        env = dict(os.environ, XDG_CONFIG_HOME=str(config.resolve()))
        result = subprocess.run([str(executable), scenario, action], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        print(result.stdout.strip(), flush=True)
        results.append(dict(scenario=scenario, action=action, exit=result.returncode,
                            output=result.stdout.strip()))
    args.output.write_text(json.dumps(results, indent=2) + '\n')
    passed = sum(x['exit'] == 0 for x in results)
    print(f'{passed}/{len(results)} integration scenarios passed')
    return 0 if passed == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())
