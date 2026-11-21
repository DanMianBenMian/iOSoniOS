import SwiftUI

/// Renders the guest framebuffer as a live image.
///
/// The pixels come from `ry_engine_fb_pixels()`, a host RGBA8888 buffer that the
/// guest display driver writes into through the MMU framebuffer window. Right
/// now it holds a test pattern so the readback -> render path is verifiable
/// before any kernel runs. No Metal needed: a CGImage backed by the copied
/// bytes is enough for a 1024x768 screen at interactive refresh.
struct GuestScreenView: View {
    @State private var image: UIImage?
    @State private var isTest = true
    private let timer = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.VM.canvas.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if isTest {
                VStack(spacing: 8) {
                    Image(systemName: "display")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.VM.textDim)
                    Text("等待客机画面")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.VM.textDim)
                    Text("显示测试图案 · 内核启动后自动切换")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.VM.textFaint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        guard let base = ry_engine_fb_pixels() else { return }
        let w = Int(ry_engine_fb_width())
        let h = Int(ry_engine_fb_height())
        let count = w * h * 4

        // Copy C bytes into a CFData so the CGImage owns its storage.
        guard let data = CFDataCreate(nil, base, count),
              let provider = CGDataProvider(data: data) else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let imageInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(width: w, height: h,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4,
                               space: colorSpace, bitmapInfo: imageInfo,
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return }
        self.image = UIImage(cgImage: cg)
        self.isTest = ry_engine_fb_is_test() != 0
    }
}
