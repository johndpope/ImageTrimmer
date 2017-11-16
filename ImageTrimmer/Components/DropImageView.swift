
import Foundation
import Cocoa
import EasyImagy
import RxSwift

class DropImageView : NSView {
    
    private let disposeBag = DisposeBag()
    
    private(set) var easyImage: Image<RGBA>?
    
    var image: NSImage?
    
    private var overlay: CALayer!
    private var imageLayer: CALayer!
    private var sublayer: CALayer!
    
    private let _onImageLoaded = PublishSubject<String>()
    var onImageLoaded: Observable<String> {
        return _onImageLoaded
    }
    
    private let onResize = PublishSubject<Void>()
    
    private let _onClickPixel = PublishSubject<(Int, Int)>()
    var onClickPixel: Observable<(Int, Int)> {
        return _onClickPixel
    }
    
    let trimRect = ReplaySubject<(Int, Int, Int, Int)>.create(bufferSize: 1)
    
    // make origin left-top
    override var isFlipped: Bool {
        return true
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        
        register(forDraggedTypes: [NSFilenamesPboardType])
        
        let zoomRecog = NSMagnificationGestureRecognizer(target: self, action: #selector(onZoom))
        addGestureRecognizer(zoomRecog)
        
        let panRecog = NSPanGestureRecognizer(target: self, action: #selector(onPan))
        addGestureRecognizer(panRecog)
        
        let clickRecog = NSClickGestureRecognizer(target: self, action: #selector(onClick))
        addGestureRecognizer(clickRecog)
        
        overlay = CALayer()
        overlay.borderColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        overlay.zPosition = 0.001
        overlay.bounds = CGRect(x: 0, y: 0, width: 0, height: 0)
        self.layer!.addSublayer(overlay)
        
        imageLayer = CALayer()
        imageLayer.contentsGravity = kCAGravityResizeAspect
        imageLayer.anchorPoint = CGPoint.zero
        self.layer!.addSublayer(imageLayer)
        
        sublayer = CALayer()
        self.layer!.addSublayer(sublayer)
        
        weak var welf = self
        
        Observable.of(trimRect,
                      onImageLoaded
                        .do(onNext: { _ in welf?.layer?.sublayerTransform = CATransform3DIdentity })
                        .withLatestFrom(trimRect),
                      onResize.withLatestFrom(trimRect))
            .merge()
            .subscribe(onNext: { x, y, width, height in
                welf?.drawRect(x: x, y: y, width: width, height: height)
            })
            .addDisposableTo(disposeBag)
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return NSDragOperation.generic
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        
        let files = sender.draggingPasteboard().propertyList(forType: NSFilenamesPboardType) as! [String]
        
        guard let file = files.first else {
            return false
        }
        
        guard let image = NSImage(contentsOfFile: file) else {
            showAlert("invalid image file.")
            return false
        }
        
        // ignore dpi
        guard let rep = image.bitmapRep else {
            showAlert("failed to load image.")
            return false
        }
        let sizeInPixels = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        image.size = sizeInPixels
        rep.size = sizeInPixels
        
        self.image = image
        
        imageLayer.contents = image
        imageLayer.bounds = self.bounds
        
        self.easyImage = Image<RGBA>(nsImage: image)
        
        let (scale, _) = getScaleAndImageOrigin(imageSize: image.size)
        overlay.borderWidth = scale * 0.3
        
        _onImageLoaded.onNext(file)
        
        return true
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = self.bounds
        onResize.onNext(())
        CATransaction.commit()
        
    }
    
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        // Intercept super.concludeDragOperation
    }
    
    override func scrollWheel(with event: NSEvent) {
        self.layer!.sublayerTransform *= CATransform3DMakeTranslation(event.deltaX, event.deltaY, 0)
    }
    
    private func selectPoint(location: CGPoint) {
        
        guard let imageSize = self.image?.size else {
            return
        }
        
        let inSublayer = self.layer!.convert(location, to: self.sublayer)
        
        let (scale, imageOrigin) = self.getScaleAndImageOrigin(imageSize: imageSize)
        
        let pt = (inSublayer - imageOrigin)/scale
        _onClickPixel.onNext((Int(pt.x), Int(pt.y)))
    }
    
    func onZoom(_ recognizer: NSMagnificationGestureRecognizer) {
        let magnification = recognizer.magnification
        let scaleFactor = (magnification >= 0.0) ? (1.0 + magnification) : 1.0 / (1.0 - magnification)
        
        let location = recognizer.location(in: self)
        let move = CGPoint(x: location.x * (scaleFactor-1), y: location.y * (scaleFactor-1))
        
        self.layer!.sublayerTransform *= CATransform3DMakeScale(scaleFactor, scaleFactor, 1)
        self.layer!.sublayerTransform *= CATransform3DMakeTranslation(-move.x, -move.y, 0)
        
        recognizer.magnification = 0
    }

    
    func onPan(_ recognizer: NSPanGestureRecognizer) {
        
        switch recognizer.state {
        case .began, .changed:
            let location = recognizer.location(in: self)
            selectPoint(location: location)
        default:
            break
        }
    }
    
    func onClick(_ recognizer: NSClickGestureRecognizer) {
        let location = recognizer.location(in: self)
        
        selectPoint(location: location)
    }
    
    private func drawRect(x: Int, y: Int, width: Int, height: Int) {
        
        guard let imageSize = self.image?.size else {
//            Swift.print("image is nil")
            return
        }
        
        guard width>0 && height>0 else {
            overlay.isHidden = true
            return
        }
        overlay.isHidden = false
        
        let (scale, imageOrigin) = self.getScaleAndImageOrigin(imageSize: imageSize)
        
        let inSublayer = CGPoint(x: CGFloat(x), y: CGFloat(y)) * scale + imageOrigin
        
        let w = scale*CGFloat(width)
        let h = scale*CGFloat(height)
        overlay.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.position = inSublayer + CGPoint(x: w/2, y: h/2)
        CATransaction.commit()
    }
    
    private func getScaleAndImageOrigin(imageSize: CGSize) -> (CGFloat, CGPoint) {
        
        let imageAspectRatio = imageSize.width / imageSize.height
        let viewAspectRatio = self.bounds.width / self.bounds.height
        
        let imageOrigin: CGPoint
        let scale: CGFloat
        // Original Size
//        if imageSize.width <= self.bounds.width && imageSize.height <= self.bounds.height {
//            scale = 1
//            imageOrigin = CGPoint(x: (self.bounds.width - imageSize.width)/2,
//                                  y: (self.bounds.height - imageSize.height)/2)
//        } else
        if imageAspectRatio < viewAspectRatio {
            scale = self.bounds.height / imageSize.height
            imageOrigin = CGPoint(x: (self.bounds.width - imageSize.width*scale)/2, y: 0)
        } else {
            scale = self.bounds.width / imageSize.width
            imageOrigin = CGPoint(x: 0, y: (self.bounds.height - imageSize.height*scale)/2)
        }
        return (scale, imageOrigin)
    }
}
