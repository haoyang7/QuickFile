import Foundation

/// Display-only preview. Every Unicode/formatting operation after the UTF-8 read
/// works on a bounded copy, never on the original, potentially enormous body.
enum TemplateContentPreview {
    static let maximumInputBytes = 800
    static let maximumOutputBytes = 800
    static let maximumCharacters = 200

    static func summary(_ content: String) -> String {
        // A Character can itself contain megabytes of combining marks or ZWJs.
        // Do not ask the original String for even its first Character. The extra
        // byte detects truncation without counting/scanning the entire body.
        let bytes = Array(content.utf8.prefix(maximumInputBytes + 1))
        var wasTruncated = bytes.count > maximumInputBytes
        var byteEnd = min(bytes.count, maximumInputBytes)
        var decoded = String(bytes: bytes[..<byteEnd], encoding: .utf8)
        // The source is valid UTF-8; only the final scalar can be incomplete.
        // Backing up at most three bytes restores a scalar boundary.
        while decoded == nil && byteEnd > 0 {
            byteEnd -= 1
            decoded = String(bytes: bytes[..<byteEnd], encoding: .utf8)
        }
        var window = decoded ?? ""
        if wasTruncated && !window.isEmpty {
            // The last grapheme may continue beyond the byte window. Drop it
            // conservatively, rather than scanning the source to find its end.
            // In particular, one enormous first cluster yields just an ellipsis.
            window.removeLast()
        }

        var result = ""
        var outputBytes = 0
        var characters = 0
        for character in window {
            guard characters < maximumCharacters else {
                wasTruncated = true
                break
            }
            let piece = String(character).replacingOccurrences(of: "\n", with: " ↩︎ ")
            let pieceBytes = piece.utf8.count
            guard outputBytes + pieceBytes <= maximumOutputBytes else {
                wasTruncated = true
                break
            }
            result += piece
            outputBytes += pieceBytes
            characters += 1
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if wasTruncated {
            // Newline markers expand in UTF-8; the ellipsis is part of the same
            // output budget. Removing whole bounded-copy graphemes stays valid.
            let ellipsis = "…"
            outputBytes = result.utf8.count
            while outputBytes + ellipsis.utf8.count > maximumOutputBytes {
                outputBytes -= String(result.removeLast()).utf8.count
            }
            result += ellipsis
        }
        return result
    }
}
