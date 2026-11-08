import SwiftUI

/// Right-hand inspector for the selected image.
public struct InspectorView: View {
    @EnvironmentObject private var store: AppStore

    public var body: some View {
        if let item = store.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview(item)
                    header(item)
                    sizeSection(item)
                    fileSection(item)
                    ColorTypeBadge(item: item)
                    actions(item)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(item.id)
        } else {
            ContentUnavailableView("未选择图片", systemImage: "cursorarrow.click.2",
                                   description: Text("点选任意缩略图查看尺寸、宽高比等详细信息。"))
        }
    }

    private func preview(_ item: ImageItem) -> some View {
        // Keep the preview box at the image's real aspect ratio (capped).
        let ratio = item.aspectRatio > 0 ? item.aspectRatio : 1
        return Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxHeight: 260)
            .overlay {
                ThumbnailCell(item: item, size: 240, showsInfo: false, isSelected: false)
            }
            .padding(2)
    }

    private func header(_ item: ImageItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.fileName)
                .font(.headline)
                .textSelection(.enabled)
            Text(item.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    private func sizeSection(_ item: ImageItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("尺寸")
            InfoRow(label: "像素", value: item.dimensionDescription, mono: true)
            InfoRow(label: "宽高比", value: String(format: "%.3f : 1", item.aspectRatio), mono: true)
            InfoRow(label: "分类", value: item.aspectCategory.rawValue)
            InfoRow(label: "宽度档位", value: item.widthBucket.label)
            InfoRow(label: "面积档位", value: item.areaBucket.label)
            InfoRow(label: "总像素", value: NumberFormatter.pixels.string(from: NSNumber(value: item.pixelCount)) ?? "\(item.pixelCount)", mono: true)
        }
    }

    private func fileSection(_ item: ImageItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("文件")
            InfoRow(label: "大小", value: item.fileSizeDescription)
            InfoRow(label: "创建时间", value: item.createdDescription)
            InfoRow(label: "修改时间", value: item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            InfoRow(label: "目录", value: URL(fileURLWithPath: item.rootPath).lastPathComponent)
            InfoRow(label: "位深", value: "\(item.bitDepth) bit")
        }
    }

    private func actions(_ item: ImageItem) -> some View {
        VStack(spacing: 8) {
            Button {
                store.open(item)
            } label: {
                Label("打开", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            HStack {
                Button {
                    store.reveal(item)
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
                Button {
                    store.copyPath(item)
                } label: {
                    Label("路径", systemImage: "doc.on.doc")
                }
                Button {
                    store.copyDimensions(item)
                } label: {
                    Label("尺寸", systemImage: "ruler")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var mono = false

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(mono ? .body.monospacedDigit() : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

private struct ColorTypeBadge: View {
    let item: ImageItem

    private var description: String {
        switch item.colorType {
        case 0: "灰度"
        case 2: "RGB"
        case 3: "调色板"
        case 4: "灰度 + Alpha"
        case 6: "RGBA（含透明通道）"
        default: "未知 (\(item.colorType))"
        }
    }

    public var body: some View {
        Label(description, systemImage: item.hasAlpha ? "circle.lefthalf.filled" : "circle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

private extension NumberFormatter {
    static let pixels: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}
