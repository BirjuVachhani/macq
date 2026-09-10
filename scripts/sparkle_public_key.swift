#!/usr/bin/env swift

// Derive the public half of an exported Sparkle EdDSA private key without ever
// printing the private half. New Sparkle keys are a 32-byte Ed25519 seed; the
// older 96-byte format already carries its 32-byte public key at the end.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: sparkle_public_key.swift <private-key-file>")
}

let path = CommandLine.arguments[1]
let contents: String
do {
    contents = try String(contentsOfFile: path, encoding: .utf8)
} catch {
    fail("could not read \(path): \(error.localizedDescription)")
}

guard let secret = Data(base64Encoded: contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    fail("\(path) does not contain a base64-encoded Sparkle key")
}

let publicKey: Data
switch secret.count {
case 32:
    do {
        publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
            .publicKey.rawRepresentation
    } catch {
        fail("could not derive the Ed25519 public key: \(error.localizedDescription)")
    }
case 96:
    publicKey = secret.suffix(32)
default:
    fail("decoded Sparkle key must contain 32 or 96 bytes, found \(secret.count)")
}

print(publicKey.base64EncodedString())
