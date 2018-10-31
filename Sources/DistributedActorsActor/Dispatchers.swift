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

import Dispatch
import NIO

/// An `Executor` is a low building block that is able to take blocks and schedule them for running
public protocol MessageDispatcher {

  // TODO we should make it dedicated to dispatch() rather than raw executing perhaps? This way it can take care of fairness things

  // func attach(cell: AnyActorCell)

  var name: String { get }

  /// - Returns: `true` iff the mailbox status indicated that the mailbox should be run (still contains pending messages)
  //func registerForExecution(_ mailbox: Mailbox, status: MailboxStatus, hasMessageHint: Bool, hasSystemMessageHint: Bool) -> Bool

  func execute(_ f: @escaping () -> Void)
}