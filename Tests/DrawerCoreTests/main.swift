import Foundation
import CoreGraphics
import DrawerCore
#if os(macOS)
import Darwin
#endif

var failures = 0
var checks = 0
@MainActor func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}

@MainActor func runChecks() -> Int32 {
var pointer = PointerIntent()
let topRegion = CGRect(x: 300, y: 1072, width: 660, height: 8)
expect(PointerIntent.containsTopEdge(CGPoint(x: 800, y: 1080), in: topRegion), "mouse against exact top boundary can open staging")
expect(PointerIntent.containsTopEdge(CGPoint(x: 950, y: 1079), in: topRegion), "right staging-side top edge opens too")
expect(!PointerIntent.containsTopEdge(CGPoint(x: 970, y: 1080), in: topRegion), "unrelated menu positions outside drawer don't open")
expect(!PointerIntent.containsTopEdge(CGPoint(x: 800, y: 1060), in: topRegion), "ordinary menu height doesn't count as top edge")
expect(!pointer.drag(buttonDown: false, point: .zero), "idle doesn't arm native receiver")
expect(!pointer.drag(buttonDown: true, point: .zero), "click doesn't arm receiver")
expect(!pointer.drag(buttonDown: true, point: CGPoint(x: 2, y: 1)), "tiny mouse jitter doesn't arm")
expect(pointer.drag(buttonDown: true, point: CGPoint(x: 10, y: 0)), "drag movement arms native receiver without reading global file data")
pointer.consume()
expect(!pointer.drag(buttonDown: true, point: CGPoint(x: 20, y: 0)), "consumed session doesn't rearm")
expect(!pointer.drag(buttonDown: false, point: .zero), "release resets drag")
expect(!pointer.hover(inside: true, buttonsDown: false, now: 0), "hover requires dwell")
expect(!pointer.hover(inside: true, buttonsDown: false, now: 0.2), "brief menu crossing doesn't open")
expect(pointer.hover(inside: true, buttonsDown: false, now: 0.4), "intentional hover opens")
expect(!pointer.hover(inside: false, buttonsDown: false, now: 0.5), "leaving resets dwell")
expect(!pointer.hover(inside: true, buttonsDown: false, now: 1), "reentry starts new dwell")
expect(!pointer.hover(inside: true, buttonsDown: true, now: 2), "mouse press cancels hover")
expect(!pointer.hover(inside: true, buttonsDown: false, now: 3), "release starts fresh dwell")

let fixtureRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("DrawerCoreChecks \(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixtureRoot) }
let spacedFile = fixtureRoot.appendingPathComponent("file with spaces.txt")
let secondFile = fixtureRoot.appendingPathComponent("second.txt")
try! Data("one".utf8).write(to: spacedFile)
try! Data("two".utf8).write(to: secondFile)
let directory = fixtureRoot.appendingPathComponent("folder", isDirectory: true)
try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let nestedFile = directory.appendingPathComponent("nested.txt")
try! Data("nested".utf8).write(to: nestedFile)
let emptyDirectory = fixtureRoot.appendingPathComponent("empty folder", isDirectory: true)
try! FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
let keyPackage = fixtureRoot.appendingPathComponent("Presentation.key", isDirectory: true)
try! FileManager.default.createDirectory(at: keyPackage, withIntermediateDirectories: true)
try! Data("package content".utf8).write(to: keyPackage.appendingPathComponent("index.apxl"))
let fileSymlink = fixtureRoot.appendingPathComponent("file-link")
let directorySymlink = fixtureRoot.appendingPathComponent("folder-link")
let brokenSymlink = fixtureRoot.appendingPathComponent("broken-link")
try! FileManager.default.createSymbolicLink(at: fileSymlink, withDestinationURL: spacedFile)
try! FileManager.default.createSymbolicLink(at: directorySymlink, withDestinationURL: directory)
try! FileManager.default.createSymbolicLink(
    at: brokenSymlink,
    withDestinationURL: fixtureRoot.appendingPathComponent("does-not-exist")
)

do {
    let validated = try DropPayload.validate([spacedFile, spacedFile])
    expect(validated == [spacedFile.standardizedFileURL], "valid files deduplicate preserving order")
} catch {
    expect(false, "valid readable file with spaces should validate")
}
do {
    let alias = fixtureRoot.appendingPathComponent("folder/../file with spaces.txt")
    let validated = try DropPayload.validate([alias])
    expect(validated == [alias], "validation preserves the original selected URL")
} catch {
    expect(false, "a path alias to a readable file should validate")
}
do {
    let validated = try DropPayload.validate([fileSymlink, directorySymlink])
    expect(validated == [fileSymlink, directorySymlink], "file and directory symlinks validate and preserve selected URLs")
} catch {
    expect(false, "symlinks to readable files and folders should validate")
}
do {
    _ = try DropPayload.validate([brokenSymlink])
    expect(false, "broken symlinks must be rejected")
} catch let error as DropPayload.ValidationError {
    expect(error == .missingFile, "broken symlink rejection has the expected error")
} catch {
    expect(false, "broken symlink rejection uses ValidationError")
}
do {
    let validated = try DropPayload.validate([directory])
    expect(validated == [directory], "folders are accepted and returned unchanged")
    expect(FileManager.default.fileExists(atPath: nestedFile.path), "folder contents remain untouched")
} catch {
    expect(false, "readable folder should validate")
}
do {
    let validated = try DropPayload.validate([emptyDirectory, keyPackage])
    expect(validated == [emptyDirectory, keyPackage], "empty folders and package directories are accepted")
} catch {
    expect(false, "empty folder and key package should validate")
}
do {
    let validated = try DropPayload.validate([spacedFile, directory, keyPackage])
    expect(validated == [spacedFile, directory, keyPackage], "mixed files and folders are accepted in order")
} catch {
    expect(false, "mixed file and folder batch should validate")
}
do {
    _ = try DropPayload.validate([spacedFile, fixtureRoot.appendingPathComponent("missing.txt")])
    expect(false, "mixed valid and missing files reject the whole batch")
} catch let error as DropPayload.ValidationError {
    expect(error == .missingFile, "missing file rejection has the expected error")
} catch {
    expect(false, "missing file rejection uses ValidationError")
}
do {
    _ = try DropPayload.validate([spacedFile, URL(string: "https://example.com/file.txt")!])
    expect(false, "remote URLs must be rejected")
} catch let error as DropPayload.ValidationError {
    expect(error == .remoteURL, "remote URL rejection has the expected error")
} catch {
    expect(false, "remote URL rejection uses ValidationError")
}
do {
    let validated = try DropPayload.validate([secondFile, spacedFile, secondFile])
    expect(validated == [secondFile.standardizedFileURL, spacedFile.standardizedFileURL], "duplicates preserve first occurrence order")
} catch {
    expect(false, "multiple valid files should validate")
}
do {
    _ = try DropPayload.validate([])
    expect(false, "empty payload must be rejected")
} catch let error as DropPayload.ValidationError {
    expect(error == .empty, "empty payload has the expected error")
} catch {
    expect(false, "empty payload rejection uses ValidationError")
}
#if os(macOS)
let fifo = fixtureRoot.appendingPathComponent("pipe")
if Darwin.mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0 {
    defer { try? FileManager.default.removeItem(at: fifo) }
    do {
        _ = try DropPayload.validate([fifo])
        expect(false, "nonregular FIFO files must be rejected")
    } catch let error as DropPayload.ValidationError {
        expect(error == .unreadableFile, "nonregular FIFO rejection has the expected error")
    } catch {
        expect(false, "nonregular FIFO rejection uses ValidationError")
    }
}
#endif

print("\(checks) checks, \(failures) failures")
return failures == 0 ? 0 : 1
}

exit(runChecks())
