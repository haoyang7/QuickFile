import Foundation

/// Template identity preserves original UTF-8, including canonical Unicode variants.
/// Contiguous storage is compared in bulk; neither operation retains a body copy.
public enum TemplateByteOperations {
    public static func areEqual<Left: Collection, Right: Collection>(_ left: Left, _ right: Right) -> Bool
    where Left.Element == UInt8, Right.Element == UInt8 {
        let contiguousResult: Bool?? = left.withContiguousStorageIfAvailable { leftBytes in
            right.withContiguousStorageIfAvailable { rightBytes in
                guard leftBytes.count == rightBytes.count else { return false }
                guard !leftBytes.isEmpty else { return true }
                // Draft baselines and unchanged snapshots often share storage.
                // Equal ranges at the same address need no full-body read.
                if leftBytes.baseAddress == rightBytes.baseAddress { return true }
                return memcmp(leftBytes.baseAddress!, rightBytes.baseAddress!, leftBytes.count) == 0
            }
        }
        if let availableResult = contiguousResult, let equal = availableResult { return equal }
        return left.elementsEqual(right)
    }

    private static let hashChunkBytes = 4_096

    public static func hash<Bytes: Collection>(_ bytes: Bytes, into hasher: inout Hasher)
    where Bytes.Element == UInt8 {
        let contiguous: Void? = bytes.withContiguousStorageIfAvailable { storage in
            hasher.combine(storage.count)
            let raw = UnsafeRawBufferPointer(storage)
            var offset = 0
            while offset < raw.count {
                let end = offset + min(hashChunkBytes, raw.count - offset)
                hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw[offset..<end]))
                offset = end
            }
        }
        if contiguous != nil { return }

        // Use identical field lengths and chunk boundaries on both storage paths.
        // Bridged/noncontiguous strings need only one bounded scratch buffer.
        let count = bytes.count
        hasher.combine(count)
        guard count > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: min(count, hashChunkBytes))
        var used = 0
        for byte in bytes {
            buffer[used] = byte
            used += 1
            if used == buffer.count {
                buffer.withUnsafeBytes { hasher.combine(bytes: $0) }
                used = 0
            }
        }
        if used > 0 {
            buffer.withUnsafeBytes {
                hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: $0[..<used]))
            }
        }
    }
}
