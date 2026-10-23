import CryptoKit
import Foundation

let service = "PullYard Update Signing"
let account = "release"
let sourceFile = "Sources/PullYard/Features/Update/UpdateSignature.swift"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func security(_ args: [String]) -> (out: String, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { fail("Couldn't run security: \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus)
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let r = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard r.status == 0, let raw = Data(base64Encoded: r.out) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    if storedKey() != nil { fail("A signing key already exists in the Keychain (\(service)). Remove it first if you really want a new one; installed apps only trust the current public key.") }
    let key = Curve25519.Signing.PrivateKey()
    let add = Process()
    add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    add.arguments = ["-i"]
    let input = Pipe()
    add.standardInput = input
    add.standardOutput = FileHandle.nullDevice
    do { try add.run() } catch { fail("Couldn't run security: \(error)") }
    input.fileHandleForWriting.write(Data("add-generic-password -s \"\(service)\" -a \(account) -w \(key.rawRepresentation.base64EncodedString())\n".utf8))
    try? input.fileHandleForWriting.close()
    add.waitUntilExit()
    guard add.terminationStatus == 0, storedKey() != nil else { fail("Couldn't save the key to the Keychain") }
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    guard var source = try? String(contentsOfFile: sourceFile, encoding: .utf8),
          let range = source.range(of: #"static let publicKey = "[^"]*""#, options: .regularExpression) else { fail("Couldn't update \(sourceFile)") }
    source.replaceSubrange(range, with: "static let publicKey = \"\(publicKey)\"")
    try? source.write(toFile: sourceFile, atomically: true, encoding: .utf8)
    print("Private key saved to the login Keychain as \"\(service)\". Back it up in a password manager.")
    print("Public key written to \(sourceFile): \(publicKey)")
case "sign":
    guard let path = args.dropFirst().first else { fail("Usage: swift scripts/update_signing.swift sign <file>") }
    guard let key = storedKey() else { fail("No signing key in the Keychain. Run: swift scripts/update_signing.swift keygen") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("Couldn't read \(path)") }
    let signature = try key.signature(for: data).base64EncodedString()
    try (signature + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("Signed: \(path).sig")
case "public-key":
    guard let key = storedKey() else { fail("No signing key in the Keychain.") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
default:
    fail("Usage: swift scripts/update_signing.swift keygen | sign <file> | public-key")
}
