import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

/// Whether [element] is the class called [name] that package:dactor declares.
bool isDactorClass(InterfaceElement element, String name) =>
    element.name == name && isFromDactor(element);

bool isFromDactor(Element element) {
  final uri = element.library?.uri;
  return uri != null &&
      uri.scheme == 'package' &&
      uri.path.startsWith('dactor/');
}

bool isFromSdk(Element element) => element.library?.uri.scheme == 'dart';

/// Whether [element] is, extends, implements or mixes in dactor's [name].
bool isDactorSubtype(InterfaceElement element, String name) =>
    isDactorClass(element, name) ||
    element.allSupertypes.any((type) => isDactorClass(type.element, name));

/// The fields declared in [element] that can be reassigned.
Iterable<FieldElement> mutableFields(InterfaceElement element) =>
    element.fields.where(
      (field) =>
          !field.isStatic &&
          !field.isFinal &&
          !field.isConst &&
          (field.isOriginDeclaration || field.isOriginDeclaringFormalParameter),
    );

/// The class [node] is written in, if that class is an actor.
InterfaceElement? enclosingActor(AstNode node) {
  final element = node
      .thisOrAncestorOfType<ClassDeclaration>()
      ?.declaredFragment
      ?.element;
  return element != null && isDactorSubtype(element, 'Actor') ? element : null;
}

/// If [node] sends something to another actor, the expressions being sent:
/// the message given to `tell`, `ask`, `forward` or a `TypedRef`'s `call`,
/// the event given to `publish`, or the `payload:` of a deprecated
/// `LocalMessage`.
Iterable<Expression> sentExpressions(AstNode node) sync* {
  if (node is InstanceCreationExpression) {
    final type = node.staticType;
    if (type is InterfaceType &&
        isDactorSubtype(type.element, 'LocalMessage')) {
      for (final argument in node.argumentList.arguments) {
        if (argument.correspondingParameter?.name == 'payload') {
          yield argument.argumentExpression;
        }
      }
    }
  } else if (node is MethodInvocation &&
      _sendsTo.containsKey(node.methodName.name)) {
    final owner = node.methodName.element?.enclosingElement;
    final arguments = node.argumentList.arguments;
    final at = _sendsTo[node.methodName.name]!;
    if (owner is InterfaceElement &&
        arguments.length > at &&
        _owners[node.methodName.name]!.any(
          (name) => isDactorSubtype(owner, name),
        )) {
      yield arguments[at].argumentExpression;
    }
  } else if (node is MethodInvocation && node.methodName.name == 'publish') {
    final owner = node.methodName.element?.enclosingElement;
    if (owner is InterfaceElement &&
        (isDactorSubtype(owner, 'ActorContext') ||
            isDactorSubtype(owner, 'EventBus'))) {
      final arguments = node.argumentList.arguments;
      if (arguments.isNotEmpty) {
        yield arguments.first.argumentExpression;
      }
    }
  }
}

/// The methods that send, and which argument is the message.
const _sendsTo = {'tell': 0, 'ask': 0, 'call': 0, 'forward': 1};

/// The dactor types each of those methods sends from.
const _owners = {
  'tell': ['ActorRef', 'TypedRef'],
  'ask': ['ActorRef'],
  'call': ['TypedRef'],
  'forward': ['ActorContext'],
};
