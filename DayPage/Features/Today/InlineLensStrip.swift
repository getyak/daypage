import SwiftUI
import Photos
import DayPageServices

// MARK: - InlineLensStrip (US-016)
//
// A horizontal strip of up to 4 thumbnails from the last 24 hours,
// displayed below the TextField inside the composing card. Tapping a
// thumbnail directly appends it to pendingAttachments without opening
// a sheet.
//
// Permission flow:
//  • First expansion of the Composer → request PHPhotoLibrary authorization.
//  • If denied/restricted → strip is hidden; @AppStorage flag prevents
//    future prompts.
//  • No photos in the last 24 h → strip is hidden (no empty state).

struct InlineLensStrip: View {

    // Called with the PHAsset to attach when a thumbnail is tapped.
    var onSelectAsset: (PHAsset) -> Void

    // MARK: Private state

    @AppStorage("composer.photoPermissionAsked") private var permissionAsked: Bool = false
    @State private var authStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var recentAssets: [PHAsset] = []
    @State private var thumbnails: [String: UIImage] = [:]   // keyed by PHAsset.localIdentifier

    private let imageManager = PHCachingImageManager()
    private static let thumbSize = CGSize(width: 168, height: 168)
    private static let thumbOptions: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.isNetworkAccessAllowed = false
        o.isSynchronous = false
        return o
    }()

    var body: some View {
        Group {
            if shouldShow {
                stripContent
            }
        }
        .onAppear(perform: handleOnAppear)
        .onChange(of: authStatus) { _ in
            if authStatus == .authorized || authStatus == .limited {
                loadRecentAssets()
            }
        }
    }

    // MARK: - Visibility gate

    private var shouldShow: Bool {
        guard authStatus == .authorized || authStatus == .limited else { return false }
        return !recentAssets.isEmpty
    }

    // MARK: - Strip content

    private var stripContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentAssets, id: \.localIdentifier) { asset in
                    thumbnailButton(asset)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func thumbnailButton(_ asset: PHAsset) -> some View {
        Button {
            onSelectAsset(asset)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .fill(DSColor.glassLo)
                    .frame(width: 56, height: 56)

                if let img = thumbnails[asset.localIdentifier] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                } else {
                    ProgressView()
                        .frame(width: 56, height: 56)
                        .onAppear { fetchThumbnail(for: asset) }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("附加照片")
    }

    // MARK: - Permission & load

    private func handleOnAppear() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authStatus = current

        switch current {
        case .authorized, .limited:
            loadRecentAssets()
        case .notDetermined:
            if !permissionAsked {
                permissionAsked = true
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    DispatchQueue.main.async {
                        authStatus = status
                    }
                }
            }
        default:
            // denied / restricted — stay hidden, permissionAsked flag prevents re-prompt
            permissionAsked = true
        }
    }

    private func loadRecentAssets() {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "creationDate > %@ AND mediaType == %d",
                                             cutoff as NSDate,
                                             PHAssetMediaType.image.rawValue)
        fetchOptions.fetchLimit = 4

        let result = PHAsset.fetchAssets(with: fetchOptions)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        recentAssets = assets

        // Pre-warm the cache for all fetched assets
        imageManager.startCachingImages(for: assets,
                                        targetSize: Self.thumbSize,
                                        contentMode: .aspectFill,
                                        options: Self.thumbOptions)
        for asset in assets { fetchThumbnail(for: asset) }
    }

    private func fetchThumbnail(for asset: PHAsset) {
        guard thumbnails[asset.localIdentifier] == nil else { return }
        imageManager.requestImage(for: asset,
                                  targetSize: Self.thumbSize,
                                  contentMode: .aspectFill,
                                  options: Self.thumbOptions) { image, _ in
            guard let image else { return }
            DispatchQueue.main.async {
                thumbnails[asset.localIdentifier] = image
            }
        }
    }
}
