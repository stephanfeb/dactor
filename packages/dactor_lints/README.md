# dactor_lints

An analyzer plugin with lint rules for code that uses [dactor](../../README.md).

Dactor actors in one isolate share a heap. The actor model only holds if messages are data: immutable, and free of references back into the sender. The language does not enforce that, so these rules check for it.

Requires Dart 3.10 or later. Diagnostics appear in `dart analyze` and in the IDE.

## Setup

Add the plugin to the `analysis_options.yaml` of the package you want checked:

```yaml
plugins:
  dactor_lints:
    path: path/to/dactor/packages/dactor_lints
```

Both rules are warnings and are on once the plugin is enabled. To turn one off:

```yaml
plugins:
  dactor_lints:
    path: path/to/dactor/packages/dactor_lints
    diagnostics:
      dactor_mutable_message: false
```

**Known quirk.** With Dart 3.11.5, running `dart analyze` on a whole package with any plugin enabled printed every built-in diagnostic twice (the plugin's own findings appeared once). `dart analyze lib` was not affected. For that reason the plugin is not switched on in dactor's own `analysis_options.yaml`.

A single finding can be silenced with `// ignore: dactor_lints/dactor_mutable_message`.

## Rules

### `dactor_mutable_message`

An object sent between actors has a field that can be reassigned.

```dart
class Cart {
  int items = 0;                              // not final
}

ref.tell(cart);        // reported here
```

Reported in two places:

- where an object of a class with a non-final field, its own or inherited, is sent: given to `tell`, `ask`, `context.forward`, a `TypedRef`'s `tell` or `call`, `publish`, or as the `payload:` of a deprecated `LocalMessage`;
- on each non-final field of a class that extends the deprecated `LocalMessage`.

`final`, `late final`, `const` and `static` fields are fine, as are getters.

What it does not check: the contents of collections (a `final List` can still be mutated), fields whose own type is mutable, and payloads whose static type is `dynamic` or `Object`.

### `dactor_captured_actor_state`

An actor sends a closure, or itself, in a message.

```dart
class Counter extends Actor {
  int count = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    peer.tell(() => count++);   // reported
    context.publish(this);                             // reported
  }
}
```

A closure created inside an actor can read and write that actor's fields, and runs in the receiver's turn. Send the data, or `context.self` if the receiver needs to reply.

Only code inside a class that extends `Actor` is checked, and only closures written inline in the sent expression. A closure stored in a variable first and sent later is not found.

## Developing

```sh
dart pub get
dart test
```

The tests analyse snippets against a stub of dactor's types (`test/support.dart`), so they do not need the real package.
