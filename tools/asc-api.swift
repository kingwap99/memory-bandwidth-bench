// App Store Connect API helper.
//
// Usage:
//   swift tools/asc-api.swift <issuer-id> GET  /v1/apps
//   swift tools/asc-api.swift <issuer-id> POST /v1/bundleIds body.json
//
// Authenticates with the API key in ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8.
import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: asc-api <issuer-id> <METHOD> <path> [body.json]\n".utf8))
    exit(2)
}
let issuer = args[1]
let method = args[2].uppercased()
let path = args[3]

let keyID = "7GLNK98WQK"
let keyURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
guard let pem = try? String(contentsOf: keyURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read API key at \(keyURL.path)\n".utf8))
    exit(1)
}
let privateKey: P256.Signing.PrivateKey
do {
    privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
} catch {
    FileHandle.standardError.write(Data("bad private key: \(error)\n".utf8))
    exit(1)
}

func b64url(_ data: Data) -> String {
    var s = data.base64EncodedString()
    s = s.replacingOccurrences(of: "+", with: "-")
    s = s.replacingOccurrences(of: "/", with: "_")
    s = s.replacingOccurrences(of: "=", with: "")
    return s
}

let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
let now = Int(Date().timeIntervalSince1970)
let payload: [String: Any] = [
    "iss": issuer,
    "iat": now,
    "exp": now + 1200,
    "aud": "appstoreconnect-v1",
]
let headerData = try JSONSerialization.data(withJSONObject: header)
let payloadData = try JSONSerialization.data(withJSONObject: payload)
let signingInput = b64url(headerData) + "." + b64url(payloadData)
let signature = try privateKey.signature(for: Data(signingInput.utf8))
let token = signingInput + "." + b64url(signature.rawRepresentation)

var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
request.httpMethod = method
request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Accept")
if args.count >= 5 {
    request.httpBody = try Data(contentsOf: URL(fileURLWithPath: args[4]))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
}

let semaphore = DispatchSemaphore(value: 0)
var status = 0
var out = Data()
URLSession.shared.dataTask(with: request) { data, response, error in
    if let http = response as? HTTPURLResponse { status = http.statusCode }
    if let error { out = Data("error: \(error)\n".utf8) }
    if let data { out = data }
    semaphore.signal()
}.resume()
semaphore.wait()
FileHandle.standardOutput.write(out)
FileHandle.standardOutput.write(Data("\n[status \(status)]\n".utf8))
exit(status >= 200 && status < 300 ? 0 : 1)
