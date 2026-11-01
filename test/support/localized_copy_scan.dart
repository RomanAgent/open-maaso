import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Parses expressions rather than exempting files or matching Chinese inside
/// comments. A locale choice must be traceable to an actual locale selector;
/// a helper must return its two different language parameters on those branches.
List<String> unlocalizedChineseCopy(Map<String, String> sources) =>
    _LocalizedCopyScan(sources).offenders();

final class _Nodes extends GeneralizingAstVisitor<void> {
  final nodes = <AstNode>[];
  @override
  void visitNode(AstNode node) {
    nodes.add(node);
    super.visitNode(node);
  }
}

final class _LocalizedCopyScan {
  _LocalizedCopyScan(Map<String, String> sources) {
    for (final entry in sources.entries) {
      final parsed = parseString(
        content: entry.value,
        path: entry.key,
        throwIfDiagnostics: false,
      );
      final collector = _Nodes();
      parsed.unit.accept(collector);
      _units[entry.key] = parsed.unit;
      for (final node in collector.nodes) {
        _paths[node] = entry.key;
        final bindingName = switch (node) {
          VariableDeclaration() => node.name.lexeme,
          MethodDeclaration() when node.isGetter => node.name.lexeme,
          FormalParameter() => node.name?.lexeme,
          _ => null,
        };
        if (bindingName != null) {
          (_bindings['${entry.key}:$bindingName'] ??= []).add(node);
        }
        final helperName = switch (node) {
          MethodDeclaration() => node.name.lexeme,
          FunctionDeclaration() => node.name.lexeme,
          ClassDeclaration() => node.namePart.typeName.lexeme,
          _ => null,
        };
        if (helperName != null) (_helpers[helperName] ??= []).add(node);
      }
      _nodes.addAll(collector.nodes);
    }
    // Constructor/function locale inputs can be forwarded through several
    // widgets. Bound propagation; an unresolved input remains an offender.
    for (var pass = 0; pass < 8; pass++) {
      final before = _localeInputs.length;
      _propagateLocaleInputs();
      if (before == _localeInputs.length) break;
    }
  }

  static final _chinese = RegExp(r'[\u3400-\u9fff]');
  final _units = <String, CompilationUnit>{};
  final _paths = <AstNode, String>{};
  final _nodes = <AstNode>[];
  final _bindings = <String, List<AstNode>>{};
  final _helpers = <String, List<AstNode>>{};
  final _localeInputs = <(AstNode, String), bool>{};

  List<String> offenders() {
    final result = <String>[];
    for (final node in _nodes) {
      final String? value = switch (node) {
        SimpleStringLiteral() => node.value,
        InterpolationString() => node.value,
        _ => null,
      };
      if (value == null || !_chinese.hasMatch(value)) continue;
      if (_localized(node) || _directStringMatchingInput(node)) continue;
      final path = _paths[node]!;
      final line = _units[path]!.lineInfo.getLocation(node.offset).lineNumber;
      result.add('$path:$line: $value');
    }
    return result;
  }

  // Multilingual search terms consumed directly by String.contains produce
  // only a boolean. They are not display copy; a field reused by Text remains
  // subject to the normal localized-copy checks.
  bool _directStringMatchingInput(AstNode node) {
    AstNode target = node;
    while (target.parent is ParenthesizedExpression ||
        target.parent is ConditionalExpression ||
        target.parent is StringInterpolation) {
      target = target.parent!;
    }
    final call = target.parent;
    return call is MethodInvocation &&
        identical(call.target, target) &&
        call.methodName.name == 'contains';
  }

  bool _localized(AstNode node) {
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is ConditionalExpression) {
        final polarity = _localePolarity(parent.condition, parent, {});
        if (polarity == null) continue;
        final chineseBranch = polarity
            ? parent.thenExpression
            : parent.elseExpression;
        final englishBranch = polarity
            ? parent.elseExpression
            : parent.thenExpression;
        if (!_inside(node, chineseBranch)) continue;
        if (_containsLanguage(chineseBranch, chinese: true) &&
            _containsLanguage(englishBranch, chinese: false)) {
          return true;
        }
      }
      if (parent is ArgumentList) {
        final helper = _bilingualHelper(parent.parent);
        if (helper != null &&
            parent.arguments.length > helper.$2 &&
            (_inside(node, parent.arguments[helper.$1]) ||
                _inside(node, parent.arguments[helper.$2])) &&
            _containsLanguage(parent.arguments[helper.$1], chinese: true) &&
            _containsLanguage(parent.arguments[helper.$2], chinese: false)) {
          return true;
        }
      }
      if (parent is RecordLiteral && _localizedRecord(parent)) return true;
      if ((parent is MethodDeclaration || parent is FunctionDeclaration) &&
          _chineseOnlyHelper(parent)) {
        return true;
      }
    }
    return false;
  }

  bool _inside(AstNode child, AstNode parent) =>
      child.offset >= parent.offset && child.end <= parent.end;

  bool _containsLanguage(Expression expression, {required bool chinese}) {
    final collector = _Nodes();
    expression.accept(collector);
    final values = collector.nodes
        .map(
          (node) => switch (node) {
            SimpleStringLiteral() => node.value,
            InterpolationString() => node.value,
            _ => '',
          },
        )
        .join();
    // A bilingual input example deliberately keeps the person's sample name
    // "小林" in both languages. This does not exempt a raw Chinese UI string.
    final englishValues = values.replaceAll('小林', '');
    return chinese
        ? _chinese.hasMatch(values)
        : RegExp(r'[A-Za-z]{2,}').hasMatch(englishValues) &&
              !_chinese.hasMatch(englishValues);
  }

  String? _callName(AstNode? node) => switch (node) {
    MethodInvocation() => node.methodName.name,
    InstanceCreationExpression() => node.constructorName.type.name.lexeme,
    _ => null,
  };

  AstNode? _scope(AstNode node) {
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is Block ||
          parent is FunctionExpression ||
          parent is MethodDeclaration ||
          parent is ClassDeclaration ||
          parent is CompilationUnit) {
        return parent;
      }
    }
    return null;
  }

  AstNode? _binding(String name, AstNode use) {
    final path = _paths[use];
    final candidates = (_bindings['$path:$name'] ?? []).where((node) {
      final scope = _scope(node);
      if (scope == null || !_inside(use, scope)) return false;
      if (node is VariableDeclaration &&
          node.parent?.parent is! FieldDeclaration &&
          node.offset > use.offset) {
        return false;
      }
      return true;
    }).toList();
    candidates.sort(
      (a, b) => (_scope(a)?.length ?? 0).compareTo(_scope(b)?.length ?? 0),
    );
    return candidates.isEmpty ? null : candidates.first;
  }

  Expression? _expression(AstNode? node) => switch (node) {
    VariableDeclaration() => node.initializer,
    MethodDeclaration(body: ExpressionFunctionBody()) =>
      (node.body as ExpressionFunctionBody).expression,
    _ => null,
  };

  bool? _localePolarity(Expression expression, AstNode use, Set<AstNode> seen) {
    if (expression is ParenthesizedExpression) {
      return _localePolarity(expression.expression, use, seen);
    }
    if (expression is PrefixExpression && expression.operator.lexeme == '!') {
      final value = _localePolarity(expression.operand, use, seen);
      return value == null ? null : !value;
    }
    if (expression is BinaryExpression) {
      final operator = expression.operator.lexeme;
      final lhs = expression.leftOperand.toSource();
      final rhs = expression.rightOperand.toSource();
      if (const {'==', '!='}.contains(operator) &&
          ((rhs == "'zh'" || rhs == '"zh"') &&
                  lhs.contains('Localizations.localeOf(') &&
                  lhs.endsWith('.languageCode') ||
              rhs == 'AppLocale.zh')) {
        return operator == '==';
      }
      if (operator == '??') {
        final right = _localePolarity(expression.rightOperand, use, {...seen});
        if (expression.leftOperand is NullLiteral) return right;
        final left = _localePolarity(expression.leftOperand, use, {...seen});
        return left != null && left == right ? left : null;
      }
    }
    if (expression is SimpleIdentifier) {
      final binding = _binding(expression.name, use);
      if (binding == null || !seen.add(binding)) return null;
      final value = _expression(binding);
      if (value != null) {
        if (binding is VariableDeclaration &&
            binding.parent is VariableDeclarationList &&
            !const {'final', 'const'}.contains(
              (binding.parent as VariableDeclarationList).keyword?.lexeme,
            )) {
          return null;
        }
        return _localePolarity(value, binding, seen);
      }
      if (binding is FormalParameter) {
        final owner = _parameterOwner(binding);
        return owner == null ? null : _localeInputs[(owner, expression.name)];
      }
      if (binding is VariableDeclaration &&
          binding.parent?.parent is FieldDeclaration) {
        final owner = _classOf(binding);
        return owner == null ? null : _localeInputs[(owner, expression.name)];
      }
    }
    final raw = expression.toSource();
    if (raw == 'widget.zh' || raw == 'widget.chinese') {
      final state = _classOf(use);
      final type =
          state?.extendsClause?.superclass.typeArguments?.arguments.firstOrNull;
      final owner = type is NamedType
          ? _visibleDeclaration(type.name.lexeme, use, classesOnly: true)
          : null;
      return owner == null ? null : _localeInputs[(owner, raw.split('.').last)];
    }
    return null;
  }

  ClassDeclaration? _classOf(AstNode node) {
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is ClassDeclaration) return parent;
    }
    return null;
  }

  AstNode? _parameterOwner(FormalParameter parameter) {
    for (
      AstNode? parent = parameter.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is FunctionDeclaration) return parent;
      if (parent is ConstructorDeclaration) return _classOf(parent);
      if (parent is MethodDeclaration) return parent;
    }
    return null;
  }

  Set<String> _visibleFiles(AstNode use) {
    final path = _paths[use]!;
    return {
      path,
      for (final directive
          in _units[path]!.directives.whereType<ImportDirective>())
        if (directive.uri.stringValue case final uri?)
          uri.startsWith('package:maaso/')
              ? 'lib/${uri.substring('package:maaso/'.length)}'
              : Uri.parse(path).resolve(uri).path,
    };
  }

  AstNode? _visibleDeclaration(
    String name,
    AstNode use, {
    bool classesOnly = false,
  }) {
    final files = _visibleFiles(use);
    final candidates =
        (_helpers[name] ?? []).where((declaration) {
          if (!files.contains(_paths[declaration])) return false;
          if (name.startsWith('_') && _paths[declaration] != _paths[use]) {
            return false;
          }
          if (classesOnly) return declaration is ClassDeclaration;
          if (declaration is MethodDeclaration) {
            return identical(_classOf(declaration), _classOf(use));
          }
          if (declaration is FunctionDeclaration &&
              _paths[declaration] == _paths[use]) {
            final scope = _scope(declaration);
            return scope != null && _inside(use, scope);
          }
          return declaration is ClassDeclaration ||
              declaration is FunctionDeclaration;
        }).toList()..sort((a, b) {
          final ownA = _paths[a] == _paths[use],
              ownB = _paths[b] == _paths[use];
          if (ownA != ownB) return ownA ? -1 : 1;
          return (_scope(a)?.length ?? 0).compareTo(_scope(b)?.length ?? 0);
        });
    return candidates.isEmpty ? null : candidates.first;
  }

  AstNode? _callDeclaration(AstNode? call) {
    if (call == null) return null;
    if (call is MethodInvocation &&
        call.target != null &&
        call.target is! ThisExpression) {
      return null;
    }
    final name = _callName(call);
    return name == null
        ? null
        : _visibleDeclaration(
            name,
            call,
            classesOnly: call is InstanceCreationExpression,
          );
  }

  FormalParameterList? _parameters(AstNode declaration) =>
      switch (declaration) {
        MethodDeclaration() => declaration.parameters,
        FunctionDeclaration() => declaration.functionExpression.parameters,
        ClassDeclaration() =>
          declaration.body.members
              .whereType<ConstructorDeclaration>()
              .firstOrNull
              ?.parameters,
        _ => null,
      };

  void _propagateLocaleInputs() {
    final callGroups = <AstNode, List<ArgumentList>>{};
    for (final arguments in _nodes.whereType<ArgumentList>()) {
      final target = _callDeclaration(arguments.parent);
      if (target != null) (callGroups[target] ??= []).add(arguments);
    }
    for (final entry in callGroups.entries) {
      final parameters = _parameters(entry.key);
      if (parameters == null) continue;
      final positional = parameters.parameters
          .where((p) => !p.isNamed)
          .toList();
      for (final parameter in parameters.parameters) {
        final name = parameter.name?.lexeme;
        if (!const {'zh', 'chinese'}.contains(name)) continue;
        bool? polarity;
        var valid = true, supplied = false;
        for (final arguments in entry.value) {
          Expression? value;
          if (parameter.isNamed) {
            value = arguments.arguments
                .whereType<NamedExpression>()
                .where((arg) => arg.name.label.name == name)
                .firstOrNull
                ?.expression;
          } else {
            final index = positional.indexOf(parameter);
            if (index < arguments.arguments.length) {
              value = arguments.arguments[index];
            }
          }
          if (value == null) {
            continue; // An omitted nullable override uses the locale fallback.
          }
          supplied = true;
          final observed = _localePolarity(value, arguments, {});
          if (observed == null || polarity != null && polarity != observed) {
            valid = false;
            break;
          }
          polarity = observed;
        }
        if (valid && supplied && polarity != null) {
          _localeInputs[(entry.key, name!)] = polarity;
        }
      }
    }
  }

  (int, int)? _bilingualHelper(AstNode? call) {
    final declaration = _callDeclaration(call);
    if (declaration == null) return null;
    final body = switch (declaration) {
      MethodDeclaration() => declaration.body,
      FunctionDeclaration() => declaration.functionExpression.body,
      _ => null,
    };
    final parameters = _parameters(declaration);
    if (parameters == null || body is! ExpressionFunctionBody) return null;
    final expression = body.expression;
    if (expression is! ConditionalExpression) return null;
    final polarity = _localePolarity(expression.condition, declaration, {});
    if (polarity == null) return null;
    final chosen = polarity
        ? expression.thenExpression
        : expression.elseExpression;
    final alternate = polarity
        ? expression.elseExpression
        : expression.thenExpression;
    if (chosen is! SimpleIdentifier ||
        alternate is! SimpleIdentifier ||
        chosen.name == alternate.name) {
      return null;
    }
    final names = parameters.parameters.map((p) => p.name?.lexeme).toList();
    final chineseIndex = names.indexOf(chosen.name),
        englishIndex = names.indexOf(alternate.name);
    return chineseIndex < 0 || englishIndex < 0
        ? null
        : (chineseIndex, englishIndex);
  }

  bool _chineseOnlyHelper(AstNode declaration) {
    final name = switch (declaration) {
      MethodDeclaration() => declaration.name.lexeme,
      FunctionDeclaration() => declaration.name.lexeme,
      _ => '',
    };
    if (!name.startsWith('_')) {
      return false;
    }
    final calls = _nodes
        .whereType<MethodInvocation>()
        .where((call) => identical(_callDeclaration(call), declaration))
        .toList();
    if (calls.isEmpty) {
      return false;
    }
    if (_nodes.whereType<MethodInvocation>().any(
      (call) =>
          call.methodName.name == name &&
          _paths[call] == _paths[declaration] &&
          !identical(_callDeclaration(call), declaration),
    )) {
      return false;
    }
    for (final reference in _nodes.whereType<SimpleIdentifier>().where(
      (n) => n.name == name && _paths[n] == _paths[declaration],
    )) {
      if (reference.parent is! MethodInvocation) {
        return false;
      }
    }
    for (final call in calls) {
      var inChinese = false;
      for (
        AstNode? parent = call.parent;
        parent != null;
        parent = parent.parent
      ) {
        if (parent is ArgumentList) {
          final helper = _bilingualHelper(parent.parent);
          if (helper != null &&
              parent.arguments.length > helper.$2 &&
              _inside(call, parent.arguments[helper.$1]) &&
              _containsLanguage(parent.arguments[helper.$2], chinese: false)) {
            inChinese = true;
            break;
          }
        }
        if (parent is ConditionalExpression) {
          final polarity = _localePolarity(parent.condition, parent, {});
          if (polarity != null &&
              _inside(
                call,
                polarity ? parent.thenExpression : parent.elseExpression,
              )) {
            inChinese = true;
            break;
          }
        }
      }
      if (!inChinese) {
        return false;
      }
    }
    return true;
  }

  bool _localizedRecord(RecordLiteral record) {
    if (record.fields.length != 2 ||
        !_containsLanguage(record.fields[0], chinese: true) ||
        !_containsLanguage(record.fields[1], chinese: false)) {
      return false;
    }
    // Only records consumed by a verified locale helper are translated data.
    for (final call in _nodes.whereType<MethodInvocation>()) {
      if (_paths[call] != _paths[record]) {
        continue;
      }
      final helper = _bilingualHelper(call);
      if (helper == null || call.argumentList.arguments.length <= helper.$2) {
        continue;
      }
      final first = call.argumentList.arguments[helper.$1].toSource();
      final second = call.argumentList.arguments[helper.$2].toSource();
      if (!first.endsWith('.\$1') ||
          !second.endsWith('.\$2') ||
          first.substring(0, first.length - 3) !=
              second.substring(0, second.length - 3)) {
        continue;
      }
      final pair = _binding(first.substring(0, first.length - 3), call);
      var value = _expression(pair);
      if (value is PostfixExpression && value.operator.lexeme == '!') {
        value = value.operand;
      }
      if (value is! IndexExpression) {
        continue;
      }
      final target = value.target;
      if (target is! SimpleIdentifier) {
        continue;
      }
      final container = _expression(_binding(target.name, call));
      if (container != null && _inside(record, container)) {
        return true;
      }
    }
    return false;
  }
}
