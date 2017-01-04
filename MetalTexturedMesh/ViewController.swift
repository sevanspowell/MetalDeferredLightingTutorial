/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information
    
    Abstract:
    View controller class that manages the MTKView and renderer.
*/

import MetalKit
import Cocoa

class ViewController: NSViewController {

    var renderer: Renderer!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let metalView = self.view as! MTKView
        
        // We initialize our renderer object with the MTKView it will be drawing into
        renderer = Renderer(mtkView:metalView)
    }
}
