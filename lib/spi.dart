/// For code that carries messages between actors without being an actor:
/// transports, bridges and test doubles. Application code does not need it.
///
/// An `ActorRef.tell` takes no sender. The runtime stamps the actor whose
/// code is running, so an actor cannot claim to be another. A transport
/// that delivers a message from elsewhere says who it came from with
/// [sendAs], and one that reports an ending to a watcher uses [tellSystem],
/// because a `Terminated` or `ExitSignal` told in the ordinary way is
/// dropped.
///
/// An `ActorRef` written outside this package reads [currentSender] at the
/// start of its `tell`, before anything asynchronous, to learn who is
/// sending.
library dactor.spi;

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/sending.dart';

/// Who is sending the message being told right now: the actor whose code
/// is running, the sender given to [sendAs], or null.
ActorRef? get currentSender => Sending.sender;

/// Whether the message being told right now comes from the runtime, through
/// [tellSystem].
bool get isSystemDelivery => Sending.isSystem;

/// Runs [send] with [sender] as the sender of everything it tells. Only the
/// synchronous part of [send] counts.
R sendAs<R>(ActorRef? sender, R Function() send) => Sending.as(sender, send);

/// Tells [target] a runtime message, a `Terminated` or an `ExitSignal`,
/// with no sender.
void tellSystem(ActorRef target, Object message) =>
    Sending.system(target, message);
