import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/captured_actor_state.dart';
import 'src/mutable_message.dart';

/// The entry point the analysis server looks for.
final plugin = DactorLintsPlugin();

class DactorLintsPlugin extends Plugin {
  @override
  String get name => 'dactor_lints';

  @override
  void register(PluginRegistry registry) {
    registry.registerWarningRule(MutableMessage());
    registry.registerWarningRule(CapturedActorState());
  }
}
