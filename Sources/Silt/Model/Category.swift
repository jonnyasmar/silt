import AppKit
import SwiftUI

/// Broad buckets for "what kind of stuff is this", used to color bars and to
/// break a folder down by content.
enum FileCategory: Int, CaseIterable, Identifiable, Sendable {
    case video, images, audio, archives, apps, models, code, documents, other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .images: "Images"
        case .audio: "Audio"
        case .archives: "Archives & DMGs"
        case .apps: "Apps & Binaries"
        case .models: "Models & Data"
        case .code: "Code & Dev"
        case .documents: "Documents"
        case .other: "Other"
        }
    }

    var shortTitle: String {
        switch self {
        case .archives: "Archives"
        case .apps: "Binaries"
        case .models: "Data"
        case .code: "Code"
        default: title
        }
    }

    var nsColor: NSColor {
        switch self {
        case .video: NSColor(srgbRed: 0.56, green: 0.43, blue: 0.93, alpha: 1)
        case .images: NSColor(srgbRed: 0.27, green: 0.72, blue: 0.53, alpha: 1)
        case .audio: NSColor(srgbRed: 0.93, green: 0.39, blue: 0.56, alpha: 1)
        case .archives: NSColor(srgbRed: 0.95, green: 0.58, blue: 0.24, alpha: 1)
        case .apps: NSColor(srgbRed: 0.28, green: 0.55, blue: 0.95, alpha: 1)
        case .models: NSColor(srgbRed: 0.86, green: 0.36, blue: 0.30, alpha: 1)
        case .code: NSColor(srgbRed: 0.18, green: 0.70, blue: 0.78, alpha: 1)
        case .documents: NSColor(srgbRed: 0.88, green: 0.73, blue: 0.24, alpha: 1)
        case .other: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.58, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    private static let table: [String: FileCategory] = {
        var t: [String: FileCategory] = [:]
        func add(_ c: FileCategory, _ exts: String) {
            for e in exts.split(separator: " ") { t[String(e)] = c }
        }
        add(.video, "mov mp4 m4v mkv avi webm wmv flv mpg mpeg mts m2ts 3gp braw r3d mxf prproj fcpbundle")
        add(.images, "jpg jpeg png heic heif gif tif tiff bmp webp raw cr2 cr3 nef arw dng orf raf psd psb ai svg ico icns exr hdr sketch fig afphoto kra")
        add(.audio, "mp3 m4a aac wav aif aiff flac ogg opus caf alac mid midi logicx band als")
        add(.archives, "zip tar gz tgz bz2 xz zst 7z rar dmg iso img pkg mpkg xip sparseimage cpgz lz4 lzma cab deb rpm apk ipa")
        add(.apps, "app framework dylib so a o bundle kext appex xpc plugin exe dll bin")
        add(.models, "gguf safetensors ckpt pt pth onnx mlmodel mlpackage tflite h5 npy npz parquet arrow feather db sqlite sqlite3 realm lance vmdk vdi qcow2 raw hprof core")
        add(.code, "js mjs cjs ts tsx jsx swift rs c h cc cpp hpp m mm py pyc rb go java kt class jar json map css scss html wasm node lock yml yaml toml xml sh zsh pdb dsym dwarf swiftmodule swiftdoc swiftinterface swiftsourceinfo pch pcm idx pack rlib rmeta d dep bc ll gcda gcno tsbuildinfo pyd whl gem nib storyboardc car")
        add(.documents, "pdf doc docx pages key keynote numbers xls xlsx csv ppt pptx txt md rtf rtfd epub mobi odt ods tex log")
        return t
    }()

    static func of(extension ext: String) -> FileCategory {
        table[ext] ?? .other
    }

    static func of(name: String) -> FileCategory {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
        let ext = name[name.index(after: dot)...]
        if ext.count > 15 { return .other }
        return of(extension: ext.lowercased())
    }
}

/// The app's own accent: the ochre of river silt.
enum Brand {
    static let ochre = NSColor(name: "silt.ochre") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.91, green: 0.66, blue: 0.33, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.50, blue: 0.16, alpha: 1)
    }
    static var color: Color { Color(nsColor: ochre) }
    /// Label colour on an ochre fill: white is ~2:1 on the dark-mode ochre.
    static let ink = Color(nsColor: NSColor(srgbRed: 0.13, green: 0.09, blue: 0.04, alpha: 1))
}

/// A prominent button filled with the brand ochre and a legible label.
/// `.borderedProminent` overrides a foreground set on the button itself, so the
/// ink is applied to the label content.
struct BrandButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            // The fill goes gray when the window is inactive or the button is
            // disabled; dark ink on that gray is unreadable, so only use it on ochre.
            label.foregroundStyle(activeState != .inactive && isEnabled ? Brand.ink : Color.primary)
        }
        .buttonStyle(.borderedProminent)
        .tint(Brand.color)
    }
}

extension BrandButton where Label == Text {
    init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}
