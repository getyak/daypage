import SwiftUI

// MARK: - HeroBannerView

/// Daily Page 顶部的全宽 16:7 横幅。
/// 将 `coverAssetPath` 相对于 Vault 沙盒解析，并在加载时显示骨架屏。
/// 当没有照片或文件解码失败时，回退为几何占位图。
struct HeroBannerView: View {
    let coverAssetPath: String?

    @State private var image: UIImage? = nil
    @State private var loadFailed: Bool = false
    @State private var showPreview: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = width * 7.0 / 16.0
            ZStack {
                DSColor.surfaceContainer

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { showPreview = true }
                        .accessibilityLabel("Daily hero image")
                        .accessibilityAddTraits(.isImage)
                } else if coverAssetPath == nil || loadFailed {
                    placeholder
                } else {
                    skeleton
                }
            }
            .frame(width: width, height: height)
        }
        .aspectRatio(16.0 / 7.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .task(id: coverAssetPath) { await load() }
        .fullScreenCover(isPresented: $showPreview) {
            HeroBannerPreview(image: image) { showPreview = false }
        }
    }

    // MARK: - Placeholder

    /// 当日无照片时使用的单色几何占位图。
    private var placeholder: some View {
        ZStack {
            DSColor.surfaceContainer

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    Rectangle()
                        .stroke(DSColor.onSurfaceVariant.opacity(0.35), lineWidth: 1)
                        .frame(width: w * 0.55, height: h * 0.6)
                        .offset(x: -w * 0.12, y: -h * 0.05)
                    Circle()
                        .stroke(DSColor.onSurfaceVariant.opacity(0.35), lineWidth: 1)
                        .frame(width: h * 0.5, height: h * 0.5)
                        .offset(x: w * 0.18, y: h * 0.08)
                }
                .frame(width: w, height: h)
            }

            VStack {
                Spacer()
                HStack {
                    Text("NO HERO IMAGE")
                        .monoLabelStyle(size: 10)
                        .kerning(2)
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DSColor.surfaceContainerHigh)
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    // MARK: - Skeleton

    /// 图片解码期间显示的中性无闪烁骨架屏。
    private var skeleton: some View {
        DSColor.surfaceContainerHigh
            .overlay(
                ProgressView()
                    .tint(DSColor.onSurfaceVariant)
            )
    }

    // MARK: - Loading

    private func load() async {
        image = nil
        loadFailed = false
        guard let relativePath = coverAssetPath, !relativePath.isEmpty else { return }

        let fileURL = VaultInitializer.vaultURL.appendingPathComponent(relativePath)
        let path = fileURL.path
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            UIImage(contentsOfFile: path)
        }.value

        if let loaded {
            self.image = loaded
        } else {
            self.loadFailed = true
        }
    }
}

// MARK: - HeroBannerPreview

/// 点击横幅时呈现的全屏捏合缩放预览。
private struct HeroBannerPreview: View {
    let image: UIImage?
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0
    @GestureState private var gestureScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * gestureScale)
                    .gesture(
                        MagnificationGesture()
                            .updating($gestureScale) { value, state, _ in state = value }
                            .onEnded { value in
                                scale = max(1.0, min(4.0, scale * value))
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1.0 ? 1.0 : 2.0
                        }
                    }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
        .onTapGesture { onDismiss() }
    }
}