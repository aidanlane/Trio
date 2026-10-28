import Foundation
@testable import Trio

/// A `FileStorage` that keeps its files in memory, so a test can set what the app reads without touching the app's own
/// files. Appending isn't needed yet, so it does nothing.
final class MockFileStorage: FileStorage {
    private var files: [String: RawJSON] = [:]

    func save<Value: JSON>(_ value: Value, as name: String) {
        files[name] = value.rawJSON
    }

    func saveAsync<Value: JSON>(_ value: Value, as name: String) async {
        save(value, as: name)
    }

    func retrieve<Value: JSON>(_ name: String, as _: Value.Type) -> Value? {
        files[name].flatMap { Value(from: $0) }
    }

    func retrieveAsync<Value: JSON>(_ name: String, as type: Value.Type) async -> Value? {
        retrieve(name, as: type)
    }

    func retrieveRaw(_ name: String) -> RawJSON? {
        files[name]
    }

    func retrieveRawAsync(_ name: String) async -> RawJSON? {
        files[name]
    }

    func append<Value: JSON>(_: Value, to _: String) {}
    func append<Value: JSON>(_: [Value], to _: String) {}
    func append<Value: JSON, T: Equatable>(_: Value, to _: String, uniqBy _: KeyPath<Value, T>) {}
    func append<Value: JSON, T: Equatable>(_: [Value], to _: String, uniqBy _: KeyPath<Value, T>) {}

    func remove(_ name: String) {
        files[name] = nil
    }

    func rename(_ name: String, to newName: String) {
        files[newName] = files.removeValue(forKey: name)
    }

    func transaction(_ exec: (FileStorage) -> Void) {
        exec(self)
    }

    func urlFor(file _: String) -> URL? { nil }
}
