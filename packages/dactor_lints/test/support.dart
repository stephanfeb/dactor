import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';

/// Just enough of package:dactor for the rules to recognise its types.
const dactorStub = '''
abstract class ActorRef {
  void tell(Object? message);
  Future<T> ask<T>(Object? message, [Duration? timeout]);
}

mixin Call<R> {}

extension type const TypedRef<M>(ActorRef untyped) {
  void tell(M message) => untyped.tell(message);
  Future<R> call<R>(Call<R> request, {Duration? timeout}) =>
      untyped.ask<R>(request, timeout);
}

class LocalMessage {
  final dynamic payload;
  final ActorRef? sender;
  LocalMessage({this.payload, this.sender});
}

class EventBus {
  void publish<T>(T event) {}
}

abstract class ActorContext {
  ActorRef get self;
  ActorRef? get sender;
  void publish<T>(T event) {}
  void forward(ActorRef target, Object? message) {}
}

abstract class Actor {
  late ActorContext context;
  Future<void> onMessage(dynamic message);
}
''';

abstract class DactorRuleTest extends AnalysisRuleTest {
  @override
  void setUp() {
    newPackage('dactor').addFile('lib/dactor.dart', dactorStub);
    super.setUp();
  }

  /// Analyses [marked] and expects exactly one diagnostic on each range
  /// written as `[!...!]`. The markers are removed before analysis.
  Future<void> expectReported(String marked) {
    final ranges = <(int, int)>[];
    final code = StringBuffer();
    var rest = marked;
    while (true) {
      final open = rest.indexOf('[!');
      if (open < 0) break;
      final close = rest.indexOf('!]', open);
      code.write(rest.substring(0, open));
      final range = rest.substring(open + 2, close);
      ranges.add((code.length, range.length));
      code.write(range);
      rest = rest.substring(close + 2);
    }
    code.write(rest);
    if (ranges.isEmpty) {
      throw ArgumentError('no [!...!] range in the test code');
    }
    return assertDiagnostics(code.toString(), [
      for (final (offset, length) in ranges) lint(offset, length),
    ]);
  }
}
