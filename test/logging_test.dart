import 'package:dactor/dactor.dart';
import 'package:dactor/src/logging/logging.dart';
import 'package:dactor/src/message.dart';
import 'package:test/test.dart';

class StringMessage implements Message {
  final String message;

  StringMessage(this.message);

  @override
  String get correlationId => 'test';

  @override
  Map<String, dynamic> get metadata => {};

  @override
  ActorRef? get replyTo => null;

  @override
  DateTime get timestamp => DateTime.now();

  @override
  String toString() => message;
}

class _TestLogCollector implements LogCollector {
  final List<LogRecord> records = [];

  @override
  void record(LogRecord record) {
    records.add(record);
  }
}

class _TestActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    context.system.logger
        .record(LogRecord(LogLevel.info, message.toString()));
  }
}

void main() {
  group('Logging', () {
    late ActorSystem system;
    late _TestLogCollector logCollector;

    setUp(() {
      logCollector = _TestLogCollector();
      system = ActorSystem.create(
          ActorSystemConfig(logCollector: logCollector));
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should log messages from actors', () async {
      final actor = await system.spawn('test', () => _TestActor());
      actor.tell(StringMessage('hello'));
      await Future.delayed(const Duration(milliseconds: 100));
      expect(logCollector.records.length, 1);
      expect(logCollector.records.first.message, 'hello');
      expect(logCollector.records.first.level, LogLevel.info);
    });
  });
}
