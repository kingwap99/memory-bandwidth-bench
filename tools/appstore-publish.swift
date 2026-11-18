// End-to-end App Store Connect publish for Memory Bandwidth Bench.
//
//   swift tools/appstore-publish.swift <issuer-id> [--dry-run]
//
// Steps performed against the App Store Connect API (authenticated with the
// API key in ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8):
//   1. register the bundle id if it is missing
//   2. create an "Apple Distribution" certificate and import it into the login keychain
//   3. create an App Store provisioning profile for that bundle id
//   4. archive + export a signed .pkg with xcodebuild
//   5. create the app record and the macOS App Store version if missing
//   6. upload the .pkg to the version
import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Configuration

let keyID = "7GLNK98WQK"
let bundleID = "com.kingwap99.MemoryBandwidthBench"
let appName = "Memory Bandwidth Bench"
let sku = "MEMORY-BANDWIDTH-BENCH"
let primaryCategory = "UTILITIES"
let teamID = "NZBLXS857E"
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("mbb-appstore-" + String(ProcessInfo.processInfo.processIdentifier))
let versionString: String = {
    let plist = repoRoot.appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let version = obj["CFBundleShortVersionString"] as? String else { return "1.0.0" }
    return version
}()

/// Set from the command line in main().
var issuer = ""
var dryRun = false
var privateKey: P256.Signing.PrivateKey?
var agreementRetries = 0
let agreementRetryLimit = 15

// MARK: - Logging

func log(_ message: String) {
    print("[appstore] \(message)")
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[appstore] ERROR: \(message)\n".utf8))
    exit(1)
}

// MARK: - JWT

func b64url(_ data: Data) -> String {
    var s = data.base64EncodedString()
    s = s.replacingOccurrences(of: "+", with: "-")
    s = s.replacingOccurrences(of: "/", with: "_")
    s = s.replacingOccurrences(of: "=", with: "")
    return s
}

func makeToken() throws -> String {
    let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
    let now = Int(Date().timeIntervalSince1970)
    let payload: [String: Any] = [
        "iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1",
    ]
    let h = try JSONSerialization.data(withJSONObject: header)
    let p = try JSONSerialization.data(withJSONObject: payload)
    let input = b64url(h) + "." + b64url(p)
    guard let privateKey else { throw APIError(status: 0, body: "API key not loaded") }
    let sig = try privateKey.signature(for: Data(input.utf8))
    return input + "." + b64url(sig.rawRepresentation)
}

// MARK: - API

struct APIError: Error {
    let status: Int
    let body: String
}

func api(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> [String: Any] {
    let token = try makeToken()
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
    request.httpMethod = method
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let sem = DispatchSemaphore(value: 0)
    var status = 0
    var text = ""
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let http = response as? HTTPURLResponse { status = http.statusCode }
        if let error { text = "transport error: \(error)" }
        if let data { text = String(data: data, encoding: .utf8) ?? "" }
        sem.signal()
    }.resume()
    sem.wait()
    guard (200..<300).contains(status) else {
        // Apple enables the endpoints right after the agreement is accepted, but
        // the rollout is not simultaneous. Wait and retry.
        if text.contains("REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED") {
            if agreementRetries < agreementRetryLimit {
                agreementRetries += 1
                log("endpoint \(path) not enabled yet; waiting 20s (\(agreementRetries)/\(agreementRetryLimit))")
                Thread.sleep(forTimeInterval: 20)
                agreementRetries = 0
                return try api(method, path, body: body)
            }
        }
        throw APIError(status: status, body: text)
    }
    if let data = text.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return obj
    }
    return [:]
}

func apiData(_ obj: [String: Any]) -> [String: Any] {
    obj["data"] as? [String: Any] ?? [:]
}

/// Fetch every page of a collection endpoint and return the merged "data" array.
func apiAll(_ path: String) throws -> [[String: Any]] {
    var items: [[String: Any]] = []
    var next: String? = path
    while let current = next {
        let obj = try api("GET", current)
        if let d = obj["data"] as? [[String: Any]] { items.append(contentsOf: d) }
        next = (obj["links"] as? [String: Any])?["next"] as? String
    }
    return items
}

// MARK: - Shell helpers

@discardableResult
func run(_ launchPath: String, _ arguments: [String], label: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.currentDirectoryURL = repoRoot
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        log("\(label) failed (exit \(process.terminationStatus))")
        print(text.suffix(4000))
        throw APIError(status: Int(process.terminationStatus), body: text)
    }
    return text
}

// MARK: - Step 1: bundle id

func ensureBundleId() throws -> String {
    let existing = try apiAll("/v1/bundleIds?filter%5Bidentifier%5D=\(bundleID)")
    if let match = existing.first {
        let id = match["id"] as? String ?? ""
        log("bundle id already registered: \(bundleID) (\(id))")
        return id
    }
    log("registering bundle id \(bundleID)")
    let body: [String: Any] = [
        "data": [
            "type": "bundleIds",
            "attributes": [
                "name": appName,
                "identifier": bundleID,
                "platform": "MAC_OS",
                "seedId": teamID,
            ],
        ],
    ]
    let created = apiData(try api("POST", "/v1/bundleIds", body: body))
    let id = created["id"] as? String ?? ""
    log("bundle id registered (\(id))")
    return id
}

// MARK: - Step 2: distribution certificate

/// Finds a usable "Apple Distribution" identity already in the login keychain.
func existingDistributionIdentity() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-identity", "-v", "-p", "codesigning"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    for line in text.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("\"Apple Distribution\""), t.contains(")") else { continue }
        let hash = t.split(separator: ")").first.map(String.init) ?? ""
        if !hash.isEmpty { return hash }
    }
    return nil
}

/// SHA-1 fingerprint of a DER certificate, matching the hash shown by
/// "security find-identity".
func sha1Hex(_ der: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    der.withUnsafeBytes { raw in
        _ = CC_SHA1(raw.baseAddress, CC_LONG(der.count), &digest)
    }
    return digest.map { String(format: "%02X", $0) }.joined()
}

func ensureDistributionCertificate() throws -> (identity: String, certificateID: String, keychain: String) {
    try? FileManager.default.createDirectory(at: p12Store, withIntermediateDirectories: true)
    // Reuse a certificate whose private key we still hold, so repeat runs do not
    // ask Apple for a new certificate every time.
    for cert in try apiAll("/v1/certificates") {
        let attrs = cert["attributes"] as? [String: Any] ?? [:]
        let type = attrs["certificateType"] as? String ?? ""
        guard type == "DISTRIBUTION" || type == "MAC_APP_DISTRIBUTION" else { continue }
        let id = cert["id"] as? String ?? ""
        guard let b64 = attrs["certificateContent"] as? String,
              let der = Data(base64Encoded: b64) else { continue }
        let stored = p12Store.appendingPathComponent("\(id).p12")
        guard FileManager.default.fileExists(atPath: stored.path) else { continue }
        log("reusing certificate \(id) (private key kept in ~/.appstoreconnect/signing)")
        return (sha1Hex(der), id, try makeSigningKeychain(p12: stored))
    }
    log("requesting a new Apple Distribution certificate")
    try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    let keyPath = workDir.appendingPathComponent("dist.key")
    let csrPath = workDir.appendingPathComponent("dist.csr")
    let subject = "/CN=Ching-yuan yang/OU=Developer/O=kingwap99/C=TW"
    try run("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes",
                                 "-keyout", keyPath.path, "-out", csrPath.path,
                                 "-subj", subject], label: "openssl req")
    let derPath = workDir.appendingPathComponent("dist.csr.der")
    try run("/usr/bin/openssl", ["req", "-in", csrPath.path, "-outform", "DER", "-out", derPath.path],
            label: "openssl csr")
    guard let csrData = try? Data(contentsOf: derPath) else { fail("cannot read the CSR") }
    let body: [String: Any] = [
        "data": [
            "type": "certificates",
            "attributes": [
                "certificateType": "MAC_APP_DISTRIBUTION",
                "csrContent": csrData.base64EncodedString(),
            ],
        ],
    ]
    let created = apiData(try api("POST", "/v1/certificates", body: body))
    let certID = created["id"] as? String ?? ""
    guard let attrs = created["attributes"] as? [String: Any],
          let certBase64 = attrs["certificateContent"] as? String,
          let certDER = Data(base64Encoded: certBase64) else {
        fail("certificate creation did not return certificate content")
    }
    let cerPath = workDir.appendingPathComponent("dist.cer")
    let pemPath = workDir.appendingPathComponent("dist.pem")
    let p12Path = workDir.appendingPathComponent("dist.p12")
    try certDER.write(to: cerPath)
    try run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", cerPath.path, "-out", pemPath.path],
            label: "openssl x509")
    try run("/usr/bin/openssl", ["pkcs12", "-export", "-out", p12Path.path,
                                 "-inkey", keyPath.path, "-in", pemPath.path,
                                 "-passout", "pass:mbbappstore"], label: "openssl pkcs12")
    try FileManager.default.copyItem(at: p12Path,
                                      to: p12Store.appendingPathComponent("\(certID).p12"))
    try ensureIntermediateCertificate()
    let keychain = try makeSigningKeychain(p12: p12Path)
    let identity = sha1Hex(certDER)
    log("imported Apple Distribution certificate \(certID) into a temporary keychain")
    return (identity, certID, keychain)
}

// MARK: - Step 3: App Store provisioning profile

/// Persistent home for the certificate private keys.
var p12Store: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".appstoreconnect/signing")
}

/// macOS no longer ships the "Apple Worldwide Developer Relations Certification
/// Authority (G3)" intermediate that developer certificates chain to. Fetch it
/// from Apple and add it to the login keychain so the chain resolves.
func ensureIntermediateCertificate() throws {
    let cert = workDir.appendingPathComponent("AppleWWDRCAG3.cer")
    if !FileManager.default.fileExists(atPath: cert.path) {
        try run("/usr/bin/curl", ["-fsSL", "-o", cert.path,
                                  "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"],
                label: "download WWDR G3")
    }
    let dest = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["add-certificates", "-k", dest, cert.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    log("ensured the Apple WWDR G3 intermediate is in the login keychain")
}

/// Builds a throwaway keychain holding only the signing key, so codesign never
/// has to ask for keychain authorisation.
func makeSigningKeychain(p12: URL) throws -> String {
    let password = "mbbappstore"
    let keychain = workDir.appendingPathComponent("signing.keychain-db").path
    try? FileManager.default.removeItem(atPath: keychain)
    try run("/usr/bin/security", ["create-keychain", "-p", password, keychain], label: "create-keychain")
    try run("/usr/bin/security", ["unlock-keychain", "-p", password, keychain], label: "unlock-keychain")
    try run("/usr/bin/security", ["import", p12.path, "-k", keychain, "-P", "mbbappstore",
                                  "-T", "/usr/bin/codesign", "-A"], label: "security import")
    try run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                                  "-s", "-k", password, keychain], label: "set-key-partition-list")
    return keychain
}

func ensureProfile(bundleIDResourceID: String, certificateID: String) throws -> String {
    let profiles = try apiAll("/v1/profiles?filter%5BprofileType%5D=MAC_APP_STORE")
    let wanted = "MBB App Store \(bundleID)"
    for profile in profiles {
        let attrs = profile["attributes"] as? [String: Any] ?? [:]
        guard attrs["name"] as? String == wanted else { continue }
        let id = profile["id"] as? String ?? ""
        let existing = apiData(try api("GET", "/v1/profiles/" + id))
        let profileData = (existing["attributes"] as? [String: Any])?["profileContent"] as? String ?? ""
        if !profileData.isEmpty {
            let path = workDir.appendingPathComponent("profile.mobileprovision")
            try Data(base64Encoded: profileData)?.write(to: path)
            log("reusing provisioning profile \(wanted)")
            return wanted
        }
    }
    log("creating App Store provisioning profile \(wanted)")
    let body: [String: Any] = [
        "data": [
            "type": "profiles",
            "attributes": [
                "name": wanted,
                "profileType": "MAC_APP_STORE",
            ],
            "relationships": [
                "bundleId": ["data": ["type": "bundleIds", "id": bundleIDResourceID]],
                "certificates": ["data": [["type": "certificates", "id": certificateID]]],
            ],
        ],
    ]
    let created = apiData(try api("POST", "/v1/profiles", body: body))
    let id = created["id"] as? String ?? ""
    let content = (created["attributes"] as? [String: Any])?["profileContent"] as? String ?? ""
    guard let der = Data(base64Encoded: content) else { fail("profile has no content") }
    try der.write(to: workDir.appendingPathComponent("profile.mobileprovision"))
    log("provisioning profile created (\(id))")
    return wanted
}

/// Copies a .mobileprovision into Xcode's profile folder so xcodebuild can find it.
func installProfile(_ path: URL) throws {
    let dest = NSHomeDirectory() + "/Library/Developer/Xcode/UserData/Provisioning Profiles"
    try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
    let uuid = (try? run("/bin/sh", ["-c",
        "security cms -D -i \(path.path) | plutil -extract UUID raw -o - -"],
        label: "read profile UUID"))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = uuid.isEmpty ? "mbb-profile.provisionprofile" : "\(uuid).provisionprofile"
    try? FileManager.default.removeItem(atPath: dest + "/" + name)
    try FileManager.default.copyItem(at: path, to: URL(fileURLWithPath: dest + "/" + name))
    log("installed provisioning profile as \(name)")
}

// MARK: - Step 4: archive and export

func buildSignedPackage(identity: String, keychain: String) throws -> URL {
    let derived = workDir.appendingPathComponent("DerivedData")
    log("building the Release app")
    try run("/usr/bin/xcodebuild", [
        "-project", "MemoryBandwidthBench.xcodeproj",
        "-scheme", "Memory Bandwidth Bench",
        "-configuration", "Release",
        "-derivedDataPath", derived.path,
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "build",
    ], label: "xcodebuild build")
    let app = derived.appendingPathComponent("Build/Products/Release/MemoryBandwidthBench.app")
    guard FileManager.default.fileExists(atPath: app.path) else {
        fail("the build did not produce \(app.path)")
    }
    let profile = workDir.appendingPathComponent("profile.mobileprovision")
    try FileManager.default.copyItem(at: profile,
                                      to: app.appendingPathComponent("Contents/embedded.provisionprofile"))
    log("signing with the Apple Distribution certificate")
    // xcodebuild locks keychains it touches, so unlock ours right before signing.
    try run("/usr/bin/security", ["unlock-keychain", "-p", "mbbappstore", keychain],
            label: "unlock signing keychain")
    try run("/usr/bin/codesign", [
        "--keychain", keychain,
        "--force", "--options", "runtime", "--timestamp",
        "--sign", identity,
        "--entitlements", "MemoryBandwidthBench.entitlements",
        app.path,
    ], label: "codesign")
    try run("/usr/bin/codesign", ["--verify", "--verbose=2", app.path], label: "codesign --verify")
    let staging = workDir.appendingPathComponent("pkgroot")
    try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: app, to: staging.appendingPathComponent(app.lastPathComponent))
    let pkg = workDir.appendingPathComponent("MemoryBandwidthBench.pkg")
    log("packaging the app for App Store Connect")
    try run("/usr/bin/pkgbuild", [
        "--root", staging.path,
        "--identifier", bundleID,
        "--version", versionString,
        "--install-location", "/",
        pkg.path,
    ], label: "pkgbuild")
    return pkg
}

// MARK: - Step 5: app record and App Store version

func ensureAppRecord() throws -> String {
    let apps = try apiAll("/v1/apps")
    for app in apps {
        let attrs = app["attributes"] as? [String: Any] ?? [:]
        if attrs["bundleId"] as? String == bundleID {
            log("app record already exists (\(attrs["name"] as? String ?? ""))")
            return app["id"] as? String ?? ""
        }
    }
    log("creating app record \(appName)")
    let body: [String: Any] = [
        "data": [
            "type": "apps",
            "attributes": [
                "name": appName,
                "bundleId": bundleID,
                "sku": sku,
            ],
            "relationships": [
                "primaryCategory": ["data": ["type": "appCategories", "id": primaryCategory]],
            ],
        ],
    ]
    let created: [String: Any]
    do {
        created = apiData(try api("POST", "/v1/apps", body: body))
    } catch let e as APIError where e.status == 403 {
        fail("""
        The App Store Connect API cannot create app records. Create it once in the web UI:
        App Store Connect > App > 新的 App, with name "\(appName)", bundle id \(bundleID),
        SKU \(sku) and the Utilities category. Then re-run this command.
        (API said: \(e.body))
        """)
    }
    let id = created["id"] as? String ?? ""
    log("app record created (\(id))")
    return id
}

func ensureVersion(appID: String, versionString: String) throws -> String {
    let versions = try apiAll("/v1/apps/\(appID)/appStoreVersions")
    for version in versions {
        let attrs = version["attributes"] as? [String: Any] ?? [:]
        if attrs["versionString"] as? String == versionString,
           attrs["platform"] as? String == "MAC_OS" {
            log("App Store version \(versionString) already exists")
            return version["id"] as? String ?? ""
        }
    }
    log("creating App Store version \(versionString) (MAC_OS)")
    let body: [String: Any] = [
        "data": [
            "type": "appStoreVersions",
            "attributes": ["versionString": versionString, "platform": "MAC_OS"],
            "relationships": ["app": ["data": ["type": "apps", "id": appID]]],
        ],
    ]
    let created = apiData(try api("POST", "/v1/appStoreVersions", body: body))
    let id = created["id"] as? String ?? ""
    log("App Store version created (\(id))")
    return id
}

// MARK: - Step 6: upload the package

func uploadBuild(versionID: String, packageURL: URL) throws {
    let payload = try Data(contentsOf: packageURL)
    log("uploading \(payload.count / 1024) KB to version \(versionID)")
    let body: [String: Any] = [
        "data": [
            "type": "builds",
            "attributes": [
                "version": versionString,
                "uploadOperations": [],
            ],
            "relationships": [
                "appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionID]],
            ],
        ],
    ]
    var created: [String: Any]
    do {
        created = apiData(try api("POST", "/v1/builds", body: body))
    } catch let e as APIError where e.status == 404 || e.status == 405 {
        log("POST /v1/builds unavailable (\(e.status)); using the version-scoped endpoint")
        created = apiData(try api("POST", "/v1/appStoreVersions/" + versionID + "/build", body: body))
    }
    let attrs = created["attributes"] as? [String: Any] ?? [:]
    let operations = attrs["uploadOperations"] as? [[String: Any]] ?? []
    guard !operations.isEmpty else { fail("no upload operations returned") }
    for op in operations {
        guard let urlString = op["url"] as? String,
              let url = URL(string: urlString) else { continue }
        let offset = (op["offset"] as? Int) ?? 0
        let length = (op["length"] as? Int) ?? 0
        var request = URLRequest(url: url)
        request.httpMethod = (op["method"] as? String) ?? "PUT"
        let headers = op["requestHeaders"] as? [[String: Any]] ?? []
        for header in headers {
            if let name = header["name"] as? String, let value = header["value"] as? String {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        request.httpBody = payload.subdata(in: offset..<(offset + length))
        let sem = DispatchSemaphore(value: 0)
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse { status = http.statusCode }
            if let error { print("upload error: \(error)") }
            sem.signal()
        }.resume()
        sem.wait()
        guard (200..<300).contains(status) else {
            fail("upload chunk failed with status \(status)")
        }
    }
    log("upload finished")
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: appstore-publish <issuer-id> [--dry-run]\n".utf8))
    exit(2)
}
issuer = args[1]
dryRun = args.contains("--dry-run")
let keyURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
guard let pem = try? String(contentsOf: keyURL, encoding: .utf8) else {
    fail("cannot read API key at \(keyURL.path)")
}
guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
    fail("cannot parse API key")
}
privateKey = key
do {
    log("publishing \(appName) \(versionString) (\(bundleID))")
    let bundleResourceID = try ensureBundleId()
    let cert = try ensureDistributionCertificate()
    _ = try ensureProfile(bundleIDResourceID: bundleResourceID,
                          certificateID: cert.certificateID)
    try installProfile(workDir.appendingPathComponent("profile.mobileprovision"))
    if dryRun {
        log("dry run: bundle id, certificate and profile are ready; stopping before build/upload")
        exit(0)
    }
    let pkg = try buildSignedPackage(identity: cert.identity, keychain: cert.keychain)
    let appID = try ensureAppRecord()
    let versionID = try ensureVersion(appID: appID, versionString: versionString)
    try uploadBuild(versionID: versionID, packageURL: pkg)
    log("published successfully")
} catch let e as APIError {
    FileHandle.standardError.write(Data("[appstore] ERROR \(e.status): \(e.body)\n".utf8))
    exit(1)
} catch {
    fail("\(error)")
}
