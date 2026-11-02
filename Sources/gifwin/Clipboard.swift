import AppKit
import Foundation

enum Clipboard {
    /// Offers the finished file both as a file (Finder, Messages) and as GIF data (browsers and
    /// editors that paste an image), so one copy works wherever it is pasted.
    static func copy(path: String) {
        let url = URL(fileURLWithPath: path)
        let gif = NSPasteboard.PasteboardType("com.compuserve.gif")
        let pb = NSPasteboard.general
        pb.declareTypes([.fileURL, gif], owner: nil)
        pb.setString(url.absoluteString, forType: .fileURL)
        if let data = try? Data(contentsOf: url) { pb.setData(data, forType: gif) }
    }
}
