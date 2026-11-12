import 'package:meta/meta.dart';

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/actor_zone.dart';

/// Who is sending, worked out by the runtime and never by the caller.
///
/// An [ActorRef.tell] stamps [sender] on what it delivers: the actor whose
/// code is running, or null outside any actor. [as] and [system] override
/// that for the length of one synchronous call, for `forward`, `ask` and
/// transports.
@internal
abstract final class Sending {
  static bool _overriding = false;
  static ActorRef? _sender;
  static bool _system = false;

  /// The sender of a message told right now.
  static ActorRef? get sender =>
      _overriding ? _sender : TombstoneZone.currentSelf;

  /// Whether the message told right now comes from the runtime.
  static bool get isSystem => _system;

  /// Runs [send] with [sender] as the sender of what it tells. Only the
  /// synchronous part of [send] counts.
  static R as<R>(ActorRef? sender, R Function() send) {
    final wasOverriding = _overriding;
    final was = _sender;
    final wasSystem = _system;
    _overriding = true;
    _sender = sender;
    _system = false;
    try {
      return send();
    } finally {
      _overriding = wasOverriding;
      _sender = was;
      _system = wasSystem;
    }
  }

  /// Tells [target] the runtime message [message], such as a `Terminated`
  /// or an `ExitSignal`, with no sender.
  static void system(ActorRef target, Object message) {
    as(null, () {
      _system = true;
      target.tell(message);
    });
  }
}
