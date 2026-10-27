import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_svg/svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:paymint/l10n/l10n.dart';
import 'package:paymint/models/isar/stack_theme.dart';
import 'package:paymint/models/node_model.dart';
import 'package:paymint/providers/providers.dart';
import 'package:paymint/services/node_service.dart';
import 'package:paymint/themes/stack_colors.dart';
import 'package:paymint/utilities/test_node_connection.dart';
import 'package:paymint/utilities/util.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/widgets/custom_buttons/blue_text_button.dart';
import 'package:paymint/widgets/node_card.dart';
import 'package:paymint/widgets/node_options_sheet.dart';

import '../sample_data/theme_json.dart';
import 'node_card_test.mocks.dart';
import 'support/platform_test_overrides.dart';

@GenerateMocks([NodeService])
void main() {
  final pivx = Pivx(CryptoCurrencyNetwork.main);

  NodeModel buildNode({required String id, required String name}) {
    return NodeModel(
      host: '127.0.0.1',
      port: 2000,
      name: name,
      id: id,
      useSSL: true,
      coinName: 'PIVX',
      torEnabled: true,
      clearnetEnabled: true,
      isPrimary: true,
    );
  }

  ThemeData buildTheme() {
    return ThemeData(
      extensions: [
        StackColors.fromStackColorTheme(
          StackTheme.fromJson(json: lightThemeJsonMap),
        ),
      ],
    );
  }

  Future<void> pumpSubject(
    WidgetTester tester, {
    required MockNodeService nodeService,
    required List<Override> extraOverrides,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nodeServiceChangeNotifierProvider.overrideWith((_) => nodeService),
          ...extraOverrides,
        ],
        child: MaterialApp(
          theme: buildTheme(),
          home: NodeCard(nodeId: 'node id', coin: pivx, popBackToRoute: ''),
        ),
      ),
    );

    await tester.pumpAndSettle();
  }

  testWidgets('NodeCard builds inactive node correctly', (tester) async {
    final nodeService = MockNodeService();

    when(
      nodeService.getPrimaryNodeFor(currency: pivx),
    ).thenAnswer((_) => buildNode(id: 'other node id', name: 'Stack Default'));
    when(nodeService.getNodeById(id: 'node id'))
        .thenAnswer((_) => buildNode(id: 'node id', name: 'some other name'));

    await pumpSubject(
      tester,
      nodeService: nodeService,
      extraOverrides: const [],
    );

    expect(find.text('some other name'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.byType(SvgPicture), findsWidgets);

    verify(nodeService.getPrimaryNodeFor(currency: pivx)).called(1);
    verify(nodeService.getNodeById(id: 'node id')).called(1);
    verify(nodeService.addListener(any)).called(1);
    verifyNoMoreInteractions(nodeService);
  });

  testWidgets('NodeCard builds active node correctly', (tester) async {
    final nodeService = MockNodeService();
    final activeNode = buildNode(id: 'node id', name: 'Some other node name');

    when(nodeService.getPrimaryNodeFor(currency: pivx))
        .thenAnswer((_) => activeNode);
    when(nodeService.getNodeById(id: 'node id')).thenAnswer((_) => activeNode);

    await pumpSubject(
      tester,
      nodeService: nodeService,
      extraOverrides: const [],
    );

    expect(find.text('Some other node name'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byType(Text), findsNWidgets(2));
    expect(find.byType(SvgPicture), findsWidgets);

    verify(nodeService.getPrimaryNodeFor(currency: pivx)).called(1);
    verify(nodeService.getNodeById(id: 'node id')).called(1);
    verify(nodeService.addListener(any)).called(1);
    verifyNoMoreInteractions(nodeService);
  });

  testWidgets('NodeCard shows its last test after its state', (tester) async {
    final nodeService = MockNodeService();
    final node = buildNode(id: 'node id', name: 'PIVXie US');
    when(nodeService.getPrimaryNodeFor(currency: pivx))
        .thenAnswer((_) => buildNode(id: 'other node id', name: 'PIVXie EU'));
    when(nodeService.getNodeById(id: 'node id')).thenAnswer((_) => node);
    final tests = NodeTests();

    await pumpSubject(
      tester,
      nodeService: nodeService,
      extraOverrides: [pNodeTests.overrideWith((_) => tests)],
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    final answer = Completer<String?>();
    final run = tests.run(node, () => answer.future);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    answer.complete(null);
    final result = await run;
    await tester.pump();
    final colors = Theme.of(tester.element(find.byType(NodeCard)))
        .extension<StackColors>()!;
    // The connection level's bars that are green.
    int greenBars() => tester
        .widgetList<Container>(find.byType(Container))
        .where(
          (e) =>
              e.decoration is BoxDecoration &&
              (e.decoration! as BoxDecoration).color == colors.accentColorGreen,
        )
        .length;

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(answerTime(result.time)), findsOneWidget);
    expect(greenBars(), result.level);

    await tests.run(node, () async => l10n.nodeUnreachable);
    await tester.pump();
    final noAnswer = tester.widget<Text>(find.text('No answer'));
    expect(noAnswer.style?.color, colors.accentColorRed);
    expect(greenBars(), 0);
  });

  testWidgets('tap to open context menu on default node', (tester) async {
    final nodeService = MockNodeService();
    final activeNode = buildNode(id: 'node id', name: 'Stack Default');

    when(nodeService.getPrimaryNodeFor(currency: pivx))
        .thenAnswer((_) => activeNode);
    when(nodeService.getNodeById(id: 'node id')).thenAnswer((_) => activeNode);

    await pumpSubject(
      tester,
      nodeService: nodeService,
      extraOverrides: const [],
    );

    expect(find.text('Stack Default'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byType(Text), findsNWidgets(2));
    expect(find.byType(SvgPicture), findsNWidgets(2));

    await tester.tap(find.byType(NodeCard));
    await tester.pumpAndSettle();

    if (Util.isDesktop) {
      expect(find.text('Connect'), findsNothing);
      expect(find.text('Details'), findsNothing);

      verify(nodeService.getPrimaryNodeFor(currency: pivx)).called(1);
      verify(nodeService.getNodeById(id: 'node id')).called(1);
    } else {
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
      expect(find.byType(NodeOptionsSheet), findsOneWidget);
      expect(find.byType(Text), findsNWidgets(7));

      verify(nodeService.getPrimaryNodeFor(currency: pivx)).called(2);
      verify(nodeService.getNodeById(id: 'node id')).called(2);
    }

    verify(nodeService.addListener(any)).called(1);
    verifyNoMoreInteractions(nodeService);
  });

  testWidgets(
    'desktop connect failure uses seam once and does not promote node',
    (tester) async {
      final nodeService = MockNodeService();
      final platformOverrides = await createPlatformTestOverrides(
        connectionResult: false,
      );
      final disconnectedNode = buildNode(id: 'node id', name: 'Stack Default');

      when(nodeService.getPrimaryNodeFor(currency: pivx)).thenAnswer(
        (_) => buildNode(id: 'other node id', name: 'Some other node name'),
      );
      when(nodeService.getNodeById(id: 'node id'))
          .thenAnswer((_) => disconnectedNode);

      await pumpSubject(
        tester,
        nodeService: nodeService,
        extraOverrides: platformOverrides.overrides,
      );

      if (!Util.isDesktop) {
        return;
      }

      await tester.tap(find.byType(NodeCard));
      await tester.pumpAndSettle();

      final connectFinder = find.byWidgetPredicate(
        (widget) => widget is CustomTextButton && widget.text == 'Connect',
      );
      expect(connectFinder, findsOneWidget);
      expect(tester.widget<CustomTextButton>(connectFinder).enabled, isTrue);

      tester.widget<CustomTextButton>(connectFinder).onTap?.call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(platformOverrides.secureStorage.reads, 0);
      expect(platformOverrides.connectionInvocations, hasLength(1));
      expect(platformOverrides.connectionInvocations.single.host, '127.0.0.1');

      verifyNever(
        nodeService.setPrimaryNodeFor(
          coin: pivx,
          node: anyNamed('node'),
          shouldNotifyListeners: anyNamed('shouldNotifyListeners'),
        ),
      );
    },
  );
}
