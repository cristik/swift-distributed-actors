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

import Backtrace
import CDistributedActorsMailbox
import Dispatch
import DistributedActorsConcurrencyHelpers
import Logging
import NIO

/// An `ActorSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ActorSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
///
/// An `ActorSystem` and all of the actors contained within remain alive until the `terminate` call is made.
public final class ActorSystem {
    public let name: String

    // initialized during startup
    internal var _deadLetters: ActorRef<DeadLetter>!

//    /// Impl note: Atomic since we are being called from outside actors here (or MAY be), thus we need to synchronize access
    // TODO: avoid the lock...
    internal var _namingContext = ActorNamingContext()
    internal let namingLock = Lock()
    internal func withNamingContext<T>(_ block: (inout ActorNamingContext) throws -> T) rethrows -> T {
        return try self.namingLock.withLock {
            try block(&self._namingContext)
        }
    }

    private let dispatcher: InternalMessageDispatcher

    // TODO: converge into one tree? // YEAH
    // Note: This differs from Akka, we do full separate trees here
    private var systemProvider: _ActorRefProvider!
    private var userProvider: _ActorRefProvider!

    internal let _root: ReceivesSystemMessages

    private let terminationLock = Lock()

    /// Allows inspecting settings that were used to configure this actor system.
    /// Settings are immutable and may not be changed once the system is running.
    public let settings: ActorSystemSettings

    // initialized during startup
    public var serialization: Serialization!

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Receptionist

    public var receptionist: ActorRef<Receptionist.Message> {
        return self._receptionist
    }

    private var _receptionist: ActorRef<Receptionist.Message>!

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: CRDT Replicator

    internal var replicator: ActorRef<CRDT.Replicator.Message> {
        return self._replicator
    }

    private var _replicator: ActorRef<CRDT.Replicator.Message>!

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Metrics

    internal var metrics: ActorSystemMetrics {
        return self._metrics
    }

    private lazy var _metrics: ActorSystemMetrics = ActorSystemMetrics(self.settings.metrics)

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Cluster

    // initialized during startup
    internal var _cluster: ClusterShell?
    internal var _clusterControl: ClusterControl?
    internal var _nodeDeathWatcher: NodeDeathWatcherShell.Ref?

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Logging

    public var log: Logger {
        var l = ActorLogger.make(system: self) // we only do this to go "through" the proxy; we may not need it in the future?
        l.logLevel = self.settings.defaultLogLevel
        return l
    }

    internal let eventLoopGroup: MultiThreadedEventLoopGroup

    #if SACT_TESTS_LEAKS
    static let actorSystemInitCounter: Atomic<Int> = Atomic(value: 0)
    let userCellInitCounter: Atomic<Int> = Atomic(value: 0)
    let userMailboxInitCounter: Atomic<Int> = Atomic(value: 0)
    #endif

    /// Creates a named ActorSystem
    /// The name is useful for debugging cross system communication
    ///
    /// - Faults: when configuration closure performs very illegal action, e.g. reusing a serializer identifier
    public convenience init(_ name: String, configuredWith configureSettings: (inout ActorSystemSettings) -> Void = { _ in () }) {
        var settings = ActorSystemSettings()
        settings.cluster.node.systemName = name
        settings.metrics.systemName = name
        configureSettings(&settings)
        self.init(settings: settings)
    }

    public init(settings: ActorSystemSettings) {
        var settings = settings
        self.name = settings.cluster.node.systemName

        // rely on swift-backtrace for pretty backtraces on crashes
        if settings.installSwiftBacktrace {
            Backtrace.install()
        }

        // TODO: we should not rely on NIO for futures
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: settings.threadPoolSize)
        settings.cluster.eventLoopGroup = eventLoopGroup

        // TODO: should we share this, or have a separate ELG for IO?
        self.eventLoopGroup = eventLoopGroup

        self.settings = settings

        self.dispatcher = try! FixedThreadPool(settings.threadPoolSize)

        // initialize top level guardians
        self._root = TheOneWhoHasNoParent()
        let theOne = self._root

        // dead letters init
        var deadLogger = settings.overrideLogger ?? Logger(label: ActorPath._deadLetters.description, factory: {
            let context = LoggingContext(identifier: $0, useBuiltInFormatter: settings.useBuiltInFormatter, dispatcher: nil)
            if settings.cluster.enabled {
                context[metadataKey: "node"] = .stringConvertible(settings.cluster.uniqueBindNode)
            }
            context[metadataKey: "nodeName"] = .stringConvertible(name)
            return ActorOriginLogHandler(context)
        })
        deadLogger.logLevel = settings.defaultLogLevel

        self._deadLetters = ActorRef(.deadLetters(.init(deadLogger, address: ActorAddress._deadLetters, system: self)))

        // actor providers
        let localUserProvider = LocalActorRefProvider(root: Guardian(parent: theOne, name: "user", system: self))
        let localSystemProvider = LocalActorRefProvider(root: Guardian(parent: theOne, name: "system", system: self))
        // TODO: want to reconciliate those into one, and allow /dead as well

        var effectiveUserProvider: _ActorRefProvider = localUserProvider
        var effectiveSystemProvider: _ActorRefProvider = localSystemProvider

        if settings.cluster.enabled {
            // FIXME: make SerializationPoolSettings configurable
            let cluster = ClusterShell()
            self._cluster = cluster
            effectiveUserProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localUserProvider)
            effectiveSystemProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localSystemProvider)
        } else {
            self._cluster = nil
            self._clusterControl = ClusterControl(self.settings.cluster, clusterRef: self.deadLetters.adapted(), eventStream: EventStream(ref: self.deadLetters.adapted()))
        }

        self.systemProvider = effectiveSystemProvider
        self.userProvider = effectiveUserProvider

        // serialization
        let traversable = CompositeActorTreeTraversable(systemTree: effectiveSystemProvider, userTree: effectiveUserProvider)

        self.serialization = Serialization(settings: settings, system: self, traversable: traversable)

        // HACK to allow starting the receptionist, otherwise we'll get initialization errors from the compiler
        self._receptionist = deadLetters.adapted()

        let receptionistBehavior = self.settings.cluster.enabled ? ClusterReceptionist.behavior(syncInterval: settings.cluster.receptionistSyncInterval) : LocalReceptionist.behavior
        let lazyReceptionist = try! self._prepareSystemActor(Receptionist.naming, receptionistBehavior, perpetual: true)
        self._receptionist = lazyReceptionist.ref

        let lazyReplicator = try! self._prepareSystemActor(CRDT.Replicator.naming, CRDT.Replicator.Shell(settings: .default).behavior, perpetual: true)
        self._replicator = lazyReplicator.ref

        #if SACT_TESTS_LEAKS
        _ = ActorSystem.actorSystemInitCounter.add(1)
        #endif

        var lazyCluster: LazyStart<ClusterShell.Message>?
        var lazyNodeDeathWatcher: LazyStart<NodeDeathWatcherShell.Message>?
        do {
            if let cluster = self._cluster {
                let clusterEvents = try! EventStream<ClusterEvent>(self, name: "clusterEvents", systemStream: true)
                lazyCluster = try cluster.start(system: self, eventStream: clusterEvents) // only spawns when cluster is initialized

                self._clusterControl = ClusterControl(settings.cluster, clusterRef: cluster.ref, eventStream: clusterEvents)

                // Node watcher MUST be started AFTER cluster and clusterEvents
                lazyNodeDeathWatcher = try self._prepareSystemActor(
                    NodeDeathWatcherShell.naming,
                    NodeDeathWatcherShell.behavior(clusterEvents: clusterEvents),
                    perpetual: true
                )
                self._nodeDeathWatcher = lazyNodeDeathWatcher?.ref
            }
        } catch {
            fatalError("Failed while starting cluster subsystem! Error: \(error)")
        }

        _ = self.metrics // force init of metrics

        // Wake up all the delayed actors. This MUST be the last thing to happen
        // in the initialization of the actor system, as we will start receiving
        // messages and all field on the system have to be initialized beforehand.
        lazyReceptionist.wakeUp()
        lazyReplicator.wakeUp()
        lazyCluster?.wakeUp()
        lazyNodeDeathWatcher?.wakeUp()
    }

    public convenience init() {
        self.init("ActorSystem")
    }

    deinit {
        #if SACT_TESTS_LEAKS
        _ = ActorSystem.actorSystemInitCounter.sub(1)
        #endif
    }

    // FIXME: make termination async and add an awaitable that signals completion of the termination

    /// Forcefully stops this actor system and all actors that live within.
    ///
    /// - Warning: Blocks current thread until the system has terminated.
    ///            Do not call from within actors or you may deadlock shutting down the system.
    public func shutdown() {
        self.log.log(level: .debug, "SHUTTING DOWN ACTOR SYSTEM [\(self.name)]. All actors will be stopped.", file: #file, function: #function, line: #line)
        if let cluster = self._cluster {
            let receptacle = BlockingReceptacle<Void>()
            cluster.ref.tell(.command(.unbind(receptacle))) // FIXME: should be shutdown
            receptacle.wait(atMost: .milliseconds(300)) // FIXME: configure
        }
        self.userProvider.stopAll()
        self.systemProvider.stopAll()
        self.dispatcher.shutdown()
        try! self.eventLoopGroup.syncShutdownGracefully()
        self.serialization = nil
        self._cluster = nil
        self._receptionist = self.deadLetters.adapted()
    }

    public var cluster: ClusterControl {
        guard let clusterControl = self._clusterControl else {
            fatalError("BUG! Tried to access clusterControl on \(self) and it was nil! Please report this on the issue tracker.")
        }

        return clusterControl
    }
}

extension ActorSystem: Equatable {
    public static func == (lhs: ActorSystem, rhs: ActorSystem) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

extension ActorSystem: CustomStringConvertible {
    public var description: String {
        var res = "ActorSystem("
        res.append(self.name)
        if self.settings.cluster.enabled {
            res.append(", \(self.cluster.node)")
        }
        res.append(")")
        return res
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorRefFactory

/// Public but not intended for user-extension.
///
/// An `ActorRefFactory` is able to create ("spawn") new actors and return `ActorRef` instances for them.
/// Only the `ActorSystem`, `ActorContext` and potentially testing facilities can ever expose this ability.
public protocol ActorRefFactory {
    /// Spawn an actor with the given `name`, optional `props` and `behavior`.
    ///
    /// ### Naming
    /// `ActorNaming` is used to determine the actors real name upon spawning;
    /// A name can be sequentially (or otherwise) assigned based on the owning naming context (i.e. `ActorContext` or `ActorSystem`).
    ///
    /// - Returns: `ActorRef` for the spawned actor.
    func spawn<Message>(_ naming: ActorNaming, of type: Message.Type, props: Props, _ behavior: Behavior<Message>) throws -> ActorRef<Message>
}

extension ActorRefFactory {
    func spawn<Message>(_ naming: ActorNaming, props: Props, _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        return try self.spawn(naming, of: Message.self, props: props, behavior)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor creation

extension ActorSystem: ActorRefFactory {
    /// Spawn a new top-level Actor with the given initial behavior and name.
    ///
    /// - throws: when the passed behavior is not a legal initial behavior
    /// - throws: when the passed actor name contains illegal characters (e.g. symbols other than "-" or "_")
    public func spawn<Message>(_ naming: ActorNaming, of type: Message.Type = Message.self, props: Props = Props(), _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        return try self._spawn(using: self.userProvider, behavior, name: naming, props: props)
    }

    // Implementation note:
    // `perpetual` here means that the actor always exists and must be addressable without receiving a reference / path to it. This is for example necessary
    // to discover the receptionist actors on all nodes in order to replicate state between them. The incarnation of those actors will be `ActorIncarnation.perpetual`. This
    // also means that there will only be one instance of that actor that will stay alive for the whole lifetime of the system. Appropriate supervision strategies
    // should be configured for these types of actors.
    internal func _spawnSystemActor<Message>(_ naming: ActorNaming, _ behavior: Behavior<Message>, props: Props = Props(), perpetual: Bool = false) throws -> ActorRef<Message> {
        return try self._spawn(using: self.systemProvider, behavior, name: naming, props: props, isWellKnown: perpetual)
    }

    /// Initializes a system actor and enqueues the `.start` message in the mailbox, but does not schedule
    /// the actor. The actor must be manually scheduled later by calling `wakeUp` on the returned `LazyStart`.
    ///
    /// Delaying the start of an actor is necessary when creating actors from within `ActorSystem.init`
    /// to prevent them from running before the system has been fully initialized, which could lead to accessing
    /// uninitialized fields and cause system crashes.
    ///
    /// Otherwise this function behaves the same as `_spawnSystemActor`.
    ///
    /// **CAUTION** This methods MUST NOT be used from outside of `ActorSystem.init`.
    internal func _prepareSystemActor<Message>(_ naming: ActorNaming, _ behavior: Behavior<Message>, props: Props = Props(), perpetual: Bool = false) throws -> LazyStart<Message> {
        let ref = try self._spawn(using: self.systemProvider, behavior, name: naming, props: props, isWellKnown: perpetual, startImmediately: false)

        return LazyStart(ref: ref)
    }

    // Actual spawn implementation, minus the leading "$" check on names;
    internal func _spawn<Message>(using provider: _ActorRefProvider, _ behavior: Behavior<Message>, name naming: ActorNaming, props: Props = Props(), isWellKnown: Bool = false, startImmediately: Bool = true) throws -> ActorRef<Message> {
        try behavior.validateAsInitial()

        let incarnation: ActorIncarnation = isWellKnown ? .perpetual : .random()

        // TODO: lock inside provider, not here
        // FIXME: protect the naming context access and name reservation; add a test
        let address: ActorAddress = try self.withNamingContext { namingContext in
            let name = naming.makeName(&namingContext)

            return try provider.rootAddress.makeChildAddress(name: name, incarnation: incarnation)
            // FIXME: reserve the name, atomically
            // provider.reserveName(name) -> ActorAddress
        }

        let dispatcher: MessageDispatcher
        switch props.dispatcher {
        case .default:
            dispatcher = self.dispatcher
        case .callingThread:
            dispatcher = CallingThreadDispatcher()
        case .nio(let group):
            dispatcher = NIOEventLoopGroupDispatcher(group)
        default:
            fatalError("selected dispacher [\(props.dispatcher)] not implemented yet; ") // FIXME: remove any not implemented ones simply from API
        }

        return try provider.spawn(
            system: self,
            behavior: behavior, address: address,
            dispatcher: dispatcher, props: props,
            startImmediately: startImmediately
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Beginnings of 'system time'

extension ActorSystem {
    /// Returns `Deadline` set `timeAmount` away from the systems current `now` time.
    // TODO: Programmatic timers are not yet implemented, but would be in use here to offer and set the "now"
    func deadline(fromNow timeAmount: TimeAmount) -> Deadline {
        let now = Deadline.now() // TODO: allow programmatic timers
        return now + timeAmount
    }

    // func progressTimeBy(_ timeAmount: TimeAmount) // TODO: Implement
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal actor tree traversal utilities

extension ActorSystem: _ActorTreeTraversable {
    /// Prints Actor hierarchy as a "tree".
    ///
    /// Note that the printout is NOT a "snapshot" of a systems state, and therefore may print actors which by the time
    /// the print completes already have terminated, or may not print actors which started just after a visit at certain parent.
    internal func _printTree() {
        self._traverseAllVoid { context, ref in
            print("\(String(repeating: "  ", count: context.depth))- /\(ref.address.name) - \(ref)")
            return .continue
        }
    }

    @usableFromInline
    internal func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        let systemTraversed: TraversalResult<T> = self.systemProvider._traverse(context: context, visit)

        switch systemTraversed {
        case .completed:
            return self.userProvider._traverse(context: context, visit)

        case .result(let t):
            var c = context
            c.accumulated.append(t)
            return self.userProvider._traverse(context: c, visit)
        case .results(let ts):
            var c = context
            c.accumulated.append(contentsOf: ts)
            return self.userProvider._traverse(context: c, visit)

        case .failed(let err):
            return .failed(err) // short circuit
        }
    }

    internal func _traverseAll<T>(_ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        let context = TraversalContext<T>()
        return self._traverse(context: context, visit)
    }

    @discardableResult
    internal func _traverseAllVoid(_ visit: (TraversalContext<Void>, AddressableActorRef) -> TraversalDirective<Void>) -> TraversalResult<Void> {
        return self._traverseAll(visit)
    }

    @usableFromInline
    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters
        }

        switch selector.value {
        case "system": return self.systemProvider._resolve(context: context)
        case "user": return self.userProvider._resolve(context: context)
        case "dead": return context.personalDeadLetters
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }

    @usableFromInline
    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters.asAddressable()
        }
        switch selector.value {
        case "system": return self.systemProvider._resolveUntyped(context: context)
        case "user": return self.userProvider._resolveUntyped(context: context)
        case "dead": return context.personalDeadLetters.asAddressable()
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }
}

public enum ActorSystemError: Error {
    case shuttingDown(String)
}

/// Represents an actor that has been initialized, but not yet scheduled to run. Calling `wakeUp` will
/// cause the actor to be scheduled.
///
/// **CAUTION** Not calling `wakeUp` will prevent the actor from ever running
/// and can cause leaks. Also `wakeUp` MUST NOT be called more than once,
/// as that would violate the single-threaded execution guaranteed of actors.
internal struct LazyStart<Message> {
    let ref: ActorRef<Message>

    init(ref: ActorRef<Message>) {
        self.ref = ref
    }

    func wakeUp() {
        self.ref._unsafeUnwrapCell.mailbox.schedule()
    }
}