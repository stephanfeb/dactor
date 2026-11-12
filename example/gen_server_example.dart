import 'package:dactor/dactor.dart';

// The messages the counter accepts. A message that mixes in Call<R> expects
// a reply of type R.
sealed class CounterMsg {}

final class Increment extends CounterMsg {}

final class Get extends CounterMsg with Call<int> {}

// A server whose state is an int and whose messages are CounterMsg.
class Counter extends GenServer<int, CounterMsg> {
  @override
  int init() => 0;

  // Messages that expect no reply: return the new state.
  @override
  int handleCast(CounterMsg message, int state) => switch (message) {
        Increment() => state + 1,
        Get() => state,
      };

  // Requests: reply and return the new state.
  @override
  CallResult<int> handleCall(CounterMsg request, int state, From from) =>
      switch (request) {
        Get() => request.reply(state, state),
        Increment() => NoReply(state),
      };

  @override
  void terminate(int state) => print('Counter stopped at $state');
}

void main() async {
  final system = LocalActorSystem();

  // typed() restricts the reference to the counter's messages.
  final TypedRef<CounterMsg> counter =
      (await system.spawn('counter', () => Counter())).typed();

  counter.tell(Increment());
  counter.tell(Increment());
  // counter.tell('increment');  // does not compile

  final int count = await counter.call(Get());
  print('Current count: $count');

  await system.shutdown();
}
