#!/usr/bin/env bash
# Native macOS regression using an isolated, disposable file-based Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
kc="$tmp/lanliang-probe.keychain-db"
cleanup() { security delete-keychain "$kc" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
import Security
import LocalAuthentication

let args = CommandLine.arguments
var storage: SecKeychain?
guard SecKeychainOpen(args[1], &storage) == errSecSuccess, let keychain = storage else { exit(1) }
let context = LAContext()
context.interactionNotAllowed = true
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: "lanliang-ci-fixture",
                            kSecAttrAccount as String: "synthetic-account",
                            kSecMatchSearchList as String: [keychain],
                            kSecReturnData as String: true,
                            kSecMatchLimit as String: kSecMatchLimitOne,
                            kSecUseAuthenticationContext as String: context]
var before = DarwinBoolean(false)
var after = DarwinBoolean(false)
guard SecKeychainGetUserInteractionAllowed(&before) == errSecSuccess else { exit(2) }
var out: CFTypeRef?
var disabledInside = false
let status = KeychainInteraction.perform(interactive: false) {
    var inside = DarwinBoolean(true)
    disabledInside = SecKeychainGetUserInteractionAllowed(&inside) == errSecSuccess && !inside.boolValue
    return SecItemCopyMatching(query as CFDictionary, &out)
}
guard SecKeychainGetUserInteractionAllowed(&after) == errSecSuccess else { exit(3) }
var interactiveRestored = false
_ = KeychainInteraction.perform(interactive: true) {
    var allowed = DarwinBoolean(false)
    interactiveRestored = SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess &&
        allowed.boolValue == before.boolValue
    return errSecSuccess
}
let restored = before.boolValue == after.boolValue && interactiveRestored
print("KEYCHAIN_NATIVE status=\(status) gotData=\(out != nil) noUI=\(disabledInside) restored=\(restored)")
guard disabledInside, restored else { exit(4) }
SWIFT
xcrun swiftc "$tmp/main.swift" App/KeychainInteraction.swift -o "$tmp/probe"
password="fixture-only-$(uuidgen)"
security create-keychain -p "$password" "$kc"
security unlock-keychain -p "$password" "$kc"
security add-generic-password -s lanliang-ci-fixture -a synthetic-account -w not-a-credential -T "$tmp/probe" "$kc"
python3 - "$tmp/probe" "$kc" <<'PY'
import subprocess, sys, time
binary,kc=sys.argv[1:]
def run(locked):
    now=time.monotonic()
    p=subprocess.run([binary,kc],capture_output=True,text=True,timeout=4,check=True)
    elapsed=time.monotonic()-now
    status=p.stdout.strip()
    assert "noUI=true restored=true" in status, status
    assert ("status=0 gotData=true" if not locked else "gotData=false") in status, status
    assert (not locked or "status=0" not in status), status
    print(f"KEYCHAIN_NATIVE {'locked' if locked else 'unlocked'} elapsed={elapsed:.2f}s {status}", flush=True)
run(False)
subprocess.run(["security","lock-keychain",kc],check=True)
run(True)
PY
