import 'package:flutter/widgets.dart';

import '../../services/account_service.dart';

/// Longest name a parent can save (in characters as they see them).
const int maxDisplayNameLength = 40;

final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// One or two capital letters for the account avatar: first + last word of
/// [displayName] when set, else of the part of [email] before the "@" (split
/// on dots, dashes, underscores, "+"). Empty when there is nothing usable, so
/// the caller can show a person icon instead. Pure (tests).
String initialsFor({String? displayName, String? email}) {
  final String name = displayName?.trim() ?? '';
  final List<String> words;
  if (name.isNotEmpty) {
    words = name.split(RegExp(r'\s+'));
  } else {
    final String local = (email ?? '').trim().split('@').first;
    words = local.split(RegExp(r'[._\-+\s]+'));
  }
  final letters = <String>[];
  for (final word in words) {
    final String? letter = _firstLetter(word);
    if (letter != null) letters.add(letter);
  }
  if (letters.isEmpty) return '';
  if (letters.length == 1) return letters.first;
  return letters.first + letters.last;
}

String? _firstLetter(String word) {
  for (final ch in word.characters) {
    if (_letterOrDigit.hasMatch(ch)) return ch.toUpperCase();
  }
  return null;
}

/// The name as it will be saved: trimmed, runs of spaces collapsed. Pure.
String normalizeDisplayName(String raw) =>
    raw.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Parent-facing problem with [raw] as a name, or null when it can be saved.
/// Pure (tests).
String? validateDisplayName(String raw) {
  final String name = normalizeDisplayName(raw);
  if (name.isEmpty) return 'Please type your name.';
  if (name.characters.length > maxDisplayNameLength) {
    return "That's a bit long — please keep it to "
        '$maxDisplayNameLength letters or fewer.';
  }
  return null;
}

/// Plain-language text for an [AccountProblem]. Pure (tests).
String accountProblemMessage(AccountProblem problem) {
  switch (problem) {
    case AccountProblem.wrongPassword:
      return "That password isn't right.";
    case AccountProblem.network:
      return "Can't reach the internet — check your connection and try again.";
    case AccountProblem.tooManyRequests:
      return 'Too many tries — please wait a few minutes and try again.';
    case AccountProblem.signInAgain:
      return 'Please sign out, sign in again, and then try once more.';
    case AccountProblem.other:
      return 'Something went wrong. Please try again.';
  }
}
