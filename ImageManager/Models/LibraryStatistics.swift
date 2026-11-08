import Foundation

/// Aggregations over a list of images, used by the sidebar.
public struct LibraryStatistics: Sendable {
    var totalCount = 0
    var totalBytes: Int64 = 0
    var aspectCounts: [AspectCategory: Int] = [:]
    var exactSizeGroups: [SizeGroup] = []
    var widthCounts: [WidthBucket: Int] = [:]
    var areaCounts: [AreaBucket: Int] = [:]
    var largest: ImageItem?
    var smallest: ImageItem?
    var duplicateNameCount = 0

    var averagePixelCount: Int {
        guard totalCount > 0 else { return 0 }
        return exactSizeGroups.reduce(into: 0) { $0 += $1.width * $1.height * $1.count } / totalCount
    }

    static func make(from items: [ImageItem]) -> LibraryStatistics {
        var stats = LibraryStatistics()
        stats.totalCount = items.count
        var sizeMap: [String: SizeGroup] = [:]
        var nameCounts: [String: Int] = [:]

        for item in items {
            stats.totalBytes += item.fileSize
            stats.aspectCounts[item.aspectCategory, default: 0] += 1
            stats.widthCounts[item.widthBucket, default: 0] += 1
            stats.areaCounts[item.areaBucket, default: 0] += 1
            nameCounts[item.fileName, default: 0] += 1

            if let g = sizeMap[item.dimensionKey] {
                sizeMap[item.dimensionKey] = SizeGroup(width: g.width, height: g.height,
                                                       count: g.count + 1, totalBytes: g.totalBytes + item.fileSize)
            } else {
                sizeMap[item.dimensionKey] = SizeGroup(width: item.pixelWidth, height: item.pixelHeight,
                                                       count: 1, totalBytes: item.fileSize)
            }

            if stats.largest == nil || item.pixelCount > stats.largest!.pixelCount { stats.largest = item }
            if stats.smallest == nil || item.pixelCount < stats.smallest!.pixelCount { stats.smallest = item }
        }

        stats.exactSizeGroups = sizeMap.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.width != $1.width { return $0.width > $1.width }
            return $0.height > $1.height
        }
        stats.duplicateNameCount = nameCounts.values.filter { $0 > 1 }.reduce(0, +)
        return stats
    }
}
