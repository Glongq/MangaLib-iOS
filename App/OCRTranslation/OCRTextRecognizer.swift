import UIKit
import Vision

/// Runs Vision OCR and groups observations into horizontal paragraphs or
/// traditional vertical CJK text regions. Long pages are recognized in
/// overlapping tiles so small lettering keeps enough pixels for Vision.
enum OCRTextRecognizer {
    static func recognize(image: UIImage, sourceLanguage: String) async -> [RecognizedTextBlock] {
        guard let cgImage = image.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let lines = recognizeLines(cgImage: cgImage, sourceLanguage: sourceLanguage)
            return blocks(from: lines)
        }.value
    }

    /// Shared post-processing for alternative OCR engines that return text
    /// plus normalized boxes but do not understand manga reading order.
    static func blocks(from lines: [RecognizedTextLine]) -> [RecognizedTextBlock] {
        cluster(lines: lines)
    }

    /// Uses even a partial Apple OCR pass only to select the matching
    /// on-device ML Kit script model when the user chose automatic input.
    static func inferredLanguage(from blocks: [RecognizedTextBlock]) -> String {
        let scalars = blocks.flatMap(\.text.unicodeScalars)
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return "ko" }
        if scalars.contains(where: {
            (0x3400...0x4DBF).contains($0.value) ||
                (0x4E00...0x9FFF).contains($0.value) ||
                (0xF900...0xFAFF).contains($0.value)
        }) { return "zh" }
        if scalars.contains(where: { CharacterSet.letters.contains($0) }) { return "en" }
        return "ja"
    }

    private static func languages(for sourceLanguage: String) -> [String] {
        switch sourceLanguage {
        case "ja": return ["ja-JP"]
        case "ko": return ["ko-KR"]
        case "zh": return ["zh-Hans", "zh-Hant"]
        case "en": return ["en-US"]
        default: return ["ja-JP", "zh-Hans", "zh-Hant", "ko-KR", "en-US"]
        }
    }

    private static func recognizeLines(cgImage: CGImage, sourceLanguage: String) -> [RecognizedTextLine] {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return [] }

        // A full-page pass makes lettering on long pages physically tiny
        // inside Vision's input. Horizontal overlapping strips preserve the
        // original pixel density and prevent text near a strip boundary
        // from disappearing.
        guard height > width * 1.55 else {
            return performRequest(
                cgImage: cgImage,
                sourceLanguage: sourceLanguage,
                fullImageHeight: height,
                cropMinY: 0,
                cropHeight: height
            )
        }

        var tileHeight = min(height, max(width * 1.35, 1_200))
        let maximumTileCount: CGFloat = 16
        if height / (tileHeight * 0.82) > maximumTileCount {
            tileHeight = height / (maximumTileCount * 0.82)
        }
        let stride = tileHeight * 0.82
        var lines: [RecognizedTextLine] = []
        var y: CGFloat = 0

        while y < height {
            if Task.isCancelled { return [] }
            let cropY = min(y, max(0, height - tileHeight))
            let cropRect = CGRect(x: 0, y: cropY, width: width, height: min(tileHeight, height - cropY)).integral
            guard let tile = cgImage.cropping(to: cropRect) else { break }
            lines.append(contentsOf: performRequest(
                cgImage: tile,
                sourceLanguage: sourceLanguage,
                fullImageHeight: height,
                cropMinY: cropRect.minY,
                cropHeight: cropRect.height
            ))
            if cropRect.maxY >= height { break }
            y += stride
        }

        return deduplicated(lines)
    }

    private static func performRequest(
        cgImage: CGImage,
        sourceLanguage: String,
        fullImageHeight: CGFloat,
        cropMinY: CGFloat,
        cropHeight: CGFloat
    ) -> [RecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        request.recognitionLanguages = languages(for: sourceLanguage)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.2 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let box = observation.boundingBox
            let localTop = 1 - box.origin.y - box.height
            let rect = CGRect(
                x: box.origin.x,
                y: (cropMinY + localTop * cropHeight) / fullImageHeight,
                width: box.width,
                height: box.height * cropHeight / fullImageHeight
            )
            return RecognizedTextLine(text: text, rect: rect, confidence: candidate.confidence)
        }
    }

    private static func deduplicated(_ lines: [RecognizedTextLine]) -> [RecognizedTextLine] {
        var result: [RecognizedTextLine] = []
        for line in lines.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = result.contains { existing in
                intersectionOverUnion(line.rect, existing.rect) >= 0.62
            }
            if !duplicate { result.append(line) }
        }
        return result
    }

    private struct VerticalColumn {
        var lines: [RecognizedTextLine]
        var rect: CGRect { lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) } }
        var text: String {
            lines.sorted(by: verticalLineOrder).map { compactCJKText($0.text) }.joined()
        }
    }

    private static func cluster(lines: [RecognizedTextLine]) -> [RecognizedTextBlock] {
        guard !lines.isEmpty else { return [] }
        let verticalResult = verticalColumns(from: lines)
        let verticalBlocks = groupVerticalColumns(verticalResult.columns)
        let horizontalLines = lines.enumerated().compactMap { index, line in
            verticalResult.consumed.contains(index) ? nil : line
        }
        return verticalBlocks + clusterHorizontal(lines: horizontalLines)
    }

    private static func verticalColumns(
        from lines: [RecognizedTextLine]
    ) -> (columns: [VerticalColumn], consumed: Set<Int>) {
        let candidates = lines.enumerated().filter { _, line in
            isCJKDominant(line.text) && line.rect.width <= line.rect.height * 1.45
        }
        let sorted = candidates.sorted {
            if abs($0.element.rect.midX - $1.element.rect.midX) > 0.004 {
                return $0.element.rect.midX > $1.element.rect.midX
            }
            return $0.element.rect.minY < $1.element.rect.minY
        }

        var indexedColumns: [[(offset: Int, element: RecognizedTextLine)]] = []
        for candidate in sorted {
            if let index = indexedColumns.indices.first(where: { columnIndex in
                let column = indexedColumns[columnIndex]
                let columnRect = column.dropFirst().reduce(column[0].element.rect) { $0.union($1.element.rect) }
                let centerTolerance = max(candidate.element.rect.width, columnRect.width) * 0.65
                guard abs(candidate.element.rect.midX - columnRect.midX) <= centerTolerance else { return false }

                let verticalGap = max(
                    0,
                    max(candidate.element.rect.minY, columnRect.minY) - min(candidate.element.rect.maxY, columnRect.maxY)
                )
                let averageHeight = column.map { $0.element.rect.height }.reduce(0, +) / CGFloat(column.count)
                let typicalHeight = max(candidate.element.rect.height, averageHeight)
                return verticalGap <= typicalHeight * 1.25
            }) {
                indexedColumns[index].append(candidate)
            } else {
                indexedColumns.append([candidate])
            }
        }

        var columns: [VerticalColumn] = []
        var consumed = Set<Int>()
        for indexedColumn in indexedColumns {
            let columnLines = indexedColumn.map(\.element).sorted(by: verticalLineOrder)
            let rect = columnLines.dropFirst().reduce(columnLines[0].rect) { $0.union($1.rect) }
            let characterCount = columnLines.reduce(0) { $0 + compactCJKText($1.text).count }
            let isVertical = (columnLines.count >= 2 && rect.height >= rect.width * 1.45)
                || (characterCount >= 2 && rect.height >= rect.width * 1.7)
            guard isVertical else { continue }
            columns.append(VerticalColumn(lines: columnLines))
            indexedColumn.forEach { consumed.insert($0.offset) }
        }
        return (columns, consumed)
    }

    private static func groupVerticalColumns(_ columns: [VerticalColumn]) -> [RecognizedTextBlock] {
        let sorted = columns.sorted { $0.rect.midX > $1.rect.midX }
        var groups: [[VerticalColumn]] = []

        for column in sorted {
            if let index = groups.indices.first(where: { groupIndex in
                let groupRect = groups[groupIndex].dropFirst().reduce(groups[groupIndex][0].rect) { $0.union($1.rect) }
                let overlap = max(0, min(column.rect.maxY, groupRect.maxY) - max(column.rect.minY, groupRect.minY))
                let overlapFraction = overlap / max(0.0001, min(column.rect.height, groupRect.height))
                let horizontalGap = max(0, groupRect.minX - column.rect.maxX)
                let averageWidth = groups[groupIndex].map { $0.rect.width }.reduce(0, +) / CGFloat(groups[groupIndex].count)
                let widthReference = max(column.rect.width, averageWidth)
                return overlapFraction >= 0.42 && horizontalGap <= max(0.025, widthReference * 1.5)
            }) {
                groups[index].append(column)
            } else {
                groups.append([column])
            }
        }

        return groups.map { group in
            let orderedColumns = group.sorted { $0.rect.midX > $1.rect.midX }
            let rect = orderedColumns.dropFirst().reduce(orderedColumns[0].rect) { $0.union($1.rect) }
            let allLines = orderedColumns.flatMap(\.lines)
            let text = orderedColumns.map(\.text).joined()
            return RecognizedTextBlock(
                id: UUID(),
                rect: rect,
                placementRect: verticalPlacementRect(for: rect),
                text: text,
                lines: allLines
            )
        }
    }

    private static func clusterHorizontal(lines: [RecognizedTextLine]) -> [RecognizedTextBlock] {
        let sorted = lines.sorted {
            $0.rect.midY == $1.rect.midY ? $0.rect.minX < $1.rect.minX : $0.rect.midY < $1.rect.midY
        }
        var clusters: [[RecognizedTextLine]] = []

        for line in sorted {
            if let lastIndex = clusters.indices.last(where: { index in
                guard let last = clusters[index].last else { return false }
                let overlap = max(0, min(line.rect.maxX, last.rect.maxX) - max(line.rect.minX, last.rect.minX))
                let overlapFraction = overlap / max(0.0001, min(line.rect.width, last.rect.width))
                let verticalGap = line.rect.minY - last.rect.maxY
                let averageHeight = (line.rect.height + last.rect.height) / 2
                return overlapFraction >= 0.4 && verticalGap <= 0.45 * averageHeight
            }) {
                clusters[lastIndex].append(line)
            } else {
                clusters.append([line])
            }
        }

        return clusters.map { clusterLines in
            let rect = clusterLines.dropFirst().reduce(clusterLines[0].rect) { $0.union($1.rect) }
            return RecognizedTextBlock(
                id: UUID(),
                rect: rect,
                text: clusterLines.map(\.text).joined(separator: " "),
                lines: clusterLines
            )
        }
    }

    private static func verticalPlacementRect(for source: CGRect) -> CGRect {
        let targetWidth = min(0.38, max(source.width * 2.2, source.height * 0.78))
        let x: CGFloat
        if source.midX < 0.3 {
            x = max(0.01, source.minX - source.width * 0.15)
        } else if source.midX > 0.7 {
            x = min(0.99 - targetWidth, source.maxX - targetWidth + source.width * 0.15)
        } else {
            x = min(max(0.01, source.midX - targetWidth / 2), 0.99 - targetWidth)
        }
        let expandedHeight = min(0.98, max(source.height, source.height * 1.05))
        let y = min(max(0.01, source.midY - expandedHeight / 2), 0.99 - expandedHeight)
        return CGRect(x: x, y: y, width: targetWidth, height: expandedHeight)
    }

    private static func verticalLineOrder(_ lhs: RecognizedTextLine, _ rhs: RecognizedTextLine) -> Bool {
        lhs.rect.minY == rhs.rect.minY ? lhs.rect.midX > rhs.rect.midX : lhs.rect.minY < rhs.rect.minY
    }

    private static func compactCJKText(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    private static func isCJKDominant(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let cjk = letters.filter { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
        return Double(cjk.count) / Double(letters.count) >= 0.6
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}
