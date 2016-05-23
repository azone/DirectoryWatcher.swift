//
//  ViewController.swift
//  DirectoryWatcherDemo
//
//  Created by Yozone Wang on 16/5/19.
//  Copyright © 2016年 Yozone Wang. All rights reserved.
//

import UIKit
import DirectoryWatcherKit

class ViewController: UIViewController {

    var dw: DirectoryWatcher!

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        let documentDirectory = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true).last!
        dw = DirectoryWatcher(watchPath: documentDirectory, autoWatchSubdirectory: true)
        dw.delegate = self
        dw.startMonitoring()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
}

extension ViewController: DirectoryWatcherDelegate {
    func directoryWatcher(directoryWatcher: DirectoryWatcher, filesChangedAtPath path: String) {
        let fm = NSFileManager.defaultManager()
        print("DIRECTORY CONTENTS:")
        print(try? fm.contentsOfDirectoryAtPath(path))
    }
    
    func directoryWatcher(directoryWatcher: DirectoryWatcher, directoryDeletedAtPath path: String) {
        print("DIRECTORY DELETED: \(path)")
    }
    
    func directoryWatcher(directoryWatcher: DirectoryWatcher, renamedDirectory fromDirectory: String, toDirectory: String) {
        print("DIRECTORY RENAMED FROM \(fromDirectory) to \(toDirectory)")
    }
}

