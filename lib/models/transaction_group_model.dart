import 'transaction_model.dart';

/// Sort direction for transaction timeline
enum TransactionSortOrder {
  latestFirst,
  oldestFirst,
}

/// Type filter for transactions
enum TransactionTypeFilter {
  all,
  debitOnly,
  creditOnly,
  untagged,
}

/// Represents transactions occurring on a single calendar day
class DayGroup {
  final DateTime date; // Normalized to midnight: YYYY-MM-DD
  final String title; // "Today, 19 Sep", "Yesterday, 18 Sep", "Mon, 14 Oct 2024"
  final String dayOfWeek; // "Mon", "Tue", etc.
  final List<BankTransaction> transactions;
  final double totalDebit;
  final double totalCredit;

  double get netAmount => totalCredit - totalDebit;

  const DayGroup({
    required this.date,
    required this.title,
    required this.dayOfWeek,
    required this.transactions,
    required this.totalDebit,
    required this.totalCredit,
  });
}

/// Represents transactions occurring in a single calendar month
class MonthGroup {
  final int year;
  final int month; // 1 - 12
  final String monthName; // "January", "February", etc.
  final String title; // "October 2024"
  final List<DayGroup> dayGroups;
  final double totalDebit;
  final double totalCredit;
  final int transactionCount;

  const MonthGroup({
    required this.year,
    required this.month,
    required this.monthName,
    required this.title,
    required this.dayGroups,
    required this.totalDebit,
    required this.totalCredit,
    required this.transactionCount,
  });
}

/// Represents transactions occurring in a calendar year
class YearGroup {
  final int year;
  final List<MonthGroup> monthGroups;
  final double totalDebit;
  final double totalCredit;
  final int transactionCount;

  const YearGroup({
    required this.year,
    required this.monthGroups,
    required this.totalDebit,
    required this.totalCredit,
    required this.transactionCount,
  });
}

const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const List<String> _weekdayNames = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

String formatDayTitle(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(date.year, date.month, date.day);
  final diffDays = today.difference(target).inDays;

  final dayMonth = '${date.day} ${_monthNames[date.month - 1].substring(0, 3)}';

  if (diffDays == 0) {
    return 'Today, $dayMonth';
  } else if (diffDays == 1) {
    return 'Yesterday, $dayMonth';
  } else {
    final weekday = _weekdayNames[date.weekday - 1];
    if (date.year == now.year) {
      return '$weekday, $dayMonth';
    } else {
      return '$weekday, $dayMonth ${date.year}';
    }
  }
}

/// Categorizes and aggregates transactions smartly into Year -> Month -> Date hierarchy,
/// respecting user sort order (latestFirst vs oldestFirst) and filters.
List<YearGroup> groupTransactionsSmartly({
  required List<BankTransaction> transactions,
  TransactionSortOrder sortOrder = TransactionSortOrder.latestFirst,
  TransactionTypeFilter typeFilter = TransactionTypeFilter.all,
  int? selectedYear,
}) {
  // 1. Filter by type & year
  final filtered = transactions.where((t) {
    if (typeFilter == TransactionTypeFilter.debitOnly && !t.isDebit) return false;
    if (typeFilter == TransactionTypeFilter.creditOnly && !t.isCredit) return false;
    if (typeFilter == TransactionTypeFilter.untagged &&
        t.category != null &&
        t.category!.trim().isNotEmpty) {
      return false;
    }
    if (selectedYear != null && t.transactionTimestamp.year != selectedYear) return false;
    return true;
  }).toList();

  if (filtered.isEmpty) return [];

  // 2. Sort transactions based on sortOrder
  filtered.sort((a, b) {
    return sortOrder == TransactionSortOrder.latestFirst
        ? b.transactionTimestamp.compareTo(a.transactionTimestamp)
        : a.transactionTimestamp.compareTo(b.transactionTimestamp);
  });

  // 3. Group by Year -> Month -> Day
  final Map<int, Map<int, Map<DateTime, List<BankTransaction>>>> hierarchy = {};

  for (final txn in filtered) {
    final y = txn.transactionTimestamp.year;
    final m = txn.transactionTimestamp.month;
    final d = DateTime(y, m, txn.transactionTimestamp.day);

    hierarchy.putIfAbsent(y, () => {});
    hierarchy[y]!.putIfAbsent(m, () => {});
    hierarchy[y]![m]!.putIfAbsent(d, () => []);
    hierarchy[y]![m]![d]!.add(txn);
  }

  // Sort year keys
  final yearKeys = hierarchy.keys.toList()
    ..sort((a, b) => sortOrder == TransactionSortOrder.latestFirst
        ? b.compareTo(a)
        : a.compareTo(b));

  final List<YearGroup> yearGroups = [];

  for (final year in yearKeys) {
    final monthsMap = hierarchy[year]!;
    final monthKeys = monthsMap.keys.toList()
      ..sort((a, b) => sortOrder == TransactionSortOrder.latestFirst
          ? b.compareTo(a)
          : a.compareTo(b));

    final List<MonthGroup> monthGroups = [];
    double yearDebit = 0;
    double yearCredit = 0;
    int yearCount = 0;

    for (final month in monthKeys) {
      final daysMap = monthsMap[month]!;
      final dayKeys = daysMap.keys.toList()
        ..sort((a, b) => sortOrder == TransactionSortOrder.latestFirst
            ? b.compareTo(a)
            : a.compareTo(b));

      final List<DayGroup> dayGroups = [];
      double monthDebit = 0;
      double monthCredit = 0;
      int monthCount = 0;

      for (final day in dayKeys) {
        final dayTxns = daysMap[day]!;
        double dayDebit = 0;
        double dayCredit = 0;

        for (final t in dayTxns) {
          if (t.isDebit) dayDebit += t.amount;
          if (t.isCredit) dayCredit += t.amount;
        }

        final dayGroup = DayGroup(
          date: day,
          title: formatDayTitle(day),
          dayOfWeek: _weekdayNames[day.weekday - 1],
          transactions: dayTxns,
          totalDebit: dayDebit,
          totalCredit: dayCredit,
        );

        dayGroups.add(dayGroup);
        monthDebit += dayDebit;
        monthCredit += dayCredit;
        monthCount += dayTxns.length;
      }

      final monthName = _monthNames[month - 1];
      final monthGroup = MonthGroup(
        year: year,
        month: month,
        monthName: monthName,
        title: '$monthName $year',
        dayGroups: dayGroups,
        totalDebit: monthDebit,
        totalCredit: monthCredit,
        transactionCount: monthCount,
      );

      monthGroups.add(monthGroup);
      yearDebit += monthDebit;
      yearCredit += monthCredit;
      yearCount += monthCount;
    }

    final yearGroup = YearGroup(
      year: year,
      monthGroups: monthGroups,
      totalDebit: yearDebit,
      totalCredit: yearCredit,
      transactionCount: yearCount,
    );

    yearGroups.add(yearGroup);
  }

  return yearGroups;
}
