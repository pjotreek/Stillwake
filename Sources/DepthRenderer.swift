import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore
import simd

struct DepthTuning {
    var viewingDistance = 6.0
    var recession = 1.0
    var blurEvenness = 0.0
    var dimReach = 0.5
    var maxBlurRadius = 135.0
    var maxDim = 1.0
    var blurSpan = 60.0
    var blurCurve = 1.6
    var dimCurve = 0.7
    var dimHingeFloor = 0.2
}

struct DepthGeometry {
    var maxSeparationDegrees = 88.0

    func corners(startAngle: Double, currentAngle: Double, tuning: DepthTuning, screenSize: CGSize) -> [CGPoint] {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        let start = startAngle * .pi / 180
        let current = currentAngle * .pi / 180
        let travel = max(startAngle - currentAngle, 0)
        let separation = min(tuning.recession * travel, maxSeparationDegrees) * .pi / 180

        let reach = height * tuning.viewingDistance + height / 2 * cos(start)
        let rise = height / 2 * sin(start)
        let along = reach * cos(current) + rise * sin(current)
        let depth = max(reach * sin(current) - rise * cos(current), height / 10)

        let half = width / 2
        func project(_ x: Double, _ y: Double) -> CGPoint {
            let scale = depth / (depth + y * sin(separation))
            return CGPoint(x: half + (x - half) * scale, y: along + (y * cos(separation) - along) * scale)
        }
        return [project(0, 0), project(width, 0), project(width, height), project(0, height)]
    }
}

struct CriticallyDampedSpring {
    var value: Double
    var velocity = 0.0
    var frequency = 16.0

    mutating func advance(to target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}

enum Homography {
    static func matrix(width: Double, height: Double, to corners: [SIMD2<Double>]) -> simd_double3x3 {
        let (x0, y0) = (corners[0].x, corners[0].y)
        let (x1, y1) = (corners[1].x, corners[1].y)
        let (x2, y2) = (corners[2].x, corners[2].y)
        let (x3, y3) = (corners[3].x, corners[3].y)

        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var g = 0.0
        var h = 0.0
        if abs(dx3) > 1e-9 || abs(dy3) > 1e-9 {
            let determinant = dx1 * dy2 - dx2 * dy1
            if abs(determinant) > 1e-12 {
                g = (dx3 * dy2 - dx2 * dy3) / determinant
                h = (dx1 * dy3 - dx3 * dy1) / determinant
            }
        }
        let a = x1 - x0 + g * x1
        let b = x3 - x0 + h * x3
        let d = y1 - y0 + g * y1
        let e = y3 - y0 + h * y3

        return simd_double3x3(columns: (
            SIMD3(a / width, d / width, g / width),
            SIMD3(b / height, e / height, h / height),
            SIMD3(x0, y0, 1)
        ))
    }
}

final class DepthRenderer {
    static let padding: CGFloat = 120

    struct Picture {
        let texture: MTLTexture
        let colorSpace: CGColorSpace
        let paddedSize: CGSize
        let maxLevel: Float
        let pixelScale: CGFloat
        let screenSize: CGSize
    }

    private struct Uniforms {
        var column0: SIMD4<Float>
        var column1: SIMD4<Float>
        var column2: SIMD4<Float>
        var screenAndOrigin: SIMD4<Float>
        var paddedAndBlur: SIMD4<Float>
        var shape: SIMD4<Float>
        var light: SIMD4<Float>
    }

    private(set) var layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var picture: Picture?

    var isReady: Bool { picture != nil }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: DepthShaders.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "depthVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "depthFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
    }

    func makeLayer() -> CAMetalLayer {
        let fresh = CAMetalLayer()
        fresh.device = device
        fresh.pixelFormat = .bgra8Unorm_srgb
        fresh.framebufferOnly = true
        fresh.isOpaque = false
        fresh.displaySyncEnabled = false
        fresh.needsDisplayOnBoundsChange = true
        layer = fresh
        return fresh
    }

    func makePicture(image: CGImage, screenSize: CGSize, pixelScale: CGFloat) -> Picture? {
        let padding = Self.padding
        let paddedSize = CGSize(width: screenSize.width + 2 * padding, height: screenSize.height + 2 * padding)
        let width = Int((paddedSize.width * pixelScale).rounded())
        let height = Int((paddedSize.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return nil }
        let byteCount = width * height * 4
        guard let staging = device.makeBuffer(length: byteCount, options: .storageModeShared) else { return nil }

        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: staging.contents(),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let inset = padding * pixelScale
        context.draw(image, in: CGRect(x: inset, y: inset, width: CGFloat(width) - 2 * inset, height: CGFloat(height) - 2 * inset))

        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard var texture = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: width * 4,
            sourceBytesPerImage: byteCount,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
            .encode(commandBuffer: commands, inPlaceTexture: &texture, fallbackCopyAllocator: nil)
        commands.commit()
        commands.waitUntilCompleted()

        return Picture(
            texture: texture,
            colorSpace: colorSpace,
            paddedSize: paddedSize,
            maxLevel: Float(levels - 1),
            pixelScale: pixelScale,
            screenSize: screenSize
        )
    }

    func adopt(_ picture: Picture) {
        self.picture = picture
        layer.colorspace = picture.colorSpace
        layer.drawableSize = CGSize(
            width: picture.screenSize.width * picture.pixelScale,
            height: picture.screenSize.height * picture.pixelScale
        )
    }

    func release() {
        picture = nil
    }

    func render(corners: [CGPoint], progress: Double, tuning: DepthTuning) {
        guard let picture, let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let clamped = min(max(progress, 0), 1)
        let blurStrength = pow(clamped, tuning.blurCurve)
        let dimStrength = pow(clamped, tuning.dimCurve)
        let size = picture.screenSize

        let inverse = Homography.matrix(
            width: Double(size.width),
            height: Double(size.height),
            to: corners.map { SIMD2(Double($0.x), Double($0.y)) }
        ).inverse
        func column(_ index: Int) -> SIMD4<Float> {
            SIMD4(Float(inverse[index].x), Float(inverse[index].y), Float(inverse[index].z), 0)
        }
        var uniforms = Uniforms(
            column0: column(0),
            column1: column(1),
            column2: column(2),
            screenAndOrigin: SIMD4(Float(size.width), Float(size.height), Float(-Self.padding), Float(-Self.padding)),
            paddedAndBlur: SIMD4(
                Float(picture.paddedSize.width),
                Float(picture.paddedSize.height),
                Float(tuning.maxBlurRadius * Double(picture.pixelScale)),
                Float(blurStrength)
            ),
            shape: SIMD4(Float(tuning.blurEvenness), Float(tuning.maxDim), Float(picture.pixelScale), picture.maxLevel),
            light: SIMD4(Float(tuning.dimHingeFloor), Float(dimStrength), Float(tuning.dimReach), 0)
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(picture.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

enum DepthShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 column0;
        float4 column1;
        float4 column2;
        float4 screenAndOrigin;
        float4 paddedAndBlur;
        float4 shape;
        float4 light;
    };

    vertex float4 depthVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
    }

    fragment float4 depthFragment(float4 position [[position]],
                                  constant Uniforms &uniforms [[buffer(0)]],
                                  texture2d<float> picture [[texture(0)]]) {
        constexpr sampler linearSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

        float2 screenSize = uniforms.screenAndOrigin.xy;
        float2 paddedOrigin = uniforms.screenAndOrigin.zw;
        float2 paddedSize = uniforms.paddedAndBlur.xy;
        float maxRadius = uniforms.paddedAndBlur.z;
        float strength = uniforms.paddedAndBlur.w;
        float blurFloor = uniforms.shape.x;
        float maxDim = uniforms.shape.y;
        float pixelScale = uniforms.shape.z;
        float maxLevel = uniforms.shape.w;
        float dimFloor = uniforms.light.x;
        float dimStrength = uniforms.light.y;
        float dimReach = uniforms.light.z;

        float2 screenPoint = float2(position.x / pixelScale, screenSize.y - position.y / pixelScale);
        float3x3 screenToPicture = float3x3(uniforms.column0.xyz, uniforms.column1.xyz, uniforms.column2.xyz);
        float3 mapped = screenToPicture * float3(screenPoint, 1.0);
        if (abs(mapped.z) < 1e-6) { return float4(0.0, 0.0, 0.0, 1.0); }
        float2 picturePoint = mapped.xy / mapped.z;

        float2 unit = (picturePoint - paddedOrigin) / paddedSize;
        if (unit.x < 0.0 || unit.x > 1.0 || unit.y < 0.0 || unit.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        float2 texCoord = float2(unit.x, 1.0 - unit.y);

        float height = clamp(picturePoint.y / screenSize.y, 0.0, 1.0);
        float blur = strength * (blurFloor + (1.0 - blurFloor) * height);
        float mipLevel = clamp(log2(max(blur * maxRadius, 1.0)), 0.0, maxLevel);

        float4 colour = picture.sample(linearSampler, texCoord, level(mipLevel));
        float spread = smoothstep(0.0, max(dimReach, 0.02), height);
        float fade = dimStrength * (dimFloor + (1.0 - dimFloor) * spread);
        colour.rgb *= pow(1.0 - maxDim * fade, 2.2);
        return float4(colour.rgb, 1.0);
    }
    """
}
