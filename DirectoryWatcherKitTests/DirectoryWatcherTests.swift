//
//  DirectoryWatcherTests.swift
//  DirectoryWatcherTests
//
//  Created by Yozone Wang on 16/5/19.
//  Copyright © 2016年 Yozone Wang. All rights reserved.
//

import XCTest
@testable import DirectoryWatcher

class DirectoryWatcherTests: XCTestCase {

    var dw: DirectoryWatcher!
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
        let documentDirectory = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true).last!
        dw = DirectoryWatcher(watchPath: documentDirectory, autoWatchSubdirectory: true)
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
        dw.stopMonitoring()
    }
    
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }
    
    func testPerformanceExample() {
        // This is an example of a performance test case.
        self.measureBlock {
            // Put the code you want to measure the time of here.
        }
    }
    
}
