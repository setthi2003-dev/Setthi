import '../models/transaction_model.dart';

/// Abstract repository contract for fetching financial transaction data
abstract class TransactionRepository {
  Future<List<BankTransaction>> fetchTransactions();
}
