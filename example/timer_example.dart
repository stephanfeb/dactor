import 'package:dactor/dactor.dart';

/// Example demonstrating session timeout functionality
class SessionActor extends Actor {
  @override
  void preStart() {
    print('Session started - setting 10 second timeout');
    _scheduleTimeout();
  }

  void _scheduleTimeout() {
    context.timers.startSingleTimer(
      'session-timeout',
      'timeout',
      Duration(seconds: 10),
    );
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'activity':
        print('User activity detected - resetting timeout');
        _scheduleTimeout(); // Reset the timeout
        break;
      case 'timeout':
        print('Session expired due to inactivity');
        context.system.stop(context.self);
        break;
    }
  }

  @override
  void postStop() {
    print('Session actor stopped');
  }
}

/// Example demonstrating heartbeat functionality
class HeartbeatActor extends Actor {
  int _heartbeatCount = 0;

  @override
  void preStart() {
    print('Starting heartbeat every 2 seconds');
    context.timers.startTimerWithFixedDelay(
      'heartbeat',
      'beat',
      Duration(seconds: 2),
    );
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'beat') {
      _heartbeatCount++;
      print('❤️ Heartbeat #$_heartbeatCount');
      
      if (_heartbeatCount >= 5) {
        print('Stopping heartbeat after 5 beats');
        context.timers.cancel('heartbeat');
        context.system.stop(context.self);
      }
    }
  }

  @override
  void postStop() {
    print('Heartbeat actor stopped');
  }
}

/// Example demonstrating metrics collection at fixed rate
class MetricsActor extends Actor {
  int _metricsCollected = 0;

  @override
  void preStart() {
    print('Starting metrics collection every 1.5 seconds');
    context.timers.startTimerAtFixedRate(
      'collect-metrics',
      'collect',
      Duration(milliseconds: 1500),
    );
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'collect') {
      _metricsCollected++;
      final fakeMetric = 100 + (_metricsCollected * 10);
      print('📊 Collected metrics #$_metricsCollected: CPU=$fakeMetric%');
      
      if (_metricsCollected >= 4) {
        print('Stopping metrics collection after 4 collections');
        context.timers.cancelAll();
        context.system.stop(context.self);
      }
    }
  }

  @override
  void postStop() {
    print('Metrics actor stopped');
  }
}

/// Example demonstrating multiple timer management
class MultiTimerActor extends Actor {
  @override
  void preStart() {
    print('Starting multiple timers...');
    
    // Single shot timer
    context.timers.startSingleTimer(
      'reminder',
      'reminder-message',
      Duration(seconds: 3),
    );
    
    // Fixed delay timer
    context.timers.startTimerWithFixedDelay(
      'periodic-task',
      'periodic',
      Duration(seconds: 1),
    );
    
    // Auto-stop after 8 seconds
    context.timers.startSingleTimer(
      'auto-stop',
      'stop',
      Duration(seconds: 8),
    );
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'reminder-message':
        print('⏰ Reminder: Don\'t forget to check the logs!');
        break;
      case 'periodic':
        print('🔄 Periodic task executed');
        break;
      case 'stop':
        print('🛑 Auto-stop triggered');
        context.timers.cancelAll();
        context.system.stop(context.self);
        break;
    }
  }

  @override
  void postStop() {
    final activeTimers = context.timers.activeTimers;
    print('Multi-timer actor stopped. Had ${activeTimers.length} active timers');
  }
}

void main() async {
  final system = LocalActorSystem();

  print('=== Dactor Timer Examples ===\n');

  // Example 1: Session timeout
  print('1. Session Timeout Example:');
  final sessionActor = await system.spawn('session', () => SessionActor());
  
  // Simulate user activity
  await Future.delayed(Duration(seconds: 3));
  sessionActor.tell(LocalMessage(payload: 'activity'));
  
  await Future.delayed(Duration(seconds: 5));
  sessionActor.tell(LocalMessage(payload: 'activity'));
  
  // Let it timeout naturally after this
  await Future.delayed(Duration(seconds: 12));
  
  print('\n2. Heartbeat Example:');
  final heartbeatActor = await system.spawn('heartbeat', () => HeartbeatActor());
  await Future.delayed(Duration(seconds: 12));
  
  print('\n3. Metrics Collection Example:');
  final metricsActor = await system.spawn('metrics', () => MetricsActor());
  await Future.delayed(Duration(seconds: 8));
  
  print('\n4. Multiple Timers Example:');
  final multiActor = await system.spawn('multi', () => MultiTimerActor());
  await Future.delayed(Duration(seconds: 10));

  print('\n=== Shutting down system ===');
  await system.shutdown();
  print('All examples completed!');
} 