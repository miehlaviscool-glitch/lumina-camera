import SwiftUI
import AVFoundation
import AVKit

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let overlay = CALayer()
    var onVolumeShutter: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        overlay.contentsGravity = .resizeAspectFill
        overlay.masksToBounds = true
        overlay.isHidden = true
        overlay.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(overlay)
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended { self?.onVolumeShutter?() }
            }
            addInteraction(interaction)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = bounds
        CATransaction.commit()
    }

    func setOverlay(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image = image {
            overlay.contents = image
            overlay.isHidden = false
        } else {
            overlay.isHidden = true
            overlay.contents = nil
        }
        CATransaction.commit()
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraManager

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = camera.session
        camera.previewLayer = v.previewLayer
        v.onVolumeShutter = { [weak camera] in camera?.shutterTapped() }
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.setOverlay(camera.previewImage)
        uiView.onVolumeShutter = { [weak camera] in camera?.shutterTapped() }
    }
}
