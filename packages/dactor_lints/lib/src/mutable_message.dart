import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import 'dactor_code.dart';

/// Messages must not be changed after they are sent.
///
/// Actors in one isolate share a heap. A message with a field that can be
/// reassigned lets the sender change what the receiver is looking at, or the
/// other way round, which is exactly the shared mutable state the actor model
/// exists to rule out.
///
/// Reported in two places: on each non-final field of a class that extends
/// dactor's deprecated `LocalMessage`, and where an object of any other
/// class with a non-final field is sent or published as an event.
class MutableMessage extends AnalysisRule {
  static const LintCode code = LintCode(
    'dactor_mutable_message',
    "'{0}' is sent between actors, but its field '{1}' can be reassigned.",
    correctionMessage:
        "Make '{1}' final, or send an immutable copy of the data.",
    severity: DiagnosticSeverity.WARNING,
  );

  MutableMessage()
    : super(
        name: 'dactor_mutable_message',
        description:
            'Objects sent between actors must not have reassignable fields.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _Visitor(this);
    registry.addClassDeclaration(this, visitor);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addMethodInvocation(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  final MutableMessage rule;
  _Visitor(this.rule);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element == null ||
        isFromDactor(element) ||
        !isDactorSubtype(element, 'LocalMessage')) {
      return;
    }
    for (final field in mutableFields(element)) {
      final fragment = field.firstFragment;
      final name = field.name;
      final offset = fragment.nameOffset;
      if (name == null || offset == null) continue;
      rule.reportAtOffset(
        offset,
        name.length,
        arguments: [element.name ?? 'This class', name],
      );
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) =>
      _check(node);

  @override
  void visitMethodInvocation(MethodInvocation node) => _check(node);

  void _check(AstNode node) {
    for (final sent in sentExpressions(node)) {
      final type = sent.staticType;
      if (type is! InterfaceType) continue;
      final element = type.element;
      // LocalMessage classes are reported where they are declared, and an actor
      // sending itself is dactor_captured_actor_state's finding.
      if (isFromSdk(element) ||
          isFromDactor(element) ||
          isDactorSubtype(element, 'LocalMessage') ||
          isDactorSubtype(element, 'Actor')) {
        continue;
      }
      final field = _firstMutableField(element);
      if (field != null) {
        rule.reportAtNode(
          sent,
          arguments: [element.name ?? 'This object', field.name ?? ''],
        );
      }
    }
  }

  /// The first reassignable field of [element] or of a class it inherits
  /// from, leaving out the SDK's own classes.
  FieldElement? _firstMutableField(InterfaceElement element) {
    for (final candidate in [
      element,
      for (final type in element.allSupertypes)
        if (!isFromSdk(type.element)) type.element,
    ]) {
      final fields = mutableFields(candidate);
      if (fields.isNotEmpty) return fields.first;
    }
    return null;
  }
}
