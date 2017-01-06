/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information
    
    Abstract:
    The Renderer class. This is the reason for the sample. Here you'll find all the detail about how to setup and interact with Metal types to render content to the screen. This type conforms to MTKViewDelegate and performs the rendering in the appropriate call backs. It is created in the ViewController.viewDidLoad() method.
*/

import Metal
import simd
import MetalKit

struct Constants {
    var modelViewProjectionMatrix = matrix_identity_float4x4
    var normalMatrix = matrix_identity_float3x3
    var modelMatrix = matrix_identity_float4x4
}

struct PointLight {
    var worldPosition = float3(0.0, 0.0, 0.0)
    var radius = Float(1.0)
}

struct LightFragmentInput {
    var screenSize = float2(1, 1)
}

@objc
class Renderer : NSObject, MTKViewDelegate
{
    weak var view: MTKView!

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let renderPipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    let sampler: MTLSamplerState
    let texture: MTLTexture
    let mesh: Mesh

    var time = TimeInterval(0.0)
    var constants = Constants()

    var gBufferAlbedoTexture: MTLTexture
    var gBufferNormalTexture: MTLTexture
    var gBufferPositionTexture: MTLTexture
    var gBufferDepthTexture: MTLTexture
    let gBufferDepthStencilState: MTLDepthStencilState
    var gBufferRenderPassDescriptor: MTLRenderPassDescriptor
    let gBufferRenderPipeline: MTLRenderPipelineState

    let lightSphere: Mesh
    let lightNumber = 2
    var lightConstants = [Constants]()
    var lightProperties = [PointLight]()
    var lightFragmentInput = LightFragmentInput()
    
    let stencilPassDepthStencilState: MTLDepthStencilState
    let stencilRenderPassDescriptor: MTLRenderPassDescriptor
    let stencilRenderPipeline: MTLRenderPipelineState
    
    let lightVolumeDepthStencilState: MTLDepthStencilState
    var lightVolumeRenderPassDescriptor: MTLRenderPassDescriptor = MTLRenderPassDescriptor()
    let lightVolumeRenderPipeline: MTLRenderPipelineState
    // The final texture we'll blit to the screen
    var compositeTexture: MTLTexture

    init?(mtkView: MTKView) {
        
        view = mtkView
        
        // Use 4x MSAA multisampling
        view.sampleCount = 4
        // Clear to solid white
        view.clearColor = MTLClearColorMake(1, 1, 1, 1)
        // Use a BGRA 8-bit normalized texture for the drawable
        view.colorPixelFormat = .bgra8Unorm
        // Use a 32-bit depth buffer
        view.depthStencilPixelFormat = .depth32Float
        
        // Ask for the default Metal device; this represents our GPU.
        if let defaultDevice = MTLCreateSystemDefaultDevice() {
            device = defaultDevice
        }
        else {
            print("Metal is not supported")
            return nil
        }
        
        // Create the command queue we will be using to submit work to the GPU.
        commandQueue = device.makeCommandQueue()

        // Compile the functions and other state into a pipeline object.
        do {
            renderPipelineState = try Renderer.buildRenderPipelineWithDevice(device, view: mtkView)
        }
        catch {
            print("Unable to compile render pipeline state")
            return nil
        }

        mesh = Mesh(cubeWithSize: 1.0, device: device)!
        
        do {
            texture = try Renderer.buildTexture(name: "checkerboard", device)
        }
        catch {
            print("Unable to load texture from main bundle")
            return nil
        }

        // Make a depth-stencil state that passes when fragments are nearer to the camera than previous fragments
        depthStencilState = Renderer.buildDepthStencilStateWithDevice(device, compareFunc: .less, isWriteEnabled: true)
        
        // Make a texture sampler that wraps in both directions and performs bilinear filtering
        sampler = Renderer.buildSamplerStateWithDevice(device, addressMode: .repeat, filter: .linear)
        
        // To be used for the size of the render textures
        let drawableWidth = Int(self.view.drawableSize.width)
        let drawableHeight = Int(self.view.drawableSize.height)
        // We create our shaders from here
        let library = device.newDefaultLibrary()!
        
        // ---- BEGIN GBUFFER PASS PREP ---- //
        
        // Create GBuffer albedo texture
        // First we create a descriptor that describes the texture we're about to create
        let gBufferAlbedoTextureDescriptor: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: drawableWidth, height: drawableHeight, mipmapped: false)
        gBufferAlbedoTextureDescriptor.sampleCount = 1
        gBufferAlbedoTextureDescriptor.storageMode = .private
        gBufferAlbedoTextureDescriptor.textureType = .type2D
        gBufferAlbedoTextureDescriptor.usage = [.renderTarget, .shaderRead]
        
        // Then we make the texture
        gBufferAlbedoTexture = device.makeTexture(descriptor: gBufferAlbedoTextureDescriptor)
        
        // Create GBuffer normal texture
        let gBufferNormalTextureDescriptor: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: drawableWidth, height: drawableHeight, mipmapped: false)
        gBufferNormalTextureDescriptor.sampleCount = 1
        gBufferNormalTextureDescriptor.storageMode = .private
        gBufferNormalTextureDescriptor.textureType = .type2D
        gBufferNormalTextureDescriptor.usage = [.renderTarget, .shaderRead]
        
        gBufferNormalTexture = device.makeTexture(descriptor: gBufferNormalTextureDescriptor)
        
        // Create GBuffer position texture
        let gBufferPositionTextureDescriptor: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: drawableWidth, height: drawableHeight, mipmapped: false)
        gBufferPositionTextureDescriptor.sampleCount = 1
        gBufferPositionTextureDescriptor.storageMode = .private
        gBufferPositionTextureDescriptor.textureType = .type2D
        gBufferPositionTextureDescriptor.usage = [.renderTarget, .shaderRead]
        
        gBufferPositionTexture = device.makeTexture(descriptor: gBufferPositionTextureDescriptor)
        
        // Create GBuffer depth (and stencil) texture
        let gBufferDepthDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: drawableWidth, height: drawableHeight, mipmapped: false)
        gBufferDepthDesc.sampleCount = 1
        gBufferDepthDesc.storageMode = .private
        gBufferDepthDesc.textureType = .type2D
        gBufferDepthDesc.usage = [.renderTarget, .shaderRead]
        
        gBufferDepthTexture = device.makeTexture(descriptor: gBufferDepthDesc)
        
        // Build GBuffer depth/stencil state
        // Again we create a descriptor that describes the object we're about to create
        let gBufferDepthStencilStateDescriptor: MTLDepthStencilDescriptor = MTLDepthStencilDescriptor()
        gBufferDepthStencilStateDescriptor.isDepthWriteEnabled = true
        gBufferDepthStencilStateDescriptor.depthCompareFunction = .lessEqual
        gBufferDepthStencilStateDescriptor.frontFaceStencil = nil
        gBufferDepthStencilStateDescriptor.backFaceStencil = nil
        
        // Then we create the depth/stencil state
        gBufferDepthStencilState = device.makeDepthStencilState(descriptor: gBufferDepthStencilStateDescriptor)
        
        // Create GBuffer render pass descriptor
        gBufferRenderPassDescriptor = MTLRenderPassDescriptor()
        // Specify the properties of the first color attachment (our albedo texture)
        gBufferRenderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
        gBufferRenderPassDescriptor.colorAttachments[0].texture = gBufferAlbedoTexture
        gBufferRenderPassDescriptor.colorAttachments[0].loadAction = .clear
        gBufferRenderPassDescriptor.colorAttachments[0].storeAction = .store
        // Specify the properties of the second color attachment (our normal texture)
        gBufferRenderPassDescriptor.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 1)
        gBufferRenderPassDescriptor.colorAttachments[1].texture = gBufferNormalTexture
        gBufferRenderPassDescriptor.colorAttachments[1].loadAction = .clear
        gBufferRenderPassDescriptor.colorAttachments[1].storeAction = .store
        // Specify the properties of the third color attachment (our position texture)
        gBufferRenderPassDescriptor.colorAttachments[2].clearColor = MTLClearColorMake(0, 0, 0, 1)
        gBufferRenderPassDescriptor.colorAttachments[2].texture = gBufferPositionTexture
        gBufferRenderPassDescriptor.colorAttachments[2].loadAction = .clear
        gBufferRenderPassDescriptor.colorAttachments[2].storeAction = .store
        
        // Specify the properties of the depth attachment
        gBufferRenderPassDescriptor.depthAttachment.loadAction = .clear
        gBufferRenderPassDescriptor.depthAttachment.storeAction = .store
        gBufferRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture
        gBufferRenderPassDescriptor.depthAttachment.clearDepth = 1.0
        
        // Create GBuffer render pipeline
        let gBufferRenderPipelineDesc = MTLRenderPipelineDescriptor()
        gBufferRenderPipelineDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        
        gBufferRenderPipelineDesc.colorAttachments[0].isBlendingEnabled = true
        gBufferRenderPipelineDesc.colorAttachments[0].rgbBlendOperation = .add
        gBufferRenderPipelineDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        gBufferRenderPipelineDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        gBufferRenderPipelineDesc.colorAttachments[0].alphaBlendOperation = .add
        gBufferRenderPipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        gBufferRenderPipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        
        gBufferRenderPipelineDesc.colorAttachments[1].pixelFormat = .rgba16Float
        gBufferRenderPipelineDesc.colorAttachments[2].pixelFormat = .rgba16Float
        gBufferRenderPipelineDesc.depthAttachmentPixelFormat = .depth32Float_stencil8
        gBufferRenderPipelineDesc.stencilAttachmentPixelFormat = .depth32Float_stencil8
        gBufferRenderPipelineDesc.sampleCount = 1
        gBufferRenderPipelineDesc.label = "GBuffer Render"
        gBufferRenderPipelineDesc.vertexFunction = library.makeFunction(name: "gBufferVert")
        gBufferRenderPipelineDesc.fragmentFunction = library.makeFunction(name: "gBufferFrag")
        do {
            try gBufferRenderPipeline = device.makeRenderPipelineState(descriptor: gBufferRenderPipelineDesc)
        } catch let error {
            fatalError("Failed to create GBuffer pipeline state, error \(error)")
        }
        
        // ---- END GBUFFER PASS PREP ---- //

        lightSphere = Mesh(sphereWithSize: 1.0, device: device)!
        
        // Add space for each light's data
        for _ in 0...(lightNumber - 1) {
            lightProperties.append(PointLight())
            lightConstants.append(Constants())
        }
        
        // Hard-code position and radius
        lightProperties[0].worldPosition = float3(0.0, 0.4, 0.0)
        lightProperties[0].radius = 0.7
        
        lightProperties[1].worldPosition = float3(-0.4, 0.0, 0.0)
        lightProperties[1].radius = 0.6

        // ---- BEGIN STENCIL PASS PREP ---- //
        
        /* Be very careful with these operations, I clear the stencil buffer to a value of 0, so it's
         * very important that I set the depthFailureOperation to 'decrementWRAP' and 'incrementWRAP'
         * for the front and back face stencil operations (respectively) rather than 'decrementClamp'
         * and 'incrementClamp'. This is because we don't know in which order these operations will
         * occur. Let's say we use clamping:
         *
         * - Back then front order - two failures, expected stencil buffer value: 0
         * - Stencil buffer starts at 0
         * - Back face depth test fails first: stencil buffer incremented to 1
         * - Front face depth test fails second: stencil buffer decremented to 0
         * - Stencil buffer final value = 0 (== expected value) - all good!
         *
         * - Front then back order - two failures, expected stencil buffer value: 0
         * - Stencil buffer starts at 0
         * - Front face depth test fails first: stencil buffer decremented and clamped to 0
         * - Back face depth test fails second: stencil buffer incremented to 1
         * - Stencil buffer final value = 1 (!= expected value) - problem here!
         *
         * Wrapping does not have this issue. There are of course other ways to avoid this problem.
         */
        // Decrement when front faces depth fail
        let frontFaceStencilOp: MTLStencilDescriptor = MTLStencilDescriptor()
        frontFaceStencilOp.stencilCompareFunction = .always        // Stencil test always succeeds, only concerned about depth test
        frontFaceStencilOp.stencilFailureOperation = .keep         // Stencil test always succeeds
        frontFaceStencilOp.depthStencilPassOperation = .keep       // Do nothing if depth test passes
        frontFaceStencilOp.depthFailureOperation = .decrementWrap // Decrement if depth test fails
        
        // Increment when back faces depth fail
        let backFaceStencilOp: MTLStencilDescriptor = MTLStencilDescriptor()
        backFaceStencilOp.stencilCompareFunction = .always        // Stencil test always succeeds, only concerned about depth test
        backFaceStencilOp.stencilFailureOperation = .keep         // Stencil test always succeeds
        backFaceStencilOp.depthStencilPassOperation = .keep       // Do nothing if depth test passes
        backFaceStencilOp.depthFailureOperation = .incrementWrap // Increment if depth test fails
        
        let stencilPassDepthStencilStateDesc: MTLDepthStencilDescriptor = MTLDepthStencilDescriptor()
        stencilPassDepthStencilStateDesc.isDepthWriteEnabled = false           // Only concerned with modifying stencil buffer
        stencilPassDepthStencilStateDesc.depthCompareFunction = .lessEqual     // Only perform stencil op when depth function fails
        stencilPassDepthStencilStateDesc.frontFaceStencil = frontFaceStencilOp // For front-facing polygons
        stencilPassDepthStencilStateDesc.backFaceStencil = backFaceStencilOp   // For back-facing polygons
        stencilPassDepthStencilState = device.makeDepthStencilState(descriptor: stencilPassDepthStencilStateDesc)

        let stencilRenderPipelineDesc = MTLRenderPipelineDescriptor()
        stencilRenderPipelineDesc.label = "Stencil Pipeline"
        stencilRenderPipelineDesc.sampleCount = view.sampleCount
        stencilRenderPipelineDesc.vertexFunction = library.makeFunction(name: "stencilPassVert")
        stencilRenderPipelineDesc.fragmentFunction = library.makeFunction(name: "stencilPassNullFrag")
        stencilRenderPipelineDesc.depthAttachmentPixelFormat = .depth32Float_stencil8
        stencilRenderPipelineDesc.stencilAttachmentPixelFormat = .depth32Float_stencil8
        do {
            try stencilRenderPipeline = device.makeRenderPipelineState(descriptor: stencilRenderPipelineDesc)
        } catch let error {
            fatalError("Failed to create Stencil pipeline state, error \(error)")
        }
        
        stencilRenderPassDescriptor = MTLRenderPassDescriptor()
        stencilRenderPassDescriptor.depthAttachment.loadAction = .load      // Load up depth information from GBuffer pass
        stencilRenderPassDescriptor.depthAttachment.storeAction = .store    // We'll use depth information in later passes
        stencilRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture
        stencilRenderPassDescriptor.stencilAttachment.loadAction = .clear   // Contents of stencil buffer unkown at this point, clear it
        stencilRenderPassDescriptor.stencilAttachment.storeAction = .store  // Store the stencil buffer so that the next pass can use it
        stencilRenderPassDescriptor.stencilAttachment.texture = gBufferDepthTexture
        
        // ---- END STENCIL PASS  PREP ---- //
        
        // ---- BEGIN LIGHTING PASS PREP ---- //
        
        lightFragmentInput.screenSize.x = Float(view.drawableSize.width)
        lightFragmentInput.screenSize.y = Float(view.drawableSize.height)
        
        // Create composite texture
        let compositeTextureDescriptor: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: drawableWidth, height: drawableHeight, mipmapped: false)
        compositeTextureDescriptor.sampleCount = 1
        compositeTextureDescriptor.storageMode = .private
        compositeTextureDescriptor.textureType = .type2D
        compositeTextureDescriptor.usage = [.renderTarget]
        
        compositeTexture = device.makeTexture(descriptor: compositeTextureDescriptor)
        
        // Build light volume depth-stencil state
        let lightVolumeStencilOp: MTLStencilDescriptor = MTLStencilDescriptor()
        lightVolumeStencilOp.stencilCompareFunction = .notEqual           // Only pass if not equal to reference value (ref. value is 0 by default)
        lightVolumeStencilOp.stencilFailureOperation = .keep              // Don't modify stencil value at all
        lightVolumeStencilOp.depthStencilPassOperation = .keep
        lightVolumeStencilOp.depthFailureOperation = .keep                // Depth test is set to always succeed
        
        let lightVolumeDepthStencilStateDesc: MTLDepthStencilDescriptor = MTLDepthStencilDescriptor()
        lightVolumeDepthStencilStateDesc.isDepthWriteEnabled = false       // Don't modify depth buffer
        lightVolumeDepthStencilStateDesc.depthCompareFunction = .always // Stencil buffer will be used to determine if we should light this fragment, ignore depth value (always pass)
        lightVolumeDepthStencilStateDesc.backFaceStencil = lightVolumeStencilOp
        lightVolumeDepthStencilStateDesc.frontFaceStencil = lightVolumeStencilOp
        lightVolumeDepthStencilState = device.makeDepthStencilState(descriptor: lightVolumeDepthStencilStateDesc)
        
        // Build light volume render pass descriptor
        // Get current render pass descriptor instead
        lightVolumeRenderPassDescriptor = MTLRenderPassDescriptor()
        lightVolumeRenderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1)
        lightVolumeRenderPassDescriptor.colorAttachments[0].texture = compositeTexture
        lightVolumeRenderPassDescriptor.colorAttachments[0].loadAction = .clear
        lightVolumeRenderPassDescriptor.colorAttachments[0].storeAction = .store // Store for blitting
        lightVolumeRenderPassDescriptor.depthAttachment.clearDepth = 1.0
        // Aren't using depth
        /*
        lightVolumeRenderPassDescriptor.depthAttachment.loadAction = .load
        lightVolumeRenderPassDescriptor.depthAttachment.storeAction = .store
        lightVolumeRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture
        */
        lightVolumeRenderPassDescriptor.stencilAttachment.loadAction = .load
        lightVolumeRenderPassDescriptor.stencilAttachment.storeAction = .dontCare // Aren't using stencil buffer after this point
        lightVolumeRenderPassDescriptor.stencilAttachment.texture = gBufferDepthTexture
        
        // Build light volume render pipeline
        let lightVolumeRenderPipelineDesc = MTLRenderPipelineDescriptor()
        lightVolumeRenderPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // We need to enable blending as each light volume is additive (it 'adds' to the contribution of the previous one)
        lightVolumeRenderPipelineDesc.colorAttachments[0].isBlendingEnabled = true
        lightVolumeRenderPipelineDesc.colorAttachments[0].rgbBlendOperation = .add
        lightVolumeRenderPipelineDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        lightVolumeRenderPipelineDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        lightVolumeRenderPipelineDesc.colorAttachments[0].alphaBlendOperation = .add
        lightVolumeRenderPipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        lightVolumeRenderPipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        lightVolumeRenderPipelineDesc.depthAttachmentPixelFormat = .depth32Float_stencil8
        lightVolumeRenderPipelineDesc.stencilAttachmentPixelFormat = .depth32Float_stencil8
        lightVolumeRenderPipelineDesc.sampleCount = 1
        lightVolumeRenderPipelineDesc.label = "Light Volume Render"
        lightVolumeRenderPipelineDesc.vertexFunction = library.makeFunction(name: "stencilPassVert")
        lightVolumeRenderPipelineDesc.fragmentFunction = library.makeFunction(name: "lightVolumeFrag")
        do {
            try lightVolumeRenderPipeline = device.makeRenderPipelineState(descriptor: lightVolumeRenderPipelineDesc)
        } catch let error {
            fatalError("Failed to create lightVolume pipeline state, error \(error)")
        }

        // ---- END LIGHTING PASS PREP ---- //

        
        super.init()
        
        // Now that all of our members are initialized, set ourselves as the drawing delegate of the view
        view.delegate = self
        view.device = device
    }
    
    class func buildRenderPipelineWithDevice(_ device: MTLDevice, view: MTKView) throws -> MTLRenderPipelineState {
        // The default library contains all of the shader functions that were compiled into our app bundle
        let library = device.newDefaultLibrary()!
        
        // Retrieve the functions that will comprise our pipeline
        let vertexFunction = library.makeFunction(name: "vertex_transform")
        let fragmentFunction = library.makeFunction(name: "fragment_lit_textured")
        
        // A render pipeline descriptor describes the configuration of our programmable pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Render Pipeline"
        pipelineDescriptor.sampleCount = view.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    class func buildTexture(name: String, _ device: MTLDevice) throws -> MTLTexture {
        let textureLoader = MTKTextureLoader(device: device)
        let asset = NSDataAsset.init(name: name)
        if let data = asset?.data {
            return try textureLoader.newTexture(with: data, options: [:])
        } else {
            fatalError("Could not load image \(name) from an asset catalog in the main bundle")
        }
    }
    
    class func buildSamplerStateWithDevice(_ device: MTLDevice,
                                           addressMode: MTLSamplerAddressMode,
                                           filter: MTLSamplerMinMagFilter) -> MTLSamplerState
    {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.sAddressMode = addressMode
        samplerDescriptor.tAddressMode = addressMode
        samplerDescriptor.minFilter = filter
        samplerDescriptor.magFilter = filter
        return device.makeSamplerState(descriptor: samplerDescriptor)
    }

    class func buildDepthStencilStateWithDevice(_ device: MTLDevice,
                                                compareFunc: MTLCompareFunction,
                                                isWriteEnabled: Bool) -> MTLDepthStencilState
    {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = compareFunc
        desc.isDepthWriteEnabled = isWriteEnabled
        return device.makeDepthStencilState(descriptor: desc)
    }
    
    func updateWithTimestep(_ timestep: TimeInterval)
    {
        // We keep track of time so we can animate the various transformations
        time = time + timestep
        //time = 1.3
        let modelToWorldMatrix = matrix4x4_rotation(Float(time) * 0.5, vector_float3(0.7, 1, 0))
        
        // So that the figure doesn't get distorted when the window changes size or rotates,
        // we factor the current aspect ration into our projection matrix. We also select
        // sensible values for the vertical view angle and the distances to the near and far planes.
        let viewSize = self.view.bounds.size
        let aspectRatio = Float(viewSize.width / viewSize.height)
        let verticalViewAngle = radians_from_degrees(65)
        let nearZ: Float = 0.1
        let farZ: Float = 100.0
        let projectionMatrix = matrix_perspective(verticalViewAngle, aspectRatio, nearZ, farZ)
        
        let viewMatrix = matrix_look_at(0, 0, 2.5, 0, 0, 0, 0, 1, 0)

        // The combined model-view-projection matrix moves our vertices from model space into clip space
        let mvMatrix = matrix_multiply(viewMatrix, modelToWorldMatrix);
        constants.modelViewProjectionMatrix = matrix_multiply(projectionMatrix, mvMatrix)
        constants.normalMatrix = matrix_inverse_transpose(matrix_upper_left_3x3(mvMatrix))
        constants.modelMatrix = modelToWorldMatrix
        
        // Update light constants
        for i in 0...(lightNumber-1) {
            let lightModelToWorldMatrix = matrix_multiply(matrix4x4_translation(lightProperties[i].worldPosition.x, lightProperties[i].worldPosition.y, lightProperties[i].worldPosition.z), matrix4x4_scale(vector3(lightProperties[i].radius, lightProperties[i].radius, lightProperties[i].radius)))
            let lightMvMatrix = matrix_multiply(viewMatrix, lightModelToWorldMatrix);
            lightConstants[i].modelViewProjectionMatrix = matrix_multiply(projectionMatrix, lightMvMatrix)
            lightConstants[i].normalMatrix = matrix_inverse_transpose(matrix_upper_left_3x3(lightMvMatrix))
            lightConstants[i].modelMatrix = lightModelToWorldMatrix;
        }
    }

    func render(_ view: MTKView) {
        // Our animation will be dependent on the frame time, so that regardless of how
        // fast we're animating, the speed of the transformations will be roughly constant.
        let timestep = 1.0 / TimeInterval(view.preferredFramesPerSecond)
        updateWithTimestep(timestep)
        
        // Our command buffer is a container for the  work we want to perform with the GPU.
        let commandBuffer = commandQueue.makeCommandBuffer()
        
        let currDrawable = view.currentDrawable
        
        // ---- GBUFFER ---- //
        // Draw our scene to texture
        // We use an encoder to 'encode' commands into a command buffer
        let gBufferEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: gBufferRenderPassDescriptor)
        gBufferEncoder.pushDebugGroup("GBuffer") // For debugging
        gBufferEncoder.label = "GBuffer"
        // Use the depth stencil state we created earlier
        gBufferEncoder.setDepthStencilState(gBufferDepthStencilState)
        gBufferEncoder.setCullMode(.back)
        // Set winding order
        gBufferEncoder.setFrontFacing(.counterClockwise)
        // Use the render pipeline state we created earlier
        gBufferEncoder.setRenderPipelineState(gBufferRenderPipeline)
        // Upload vertex data
        gBufferEncoder.setVertexBuffer(mesh.vertexBuffer, offset:0, at:0)
        // Upload uniforms
        gBufferEncoder.setVertexBytes(&constants, length: MemoryLayout<Constants>.size, at: 1)
        // Bind the checkerboard texture (for the cube)
        gBufferEncoder.setFragmentTexture(texture, at: 0)
        // Draw our mesh
        gBufferEncoder.drawIndexedPrimitives(type: mesh.primitiveType,
                                              indexCount: mesh.indexCount,
                                              indexType: mesh.indexType,
                                              indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: 0)
        gBufferEncoder.popDebugGroup() // For debugging
        // Finish encoding commands in this encoder
        gBufferEncoder.endEncoding()
        
        // ---- STENCIL ---- //
        let stencilPassEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: stencilRenderPassDescriptor)
        stencilPassEncoder.pushDebugGroup("Stencil Pass")
        stencilPassEncoder.label = "Stencil Pass"
        stencilPassEncoder.setDepthStencilState(stencilPassDepthStencilState)
        // We want to draw back-facing AND front-facing polygons
        stencilPassEncoder.setCullMode(.none)
        stencilPassEncoder.setFrontFacing(.counterClockwise)
        stencilPassEncoder.setRenderPipelineState(stencilRenderPipeline)
        stencilPassEncoder.setVertexBuffer(lightSphere.vertexBuffer, offset:0, at:0)
        
        for i in 0...(lightNumber-1) {
            stencilPassEncoder.setVertexBytes(&lightConstants[i], length: MemoryLayout<Constants>.size, at: 1)
            stencilPassEncoder.drawIndexedPrimitives(type: lightSphere.primitiveType, indexCount: lightSphere.indexCount, indexType: lightSphere.indexType, indexBuffer: lightSphere.indexBuffer, indexBufferOffset: 0)
        }
        
        stencilPassEncoder.popDebugGroup()
        stencilPassEncoder.endEncoding()
        
        // ---- LIGHTING ---- //
        let lightPassEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: lightVolumeRenderPassDescriptor)
        lightPassEncoder.pushDebugGroup("Light Volume Pass")
        lightPassEncoder.label = "Light Volume Pass"
        // Use our previously configured depth stencil state
        lightPassEncoder.setDepthStencilState(lightVolumeDepthStencilState)
        // Set our stencil reference value to 0 (in the depth stencil state we configured fragments to pass only if they are NOT EQUAL to the reference value
        lightPassEncoder.setStencilReferenceValue(0)
        // We cull the front of the spherical light volume and not the back, in-case we are inside the light volume. I'm not 100% certain this is the best way to do this, but it seems to work.
        lightPassEncoder.setCullMode(.front)
        lightPassEncoder.setFrontFacing(.counterClockwise)
        lightPassEncoder.setRenderPipelineState(lightVolumeRenderPipeline)
        // Bind our GBuffer textures
        lightPassEncoder.setFragmentTexture(gBufferAlbedoTexture, at: 0)
        lightPassEncoder.setFragmentTexture(gBufferNormalTexture, at: 1)
        lightPassEncoder.setFragmentTexture(gBufferPositionTexture, at: 2)
        lightPassEncoder.setVertexBuffer(lightSphere.vertexBuffer, offset:0, at:0)
        // Upload our screen size
        lightPassEncoder.setFragmentBytes(&lightFragmentInput, length: MemoryLayout<LightFragmentInput>.size, at: 0)
        // Render light volumes
        for i in 0...(lightNumber - 1) {
            lightPassEncoder.setVertexBytes(&lightConstants[i], length: MemoryLayout<Constants>.size, at: 1)
            lightPassEncoder.drawIndexedPrimitives(type: lightSphere.primitiveType, indexCount: lightSphere.indexCount, indexType: lightSphere.indexType, indexBuffer: lightSphere.indexBuffer, indexBufferOffset: 0)
        }
        
        lightPassEncoder.popDebugGroup()
        lightPassEncoder.endEncoding()
        
        // ---- BLIT ---- //
        // Blit our texture to the screen
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        blitEncoder.pushDebugGroup("Blit")
        
        // Create a region that covers the entire texture we want to blit to the screen
        let origin: MTLOrigin = MTLOriginMake(0, 0, 0)
        let size: MTLSize = MTLSizeMake(Int(self.view.drawableSize.width), Int(self.view.drawableSize.height), 1)
        
        // Encode copy command, copying from our albedo texture to the 'current drawable' texture
        // The 'current drawable' is essentially a render target that can be displayed on the screen
        blitEncoder.copy(from: compositeTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size, to: (currDrawable?.texture)!, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        
        blitEncoder.endEncoding()
        blitEncoder.popDebugGroup()
        
        if let drawable = currDrawable
        {
            // Display our drawable to the screen
            commandBuffer.present(drawable)
        }

        // Finish encoding commands
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // respond to resize
    }

    @objc(drawInMTKView:)
    func draw(in metalView: MTKView)
    {
        render(metalView)
    }
}
