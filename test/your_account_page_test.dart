// "Your account" page against a fake account service (the real one needs the
// sign-in service, which isn't set up in tests).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/app_info.dart';
import 'package:smarty_app/screens/account/your_account_page.dart';
import 'package:smarty_app/services/account_service.dart';

class FakeAccountService implements AccountService {
  FakeAccountService({
    this.email = 'anna.kowalska@example.com',
    this.displayName,
  });

  @override
  String? email;

  @override
  String? displayName;

  String password = 'secret123';
  AccountProblem? nameProblem;
  AccountProblem? resetProblem;

  final List<String> calls = [];

  @override
  Future<void> updateDisplayName(String name) async {
    calls.add('name:$name');
    if (nameProblem != null) throw AccountException(nameProblem!);
    displayName = name;
  }

  @override
  Future<void> sendPasswordReset() async {
    calls.add('reset');
    if (resetProblem != null) throw AccountException(resetProblem!);
  }

  @override
  Future<void> signOut() async => calls.add('signOut');

  @override
  Future<void> deleteAccount(String password) async {
    calls.add('delete');
    if (password != this.password) {
      throw const AccountException(AccountProblem.wrongPassword);
    }
  }
}

void main() {
  late FakeAccountService account;
  late int signedOut;

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: YourAccountPage(
          account: account,
          onSignedOut: (_) => signedOut++,
        ),
      ),
    );
  }

  setUp(() {
    account = FakeAccountService();
    signedOut = 0;
  });

  testWidgets('shows email, a prompt to add a name, initials and version',
      (tester) async {
    await pumpPage(tester);
    expect(find.text('Your account'), findsWidgets);
    expect(find.text('anna.kowalska@example.com'), findsWidgets);
    expect(find.text('Add your name'), findsOneWidget);
    expect(find.text('AK'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Version $appVersion'), 100);
    expect(find.text('Version $appVersion'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('shows the saved name and its initials', (tester) async {
    account.displayName = 'Ola Nowak';
    await pumpPage(tester);
    expect(find.text('Ola Nowak'), findsWidgets);
    expect(find.text('ON'), findsOneWidget);
    expect(find.text('Add your name'), findsNothing);
  });

  testWidgets('editing the name saves it cleaned up', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add your name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Anna   Maria ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(account.calls, ['name:Anna Maria']);
    expect(find.text('Anna Maria'), findsWidgets);
    expect(find.text('Name saved'), findsOneWidget);
  });

  testWidgets('an empty name is refused without saving', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add your name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Please type your name.'), findsOneWidget);
    expect(account.calls, isEmpty);
  });

  testWidgets('a failed name save shows a friendly message', (tester) async {
    account.nameProblem = AccountProblem.other;
    await pumpPage(tester);
    await tester.tap(find.text('Add your name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Anna');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't save your name. Please try again."),
        findsOneWidget);
    expect(find.text('Add your name'), findsOneWidget);
  });

  testWidgets('change password emails a link', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Change password'));
    await tester.pumpAndSettle();
    expect(account.calls, ['reset']);
    expect(find.textContaining('Check your email'), findsOneWidget);
  });

  testWidgets('change password without internet says so', (tester) async {
    account.resetProblem = AccountProblem.network;
    await pumpPage(tester);
    await tester.tap(find.text('Change password'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Can't reach the internet"), findsOneWidget);
    expect(find.textContaining('Check your email'), findsNothing);
  });

  testWidgets('sign out asks first, then leaves', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(account.calls, isEmpty);
    expect(signedOut, 0);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(account.calls, ['signOut']);
    expect(signedOut, 1);
  });

  group('delete account', () {
    Future<void> openDialog(WidgetTester tester) async {
      await pumpPage(tester);
      await tester.scrollUntilVisible(find.text('Delete account'), 100);
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      expect(find.text('Delete your account?'), findsOneWidget);
    }

    Finder deleteButton() => find.widgetWithText(TextButton, 'Delete account');

    testWidgets('needs the password typed', (tester) async {
      await openDialog(tester);
      await tester.tap(deleteButton());
      await tester.pumpAndSettle();
      expect(find.text('Please type your password.'), findsOneWidget);
      expect(account.calls, isEmpty);
      expect(signedOut, 0);
    });

    testWidgets('wrong password is explained inline', (tester) async {
      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'nope');
      await tester.tap(deleteButton());
      await tester.pumpAndSettle();
      expect(find.text("That password isn't right."), findsOneWidget);
      expect(find.text('Delete your account?'), findsOneWidget);
      expect(signedOut, 0);
    });

    testWidgets('right password deletes and leaves', (tester) async {
      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'secret123');
      await tester.tap(deleteButton());
      await tester.pumpAndSettle();
      expect(account.calls, ['delete']);
      expect(signedOut, 1);
    });

    testWidgets('cancel does nothing', (tester) async {
      await openDialog(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Delete your account?'), findsNothing);
      expect(account.calls, isEmpty);
      expect(signedOut, 0);
    });
  });
}
