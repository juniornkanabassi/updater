//
//  main.swift
//  UpdateInstaller
//
//  Created by Max Langer on 06.01.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//

import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
  /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection)
    -> Bool
  {
    newConnection.setCodeSigningRequirement(UpdateInstallerIdentity.appRequirement)
    newConnection.exportedInterface = NSXPCInterface(with: UpdateInstallerProtocol.self)

    newConnection.exportedObject = UpdateInstaller()
    newConnection.resume()

    return true
  }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Create and start the listener
let listener = NSXPCListener(machServiceName: UpdateInstallerIdentity.service)
listener.delegate = delegate
listener.resume()

// Keep the main run loop running
RunLoop.current.run()
