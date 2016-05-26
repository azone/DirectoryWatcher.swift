//
//  DirectoryWatcher.swift
//  DirectoryWatcher
//
//  Created by Yozone Wang on 16/5/19.
//  Copyright © 2016年 Yozone Wang. All rights reserved.
//

import Foundation

public let DirectoryWatchFilesChangedNotification = "cn.firestudio.directory-watcher.DirectoryWatchFilesChangedNotification"
public let DirectoryWatchDirectoryDeletedNotification = "cn.firestudio.directory-watcher.DirectoryWatchDirectoryDeletedNotification"
public let DirectoryWatchDirectoryRenamedNotification = "cn.firestudio.directory-watcher.DirectoryWatchDirectoryRenamedNotification"

public let DirectoryWatchPathKey = "cn.firestudio.directory-watcher.DirectoryWatchPathKey"
public let DirectoryWatchOldPathKey = "cn.firestudio.directory-watcher.DirectoryWatchOldPathKey"
public let DirectoryWatchNewPathKey = "cn.firestudio.directory-watcher.DirectoryWatchNewPathKey"

public protocol DirectoryWatcherDelegate: class {
    func directoryWatcher(directoryWatcher: DirectoryWatcher, filesChangedAtPath path: String)
    func directoryWatcher(directoryWatcher: DirectoryWatcher, directoryDeletedAtPath path: String)
    func directoryWatcher(directoryWatcher: DirectoryWatcher, renamedDirectory fromDirectory: String, toDirectory: String)
}

public class DirectoryWatcher {
    public private(set) var watchPath: String!
    private var autoWatchSubdirectory: Bool
    private var fid: CInt = 0
    private var subdirectoriesWatcher = [String: DirectoryWatcher]()
    private var subdirectories = Set<String>()
    private var source: dispatch_source_t!
    private let fm = NSFileManager.defaultManager()

    public private(set) var parentWatcher: DirectoryWatcher?
    public var rootWatcher: DirectoryWatcher {
        var parentWatcher = self.parentWatcher
        while parentWatcher?.parentWatcher != nil {
            parentWatcher = parentWatcher?.parentWatcher
        }
        if parentWatcher == nil {
            return self
        }
        return parentWatcher!
    }

    public weak var delegate: DirectoryWatcherDelegate?

    public private(set) var monitoring = false

    private static var QueueSpecificKey = 0
    private static var QueueSpecificContext = 0

    static private let WatcherQueue: dispatch_queue_t = {
        let queue = dispatch_queue_create("cn.firestudio.directory-watcher", DISPATCH_QUEUE_SERIAL)
        dispatch_queue_set_specific(queue, &DirectoryWatcher.QueueSpecificKey, &DirectoryWatcher.QueueSpecificContext, nil)
        return queue
    }()

    public init(watchPath: String, autoWatchSubdirectory: Bool = false) {
        self.watchPath = watchPath
        self.autoWatchSubdirectory = autoWatchSubdirectory
        let nc = NSNotificationCenter.defaultCenter()
        nc.addObserver(self, selector: #selector(DirectoryWatcher.removeSubdirectoryWatcher(_:)), name: DirectoryWatchDirectoryDeletedNotification, object: nil)
        nc.addObserver(self, selector: #selector(DirectoryWatcher.clearRenamedWatcher(_:)), name: DirectoryWatchDirectoryRenamedNotification, object: nil)
    }

    deinit {
        stopMonitoring()
        
        let nc = NSNotificationCenter.defaultCenter()
        nc.removeObserver(self, name: DirectoryWatchDirectoryDeletedNotification, object: nil)
        nc.removeObserver(self, name: DirectoryWatchDirectoryRenamedNotification, object: nil)
    }

    public func startMonitoring() -> Bool {
        // return true if is monitoring
        guard !monitoring else { return true }
        
        fid = open(watchPath, O_EVTONLY)
        guard fid >= 0 else { return false }

        monitoring = true

        watchSubdirectories()
        
        source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, UInt(fid), DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME, DirectoryWatcher.WatcherQueue)
        dispatch_source_set_event_handler(source) { 
            let mask = dispatch_source_get_data(self.source)
            if mask & DISPATCH_VNODE_DELETE == DISPATCH_VNODE_DELETE {
                // TODO: 看哪个目录或者文件被删除了，然后停止观察
                self.stopMonitoring()
                dispatch_async(dispatch_get_main_queue()) {
                    self.delegate?.directoryWatcher(self, directoryDeletedAtPath: self.watchPath)
                    let nc = NSNotificationCenter.defaultCenter()
                    nc.postNotificationName(DirectoryWatchDirectoryDeletedNotification, object: self, userInfo: [DirectoryWatchPathKey: self.watchPath])
                }
                return
            }
            if mask & DISPATCH_VNODE_RENAME == DISPATCH_VNODE_RENAME {
                let maxPathLength = Int(PATH_MAX)
                let newFilePathPointer = UnsafeMutablePointer<CChar>.alloc(maxPathLength)
                var newFilePath: String = ""
                if fcntl(self.fid, F_GETPATH, newFilePathPointer) >= 0{
                    newFilePath = String.fromCString(newFilePathPointer) ?? ""
                    newFilePathPointer.destroy()
                    newFilePathPointer.dealloc(maxPathLength)
                }
                
                dispatch_async(dispatch_get_main_queue()) {
                    self.delegate?.directoryWatcher(self, renamedDirectory: self.watchPath, toDirectory: newFilePath)
                    let nc = NSNotificationCenter.defaultCenter()
                    nc.postNotificationName(DirectoryWatchDirectoryRenamedNotification,
                                            object: self,
                                            userInfo: [
                                                DirectoryWatchOldPathKey: self.watchPath,
                                                DirectoryWatchNewPathKey: newFilePath
                        ]
                    )
                }
                return
            }
            self.watchSubdirectories()
            dispatch_async(dispatch_get_main_queue()) {
                self.delegate?.directoryWatcher(self, filesChangedAtPath: self.watchPath)
                let nc = NSNotificationCenter.defaultCenter()
                nc.postNotificationName(DirectoryWatchFilesChangedNotification, object: self, userInfo: [DirectoryWatchPathKey: self.watchPath])
            }
        }
        dispatch_source_set_cancel_handler(source) { 
            close(self.fid)
            self.monitoring = false
        }
        dispatch_resume(source)

        return true
    }

    public func stopMonitoring() {
        guard monitoring else { return }

        performOnWatcherQueue {
            self.parentWatcher = nil
            for (_, submonitor) in self.subdirectoriesWatcher {
                submonitor.stopMonitoring()
            }
            self.subdirectoriesWatcher.removeAll()
            self.subdirectories.removeAll()
            dispatch_source_cancel(self.source)
        }
    }

    private func watchSubdirectories() {
        performOnWatcherQueue {
            guard self.autoWatchSubdirectory else { return }
            var directories = Set<String>()
            if let directoryContents = try? self.fm.contentsOfDirectoryAtPath(self.watchPath) {
                for file in directoryContents {
                    let directoryPath = self.watchPath as NSString
                    let fullFilename = directoryPath.stringByAppendingPathComponent(file)
                    var isDir: ObjCBool = false
                    if self.fm.fileExistsAtPath(fullFilename, isDirectory: &isDir) && isDir.boolValue {
                        directories.insert(fullFilename)
                    }
                }
            }

            directories.forEach {
                if !self.subdirectories.contains($0) {
                    self.subdirectories.insert($0)
                    let dw = DirectoryWatcher(watchPath: $0, autoWatchSubdirectory: true)
                    dw.delegate = self.delegate
                    dw.parentWatcher = self
                    dw.startMonitoring()
                    self.subdirectoriesWatcher[$0] = dw
                }
            }
        }
    }

    @objc private func removeSubdirectoryWatcher(notification: NSNotification) {
        performOnWatcherQueue {
            guard let deletedPath = notification.userInfo?[DirectoryWatchPathKey] as? String else { return }
            if self.subdirectories.contains(deletedPath) {
                self.subdirectories.remove(deletedPath)
                if let dw = self.subdirectoriesWatcher.removeValueForKey(deletedPath) where dw.monitoring {
                    dw.stopMonitoring()
                }
            }
        }
    }

    @objc private func clearRenamedWatcher(notification: NSNotification) {
        performOnWatcherQueue {
            guard let renamedPath = notification.userInfo?[DirectoryWatchOldPathKey] as? String else { return }
            if self.subdirectories.contains(renamedPath) {
                self.subdirectories.remove(renamedPath)
                if let dw = self.subdirectoriesWatcher.removeValueForKey(renamedPath) where dw.monitoring {
                    dw.stopMonitoring()
                }
            }
        }
    }
}

extension DirectoryWatcher: CustomStringConvertible {
    public var description: String {
        let oid = ObjectIdentifier(self).uintValue
        var descriptionString = String(format: "<\(self.dynamicType): 0x%lx> {", oid)
        descriptionString += "\n\twatch path: \(watchPath),"
        if !subdirectories.isEmpty {
            descriptionString += "\n\twatched subdirectories: [\n\(subdirectories.joinWithSeparator(",\n"))\n\t\t]"
        }
        descriptionString += "\n}"
        return descriptionString
    }
}

private func performOnWatcherQueue(block: () -> Void) {
    let specific = dispatch_get_specific(&DirectoryWatcher.QueueSpecificKey)
    if specific == &DirectoryWatcher.QueueSpecificContext {
        block()
    } else {
        dispatch_async(DirectoryWatcher.WatcherQueue, block)
    }
}