import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TelemessageCore

/// Fixture: clip.mov is a 1-second 160×120 H.264 test pattern in a QuickTime container.
nonisolated enum Scratch {
    static func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tm-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a solid image of `size` as `type`, optionally tagged with an EXIF orientation.
    static func image(_ name: String, size: CGSize, type: UTType, orientation: Int = 1, in directory: URL) -> URL {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let url = directory.appending(path: name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return url
    }
}

struct AttachmentPreparerTests {
    @Test func pngPhotoIsSentAsIs() async throws {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Scratch.image("shot.png", size: CGSize(width: 800, height: 600), type: .png, in: dir)
        let prepared = try await AttachmentPreparer.prepare(source: source, stagingDirectory: dir.appending(path: "staging"))
        #expect(prepared.kind == .photo)
        #expect(prepared.mediaPath == prepared.originalPath)
        #expect(prepared.width == 800 && prepared.height == 600)
        #expect(prepared.thumbnailPath.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(max(prepared.thumbnailSize.width, prepared.thumbnailSize.height) <= 320)
        // The staged copy is independent of the source.
        #expect(prepared.originalPath != source.path)
    }

    @Test func otherFormatsAndRotatedPhotosBecomeUprightJPEG() async throws {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tiff = Scratch.image("scan.tiff", size: CGSize(width: 400, height: 300), type: .tiff, in: dir)
        let fromTIFF = try await AttachmentPreparer.prepare(source: tiff, stagingDirectory: dir.appending(path: "staging"))
        #expect(fromTIFF.kind == .photo)
        #expect(fromTIFF.mediaPath.hasSuffix(".jpg"))

        let rotated = Scratch.image("portrait.jpg", size: CGSize(width: 400, height: 300), type: .jpeg, orientation: 6, in: dir)
        let fromRotated = try await AttachmentPreparer.prepare(source: rotated, stagingDirectory: dir.appending(path: "staging"))
        #expect(fromRotated.mediaPath != fromRotated.originalPath)
        #expect(fromRotated.width == 300 && fromRotated.height == 400)
    }

    @Test func quickTimeVideoIsRewrappedAsMP4() async throws {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = URL(fileURLWithPath: StickerFixtures.path("clip.mov"))
        let prepared = try await AttachmentPreparer.prepare(source: source, stagingDirectory: dir)
        #expect(prepared.kind == .video)
        #expect(prepared.mediaPath.hasSuffix(".mp4"))
        #expect(FileManager.default.fileExists(atPath: prepared.mediaPath))
        #expect(prepared.width == 160 && prepared.height == 120)
        #expect(prepared.duration == 1)
        #expect(prepared.thumbnailPath != nil)
    }

    @Test func otherFilesAreDocuments() async throws {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: source)
        let prepared = try await AttachmentPreparer.prepare(source: source, stagingDirectory: dir.appending(path: "staging"))
        #expect(prepared.kind == .document)
        #expect(prepared.fileName == "notes.txt")
        if case .document(let path, _, _) = prepared.content(asFile: false, caption: FormattedText(text: "")) {
            #expect(path == prepared.originalPath)
        } else {
            Issue.record("expected a document")
        }
    }

    @Test func sendAsFilesUsesTheOriginal() async throws {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Scratch.image("scan.tiff", size: CGSize(width: 200, height: 100), type: .tiff, in: dir)
        let prepared = try await AttachmentPreparer.prepare(source: source, stagingDirectory: dir.appending(path: "staging"))
        guard case .document(let path, _, _) = prepared.content(asFile: true, caption: FormattedText(text: "")) else {
            Issue.record("expected a document")
            return
        }
        #expect(path == prepared.originalPath)
        #expect(prepared.uploadPaths(asFile: true).contains(prepared.originalPath))
        #expect(!prepared.uploadPaths(asFile: true).contains(prepared.mediaPath))
    }

    @Test func directoriesAreRejected() async {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            try await AttachmentPreparer.prepare(source: dir, stagingDirectory: dir.appending(path: "staging"))
        }
    }
}

struct AlbumGroupingTests {
    private func item(_ kind: PreparedAttachment.Kind) -> PreparedAttachment {
        PreparedAttachment(id: UUID(), kind: kind, fileName: "f", originalPath: "/o", mediaPath: "/m", width: 1, height: 1,
                           duration: 0, thumbnailPath: nil, thumbnailSize: .zero, byteCount: 1)
    }

    @Test func groupsConsecutiveMediaAndDocuments() {
        let items = [item(.photo), item(.photo), item(.video), item(.document), item(.document), item(.photo)]
        #expect(AlbumGrouping.groups(items, asFiles: false).map(\.count) == [3, 2, 1])
        #expect(AlbumGrouping.groups(items, asFiles: true).map(\.count) == [6])
    }

    @Test func albumsHoldAtMostTen() {
        let items = (0..<23).map { _ in item(.photo) }
        #expect(AlbumGrouping.groups(items, asFiles: false).map(\.count) == [10, 10, 3])
    }
}

@MainActor
struct MediaRequestEncodingTests {
    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try TDCoding.encoder.encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func photoContentNestsInputPhoto() throws {
        let content = InputMessageContent.photo(path: "/tmp/p.jpg", thumbnail: nil, width: 800, height: 600,
                                                caption: FormattedText(text: "Hi"))
        let object = try json(content)
        #expect(object["@type"] as? String == "inputMessagePhoto")
        let photo = try #require(object["photo"] as? [String: Any])
        #expect(photo["@type"] as? String == "inputPhoto")
        #expect(photo["width"] as? Int == 800)
        let file = try #require(photo["photo"] as? [String: Any])
        #expect(file["@type"] as? String == "inputFileLocal")
        #expect(file["path"] as? String == "/tmp/p.jpg")
        #expect((object["caption"] as? [String: Any])?["text"] as? String == "Hi")
    }

    @Test func videoContentCarriesThumbnail() throws {
        let thumbnail = InputMessageContent.InputThumbnail(path: "/tmp/t.jpg", width: 320, height: 180)
        let object = try json(InputMessageContent.video(path: "/tmp/v.mp4", thumbnail: thumbnail, duration: 12,
                                                        width: 1280, height: 720, caption: FormattedText(text: "")))
        let video = try #require(object["video"] as? [String: Any])
        #expect(video["@type"] as? String == "inputVideo")
        #expect(video["duration"] as? Int == 12)
        #expect(video["supports_streaming"] as? Bool == true)
        let thumb = try #require(video["thumbnail"] as? [String: Any])
        #expect(thumb["@type"] as? String == "inputThumbnail")
        #expect((thumb["thumbnail"] as? [String: Any])?["path"] as? String == "/tmp/t.jpg")
    }

    @Test func albumEncodesContents() throws {
        let album = SendMessageAlbum(chatID: 5, contents: [
            .document(path: "/a", thumbnail: nil, caption: FormattedText(text: "")),
            .document(path: "/b", thumbnail: nil, caption: FormattedText(text: "")),
        ], replyToMessageID: 9)
        let object = try json(album)
        #expect((object["input_message_contents"] as? [[String: Any]])?.count == 2)
        #expect((object["reply_to"] as? [String: Any])?["message_id"] as? Int == 9)
    }
}

@MainActor
struct StagingStoreTests {
    private func stagedFile(in directory: URL) -> String {
        let folder = directory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "file.jpg")
        try? Data("x".utf8).write(to: url)
        return url.path
    }

    @Test func sentMessagesReleaseFilesFailedOnesKeepThem() throws {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = StagingStore(directory: dir, manifestURL: dir.appending(path: "staging.json"))
        let sent = stagedFile(in: dir), failed = stagedFile(in: dir)
        staging.register(paths: [sent], chatID: 1, messageID: 100)
        staging.register(paths: [failed], chatID: 1, messageID: 101)
        staging.messageReplaced(chatID: 1, oldMessageID: 100, newMessageID: 5, sent: true)
        staging.messageReplaced(chatID: 1, oldMessageID: 101, newMessageID: 102, sent: false)
        #expect(!FileManager.default.fileExists(atPath: sent))
        #expect(FileManager.default.fileExists(atPath: failed))
        #expect(StagingStore(directory: dir, manifestURL: dir.appending(path: "staging.json")).trackedEntries.map(\.messageID) == [102])
    }

    @Test func retryKeepsFilesThroughTheDeletionOfTheFailedMessage() {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = StagingStore(directory: dir, manifestURL: nil)
        let file = stagedFile(in: dir)
        staging.register(paths: [file], chatID: 1, messageID: 102)
        staging.beginRetry(chatID: 1, messageID: 102)
        staging.messagesDeleted(chatID: 1, messageIDs: [102])
        staging.finishRetry(chatID: 1, oldMessageID: 102, newMessageID: 200)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(staging.trackedEntries.map(\.messageID) == [200])
        staging.messagesDeleted(chatID: 1, messageIDs: [200])
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func discardSparesTrackedFiles() {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = StagingStore(directory: dir, manifestURL: nil)
        let tracked = stagedFile(in: dir), loose = stagedFile(in: dir)
        staging.register(paths: [tracked], chatID: 1, messageID: 1)
        staging.discard([tracked, loose])
        #expect(FileManager.default.fileExists(atPath: tracked))
        #expect(!FileManager.default.fileExists(atPath: loose))
    }

    @Test func reconcileKeepsOnlyUnsentMessages() async throws {
        let dir = Scratch.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = MockTransport { request in
            guard request["@type"] as? String == "getMessage", let id = request["message_id"] as? Int64 else {
                return [MockTransport.reply(to: request, #"{"@type":"ok"}"#)]
            }
            switch id {
            case 1: return [MockTransport.reply(to: request, Fixture.message(id: 1, outgoing: true, pending: true))]
            case 2: return [MockTransport.reply(to: request, Fixture.message(id: 2, outgoing: true))]
            default: return [MockTransport.reply(to: request, #"{"@type":"error","code":404,"message":"Not Found"}"#)]
            }
        }
        let session = TelegramSession(transport: transport, configuration: .init(
            secrets: TelegramSecrets(apiID: 1, apiHash: "x"), dataDirectory: dir, databaseKey: Data(), applicationVersion: "t"))
        session.start()
        let staging = StagingStore(directory: dir.appending(path: "Staging"), manifestURL: nil)
        let pending = stagedFile(in: staging.directory), sent = stagedFile(in: staging.directory)
        let missing = stagedFile(in: staging.directory), orphan = stagedFile(in: staging.directory)
        staging.register(paths: [pending], chatID: 100, messageID: 1)
        staging.register(paths: [sent], chatID: 100, messageID: 2)
        staging.register(paths: [missing], chatID: 100, messageID: 3)
        await staging.reconcile(session: session)
        #expect(staging.trackedEntries.map(\.messageID) == [1])
        #expect(FileManager.default.fileExists(atPath: pending))
        for path in [sent, missing, orphan] { #expect(!FileManager.default.fileExists(atPath: path)) }
    }
}
