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

public protocol DirectoryWatcherDelegate {
    func directoryWatcher(directoryWatcher: DirectoryWatcher, filesChangedAtPath path: String)
    func directoryWatcher(directoryWatcher: DirectoryWatcher, directoryDeletedAtPath path: String)
    func directoryWatcher(directoryWatcher: DirectoryWatcher, renamedDirectory fromDirectory: String, toDirectory: String)
}

public class DirectoryWatcher {
    private var watchPath: String!
    private var autoWatchSubdirectory: Bool
    private var fid: CInt = 0
    private var subdirectoriesWatcher = [String: DirectoryWatcher]()
    private var subdirectories = Set<String>()
    private var source: dispatch_source_t!
    private let fm = NSFileManager.defaultManager()

    public var delegate: DirectoryWatcherDelegate?

    public private(set) var monitoring = false

    static private let watcherQueue = dispatch_queue_create("cn.firestudio.directory-watcher", DISPATCH_QUEUE_CONCURRENT)

    public init(watchPath: String, autoWatchSubdirectory: Bool = false) {
        self.watchPath = watchPath
        self.autoWatchSubdirectory = autoWatchSubdirectory
        let nc = NSNotificationCenter.defaultCenter()
        nc.addObserver(self, selector: #selector(DirectoryWatcher.removeSubdirectoryWatcher(_:)), name: DirectoryWatchDirectoryDeletedNotification, object: nil)
        nc.addObserver(self, selector: #selector(DirectoryWatcher.clearRenamedWatcher(_:)), name: DirectoryWatchDirectoryRenamedNotification, object: nil)
    }

    deinit {
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
        
        source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, UInt(fid), DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME, DirectoryWatcher.watcherQueue)
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
        for (_, submonitor) in subdirectoriesWatcher {
            submonitor.stopMonitoring()
        }
        subdirectoriesWatcher.removeAll()
        subdirectories.removeAll()
        dispatch_source_cancel(source)
    }

    private func watchSubdirectories() {
        guard self.autoWatchSubdirectory else { return }
        var directories = Set<String>()
        if let directoryEnumerator = fm.enumeratorAtPath(self.watchPath) {
            for file in directoryEnumerator {
                let directoryPath = self.watchPath as NSString
                let fullFilename = directoryPath.stringByAppendingPathComponent(file as! String)
                var isDir: ObjCBool = false
                if fm.fileExistsAtPath(fullFilename, isDirectory: &isDir) && isDir.boolValue {
                    directories.insert(fullFilename)
                }
            }
        }

        directories.forEach {
            if !self.subdirectories.contains($0) {
                self.subdirectories.insert($0)
                let dw = DirectoryWatcher(watchPath: $0, autoWatchSubdirectory: true)
                dw.delegate = delegate
                dw.startMonitoring()
                self.subdirectoriesWatcher[$0] = dw
            }
        }
    }

    @objc private func removeSubdirectoryWatcher(notification: NSNotification) {
        guard let deletedPath = notification.userInfo?[DirectoryWatchPathKey] as? String else { return }
        if subdirectories.contains(deletedPath) {
            subdirectories.remove(deletedPath)
            if let dw = subdirectoriesWatcher.removeValueForKey(deletedPath) where dw.monitoring {
                dw.stopMonitoring()
            }
        }
    }

    @objc private func clearRenamedWatcher(notification: NSNotification) {
        guard let renamedPath = notification.userInfo?[DirectoryWatchOldPathKey] as? String else { return }
        if subdirectories.contains(renamedPath) {
            subdirectories.remove(renamedPath)
            if let dw = subdirectoriesWatcher.removeValueForKey(renamedPath) where dw.monitoring {
                dw.stopMonitoring()
            }
        }
    }
}