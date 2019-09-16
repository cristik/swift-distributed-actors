//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
@testable import DistributedActorsTestKit
import XCTest

class ActorTestProbeTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown()
    }

    func test_maybeExpectMessage_shouldReturnTheReceivedMessage() throws {
        let probe = self.testKit.spawnTestProbe("p2", expecting: String.self)

        probe.tell("one")

        try probe.maybeExpectMessage().shouldEqual("one")
    }

    func test_maybeExpectMessage_shouldReturnNilIfTimeoutExceeded() throws {
        let probe = self.testKit.spawnTestProbe("p2", expecting: String.self)

        probe.tell("one")

        try probe.maybeExpectMessage().shouldEqual("one")
    }

    func test_expectNoMessage() throws {
        let p = self.testKit.spawnTestProbe("p3", expecting: String.self)

        try p.expectNoMessage(for: .milliseconds(100))
        p.stop()
    }

    func test_shouldBeWatchable() throws {
        let watchedProbe = self.testKit.spawnTestProbe(expecting: Never.self)
        let watchingProbe = self.testKit.spawnTestProbe(expecting: Never.self)

        watchingProbe.watch(watchedProbe.ref)

        watchedProbe.stop()

        try watchingProbe.expectTerminated(watchedProbe.ref)
    }

    func test_expectMessageAnyOrderSuccess() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)
        let messages = ["test1", "test2", "test3", "test4"]

        for message in messages.reversed() {
            p.ref.tell(message)
        }

        try p.expectMessagesInAnyOrder(messages)
    }
}