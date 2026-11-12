import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import 'dactor_code.dart';

/// An actor must not hand out a way into its own state.
///
/// A closure created inside an actor can read and write that actor's fields.
/// Sent in a message, it runs in the receiver's turn, so two actors end up
/// touching the same state at once. Sending the actor object itself has the
/// same effect. Send data, or the actor's `ActorRef`, instead.
class CapturedActorState extends AnalysisRule {
  static const LintCode code = LintCode(
    'dactor_captured_actor_state',
    'This message carries {0}, which gives the receiver direct access to '
        "the sending actor's state.",
    correctionMessage:
        "Send the data itself, or 'context.self' if the receiver needs to "
        'reply.',
    severity: DiagnosticSeverity.WARNING,
  );

  CapturedActorState()
    : super(
        name: 'dactor_captured_actor_state',
        description: 'Actors must not send closures or themselves in messages.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _Visitor(this);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addMethodInvocation(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  final CapturedActorState rule;
  _Visitor(this.rule);

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) =>
      _check(node);

  @override
  void visitMethodInvocation(MethodInvocation node) => _check(node);

  void _check(AstNode node) {
    if (enclosingActor(node) == null) return;
    for (final sent in sentExpressions(node)) {
      sent.accept(_Finder(rule));
    }
  }
}

/// Reports every closure and every `this` inside a sent expression.
class _Finder extends RecursiveAstVisitor<void> {
  final CapturedActorState rule;
  _Finder(this.rule);

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Not descending: one report per closure is enough.
    rule.reportAtNode(node, arguments: ['a closure']);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    rule.reportAtNode(node, arguments: ['the actor itself']);
  }
}
