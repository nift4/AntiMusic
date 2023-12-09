//
// ViewController.swift
// AntiMusic
//
// Created by nift4 on 09.12.2023.
//

import Foundation
import UniformTypeIdentifiers
import Cocoa

public class ViewController : NSViewController {

    @IBOutlet weak var button: NSButton!
    @IBOutlet weak var label: NSTextField!
    @IBOutlet weak var checkbox: NSButton!
    var delegate: AppDelegate? = nil
    private var hasOpenPanel = false

    @IBAction func onPressChange(sender: NSButton) {
        if (delegate == nil || hasOpenPanel) {
            return
        }
        let panel = NSOpenPanel()
        panel.showsResizeIndicator = true
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = NSURL(fileURLWithPath: "/Applications").filePathURL
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType.application]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        hasOpenPanel = true
        panel.begin { [self] result in
            hasOpenPanel = false
            if (result == NSApplication.ModalResponse.OK) {
                do {
                    delegate!.playerApp = try NSURL(resolvingAliasFileAt: panel.url!).path!
                } catch {
                    NSLog("failed parsing URL %@", panel.url!.absoluteString)
                }
                label.stringValue = delegate!.playerApp
                delegate!.writeSettings()
                delegate!.refreshFakePlayerMetadata()
                delegate!.refreshNowPlaying()
            }
        }
    }
    @IBAction func onToggleIgnore(sender: NSButton) {
        if (hasOpenPanel) {
            return
        }
        delegate?.ignoreMediaKey = sender.state == .on
        delegate?.writeSettings()
    }
}

// https://stackoverflow.com/a/24590678
extension NSView {
    var parentViewController: NSViewController? {
        var parentResponder: NSResponder? = self.nextResponder
        while parentResponder != nil {
            if let viewController = parentResponder as? NSViewController {
                return viewController
            }
            parentResponder = parentResponder?.nextResponder
        }
        return nil
    }
}

// https://stackoverflow.com/a/48147918
extension NSImage {
    func copy(size: NSSize) -> NSImage? {
        // Create a new rect with given width and height
        let frame = NSMakeRect(0, 0, size.width, size.height)
        
        // Get the best representation for the given size.
        guard let rep = self.bestRepresentation(for: frame, context: nil, hints: nil) else {
            return nil
        }
        
        // Create an empty image with the given size.
        let img = NSImage(size: size)
        
        // Set the drawing context and make sure to remove the focus before returning.
        img.lockFocus()
        defer { img.unlockFocus() }
        
        // Draw the new image
        if rep.draw(in: frame) {
            return img
        }
        
        // Return nil in case something went wrong.
        return nil
    }
    
    func resizeWhileMaintainingAspectRatioToSizeInverted(size: NSSize) -> NSImage? {
        let newSize: NSSize
        
        let widthRatio  = size.width / self.size.width
        let heightRatio = size.height / self.size.height
        
        if widthRatio > heightRatio {
            newSize = NSSize(width: floor(self.size.width * heightRatio), height: floor(self.size.height * heightRatio))
            } else {
                newSize = NSSize(width: floor(self.size.width * widthRatio), height: floor(self.size.height * widthRatio))
            }

        return self.copy(size: newSize)
    }
    
    func crop(size: NSSize) -> NSImage? {
        // Resize the current image, while preserving the aspect ratio.
        guard let resized = self.resizeWhileMaintainingAspectRatioToSizeInverted(size: size) else {
            return nil
        }
        // Get some points to center the cropping area.
        let x = floor((resized.size.width - size.width) / 2)
        let y = floor((resized.size.height - size.height) / 2)
        
        // Create the cropping frame.
        let frame = NSMakeRect(x, y, size.width, size.height)
        
        // Get the best representation of the image for the given cropping frame.
        guard let rep = resized.bestRepresentation(for: frame, context: nil, hints: nil) else {
            return nil
        }
        
        // Create a new image with the new size
        let img = NSImage(size: size)
        
        img.lockFocus()
        defer { img.unlockFocus() }
        
        if rep.draw(in: NSMakeRect(0, 0, size.width, size.height),
                    from: frame,
                    operation: NSCompositingOperation.copy,
                    fraction: 1.0,
                    respectFlipped: false,
                    hints: [:]) {
            // Return the cropped image.
            return img
        }
        
        // Return nil in case anything fails.
        return nil
    }
}
