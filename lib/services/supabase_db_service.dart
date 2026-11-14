import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../config/supabase_config.dart';
import '../models/chat_message_model.dart';
import '../models/merchant_category_model.dart';
import '../models/reminder_model.dart';
import '../models/transaction_model.dart';
import 'email_transaction_parser.dart';
import 'setu_aa_service.dart';
import 'slice_credit_card_pdf_parser_service.dart';

/// Service managing persistent storage of user profiles, AA consents,
/// bank accounts, and financial transactions in Supabase Postgres.
class SupabaseDbService {
  final SupabaseClient? client;

  SupabaseDbService({this.client});

  SupabaseClient? get _effectiveClient {
    if (client != null) return client;
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return SupabaseConfig.client;
    } catch (_) {
      return null;
    }
  }

  String? get currentUserId {
    final client = _effectiveClient;
    if (client == null) return null;
    final user = client.auth.currentUser;
    if (user != null) return user.id;
    final session = client.auth.currentSession;
    if (session != null) return session.user.id;
    return null;
  }

  // ===========================================================================
  // 1. PROFILES
  // ===========================================================================

  /// Upserts user profile details in public.profiles
  Future<void> upsertProfile({
    required String userId,
    required String email,
    String? fullName,
    String? phoneNumber,
    String? avatarUrl,
    int? age,
    String? gender,
    DateTime? dateOfBirth,
    String? incomeType,
    double? expectedMonthlyIncome,
  }) async {
    final client = _effectiveClient;
    if (client == null) return;

    try {
      final payload = <String, dynamic>{
        'id': userId,
        'email': email.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (fullName != null && fullName.isNotEmpty) {
        payload['full_name'] = fullName.trim();
      }
      if (phoneNumber != null && phoneNumber.isNotEmpty) {
        payload['phone_number'] = phoneNumber.trim();
      }
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        payload['avatar_url'] = avatarUrl.trim();
      }
      if (dateOfBirth != null) {
        payload['date_of_birth'] =
            '${dateOfBirth.year.toString().padLeft(4, '0')}-${dateOfBirth.month.toString().padLeft(2, '0')}-${dateOfBirth.day.toString().padLeft(2, '0')}';
        if (age == null) {
          final now = DateTime.now();
          int calculatedAge = now.year - dateOfBirth.year;
          if (now.month < dateOfBirth.month ||
              (now.month == dateOfBirth.month && now.day < dateOfBirth.day)) {
            calculatedAge--;
          }
          payload['age'] = calculatedAge;
        }
      }
      if (age != null) {
        payload['age'] = age;
      }
      if (gender != null && gender.isNotEmpty) {
        payload['gender'] = gender.trim();
      }
      if (incomeType != null) {
        payload['income_type'] = incomeType.trim();
      }
      if (expectedMonthlyIncome != null) {
        payload['expected_monthly_income'] = expectedMonthlyIncome;
      }

      await client.from('profiles').upsert(payload);
      debugPrint('[Supabase DB] Profile updated successfully for $userId');
    } catch (e) {
      debugPrint('[Supabase DB] Error upserting profile: $e');
    }
  }

  /// Fetches the current user profile from public.profiles
  Future<Map<String, dynamic>?> fetchProfile([String? userId]) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return null;

    try {
      var res = await client
          .from('profiles')
          .select()
          .eq('id', uid)
          .maybeSingle();

      if (res == null) {
        // Self-heal: profile missing, create it automatically with 3 free credits
        final user = client.auth.currentUser;
        final email = user?.email ?? '';
        final fullName = user?.userMetadata?['full_name'] as String? ??
            user?.userMetadata?['name'] as String? ??
            'Setthi Member';
        await client.from('profiles').upsert({
          'id': uid,
          'email': email,
          'full_name': fullName,
          'ai_credits': 3,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
        res = await client.from('profiles').select().eq('id', uid).maybeSingle();
      }

      return res;
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching profile: $e');
      return null;
    }
  }

  // ===========================================================================
  // 2. ACCOUNT AGGREGATOR CONSENTS
  // ===========================================================================

  /// Records an initiated or approved Setu AA consent in public.aa_consents
  Future<void> recordConsent({
    required String consentId,
    required String status,
    String? vua,
    DateTime? validFrom,
    DateTime? validTo,
  }) async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return;

    try {
      final payload = <String, dynamic>{
        'user_id': uid,
        'consent_id': consentId,
        'status': status.toUpperCase(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (vua != null) payload['vua'] = vua;
      if (validFrom != null) payload['valid_from'] = validFrom.toUtc().toIso8601String();
      if (validTo != null) payload['valid_to'] = validTo.toUtc().toIso8601String();

      await client.from('aa_consents').upsert(
            payload,
            onConflict: 'consent_id',
          );
      debugPrint('[Supabase DB] Recorded AA consent $consentId ($status)');
    } catch (e) {
      debugPrint('[Supabase DB] Error recording consent: $e');
    }
  }

  /// Updates status for an existing AA consent
  Future<void> updateConsentStatus({
    required String consentId,
    required String status,
  }) async {
    final client = _effectiveClient;
    if (client == null) return;

    try {
      await client.from('aa_consents').update({
        'status': status.toUpperCase(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('consent_id', consentId);
    } catch (e) {
      debugPrint('[Supabase DB] Error updating consent status: $e');
    }
  }

  /// Fetches the latest active AA consent record for the current user.
  Future<Map<String, dynamic>?> fetchActiveConsent({String? userId}) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return null;

    try {
      final res = await client
          .from('aa_consents')
          .select()
          .eq('user_id', uid)
          .eq('status', 'ACTIVE')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      return res;
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching active consent: $e');
      return null;
    }
  }

  // ===========================================================================
  // 3. BANK ACCOUNTS
  // ===========================================================================

  /// Upserts a discovered bank account into public.bank_accounts
  Future<String?> upsertBankAccount({
    required String maskedAccNumber,
    String? fipId,
    String? consentId,
    String? linkRefNumber,
    String accountType = 'SAVINGS',
    double currentBalance = 0.0,
    String currency = 'INR',
    String status = 'ACTIVE',
  }) async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return null;

    try {
      final payload = <String, dynamic>{
        'user_id': uid,
        'masked_acc_number': maskedAccNumber,
        'fip_id': fipId,
        'account_type': accountType,
        'current_balance': currentBalance,
        'currency': currency,
        'status': status,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (consentId != null) payload['consent_id'] = consentId;
      if (linkRefNumber != null) payload['link_ref_number'] = linkRefNumber;

      final res = await client
          .from('bank_accounts')
          .upsert(
            payload,
            onConflict: 'user_id,masked_acc_number,fip_id',
          )
          .select('id')
          .maybeSingle();

      return res?['id']?.toString();
    } catch (e) {
      debugPrint('[Supabase DB] Error upserting bank account: $e');
      return null;
    }
  }

  /// Fetches linked bank accounts for the current user
  Future<List<Map<String, dynamic>>> fetchBankAccounts() async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return [];

    try {
      final res = await client
          .from('bank_accounts')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res);
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching bank accounts: $e');
      return [];
    }
  }

  /// Fetches verified bank balance facts via get_current_balance RPC
  Future<Map<String, dynamic>?> fetchCurrentBalance([String? userId]) async {
    final client = _effectiveClient;
    if (client == null) return null;

    try {
      final res = await client.rpc(
        'get_current_balance',
        params: userId != null ? {'p_user_id': userId} : {},
      );
      if (res is Map<String, dynamic>) {
        return res;
      } else if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
      return null;
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching current balance: $e');
      return null;
    }
  }

  // ===========================================================================
  // 4. BANK TRANSACTIONS
  // ===========================================================================

  /// Fetches known merchant rules from public.merchant_categories and populates
  /// the in-memory [MerchantCategoryRegistry].
  Future<List<MerchantCategoryRule>> fetchMerchantCategories() async {
    final client = _effectiveClient;
    if (client == null) {
      return MerchantCategoryRegistry.instance.rules;
    }

    try {
      final res = await client
          .from('merchant_categories')
          .select('keyword, clean_name, category, icon')
          .order('keyword', ascending: true);
      final list = List<Map<String, dynamic>>.from(res);
      final rules = list.map(MerchantCategoryRule.fromJson).toList();
      MerchantCategoryRegistry.instance.updateRules(rules);
      debugPrint('[Supabase DB] Loaded ${rules.length} merchant categories from database');
      return rules;
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching merchant categories: $e');
      return MerchantCategoryRegistry.instance.rules;
    }
  }

  /// Persists a batch of transactions collected from the Setu AA gateway or PDF parser into public.bank_transactions.
  /// Uses idempotent upsert on (user_id, txn_id) to avoid duplicates while updating current balances.
  Future<bool> saveBankTransactions({
    required List<BankTransaction> transactions,
    String? accountId,
    String? userId,
    String? fileName,
  }) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null || transactions.isEmpty) return false;

    try {
      if (!MerchantCategoryRegistry.instance.isInitializedFromRemote) {
        await fetchMerchantCategories();
      }

      String? effectiveAccId = accountId;
      if (effectiveAccId == null) {
        final accounts = await fetchBankAccounts();
        if (accounts.isNotEmpty) {
          effectiveAccId = accounts.first['id']?.toString();
        } else {
          // If no linked account exists, create an initial account record
          effectiveAccId = await upsertBankAccount(
            maskedAccNumber: 'Statement Account',
            fipId: 'STATEMENT_IMPORT',
            accountType: 'SAVINGS',
            currentBalance: 0.0,
          );
        }
      }

      final nowUtcIso = DateTime.now().toUtc().toIso8601String();
      final importBatchId = const Uuid().v4();
      final importBatchAt = nowUtcIso;

      final rows = transactions.map((t) {
        final match = MerchantCategoryRegistry.instance.findMatch(t.narration);
        final category = t.category ?? match?.category; // null if unmatched
        final cleanName = t.cleanMerchantName;

        final rawMeta = {
          'source': 'pdf_statement',
          'fileName': fileName ?? 'bank_statement.pdf',
          'parsedAt': nowUtcIso,
          'originalTxnId': t.txnId,
        };

        final parts = t.txnId.split('_');
        final seqNum = t.seq ?? (parts.length >= 3 ? int.tryParse(parts[2]) : null);

        return <String, dynamic>{
          'user_id': uid,
          'account_id': ?effectiveAccId,
          'txn_id': t.txnId,
          'type': t.type.value,
          'mode': t.mode,
          'amount': t.amount,
          'current_balance': t.currentBalance,
          'transaction_timestamp': t.transactionTimestamp.toUtc().toIso8601String(),
          'narration': t.narration,
          'clean_merchant_name': cleanName,
          'category': category,
          'raw_data': rawMeta,
          if (t.spendTier != null && t.spendTier!.isNotEmpty) 'spend_tier': t.spendTier,
          'is_recurring': t.isRecurring,
          'seq': ?seqNum,
          'import_batch_id': importBatchId,
          'import_batch_at': importBatchAt,
        };
      }).toList();

      await client.from('bank_transactions').upsert(
            rows,
            onConflict: 'user_id,txn_id',
          );

      // Trigger post-import pipeline in Supabase Postgres:
      // tag_transactions -> sync_detected_recurring_commitments -> classify_transactions -> update bank_accounts -> refresh_habit_profile
      try {
        await client.rpc('post_import_pipeline', params: {'p_user_id': uid});
      } catch (pipeErr) {
        debugPrint('[Supabase DB] post_import_pipeline RPC error: $pipeErr');
      }

      debugPrint(
        '[Supabase DB] Successfully persisted ${transactions.length} transactions in Supabase!',
      );
      return true;
    } catch (e) {
      debugPrint('[Supabase DB] Error saving bank transactions: $e');
      return false;
    }
  }

  /// Fetches stored bank and credit card transactions for the current user with pagination.
  Future<List<BankTransaction>> fetchStoredTransactions({
    String? userId,
    int? limit,
    int? offset,
    bool includeCreditCard = true,
  }) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return [];

    try {
      var query = client
          .from('bank_transactions')
          .select()
          .eq('user_id', uid)
          .not('txn_id', 'like', 'gmail_%')
          .order('transaction_timestamp', ascending: false)
          .order('seq', ascending: false, nullsFirst: false)
          .order('created_at', ascending: false);

      if (limit != null) {
        final start = offset ?? 0;
        final end = start + limit - 1;
        query = query.range(start, end);
      }

      final res = await query;
      final list = List<Map<String, dynamic>>.from(res);
      final bankTxns = list.map((row) => BankTransaction.fromJson(row)).toList();

      if (includeCreditCard) {
        try {
          final cardRes = await client
              .from('credit_card_transactions')
              .select()
              .eq('user_id', uid)
              .order('transaction_date', ascending: false)
              .range(offset ?? 0, (offset ?? 0) + (limit ?? 50) - 1);
          final cardList = List<Map<String, dynamic>>.from(cardRes);
          final cardTxns = cardList.map((row) => BankTransaction.fromCreditCardJson(row)).toList();

          if (cardTxns.isNotEmpty) {
            final combined = [...bankTxns, ...cardTxns];
            combined.sort((a, b) => b.transactionTimestamp.compareTo(a.transactionTimestamp));
            if (limit != null && combined.length > limit) {
              return combined.sublist(0, limit);
            }
            return combined;
          }
        } catch (e) {
          debugPrint('[Supabase DB] Note on card txns in fetchStoredTransactions: $e');
        }
      }

      return bankTxns;
    } catch (e) {
      debugPrint('[Supabase DB] Error loading stored transactions: $e');
      return [];
    }
  }

  /// Cleans up any legacy/test email transactions that were incorrectly inserted into public.bank_transactions.
  /// Bank transactions are reserved exclusively for bank statements and Account Aggregator feeds.
  Future<void> cleanupOrphanedBankTransactions([String? userId]) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return;

    try {
      await client
          .from('bank_transactions')
          .delete()
          .eq('user_id', uid)
          .like('txn_id', 'gmail_%');
      debugPrint('[Supabase DB] Cleaned up orphaned gmail_ records from bank_transactions');
    } catch (e) {
      debugPrint('[Supabase DB] Note on cleanupOrphanedBankTransactions: $e');
    }
  }

  /// Returns the total count of stored transactions (bank + card) for the current user
  Future<int> countStoredTransactions([String? userId]) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return 0;

    try {
      final res = await client
          .from('bank_transactions')
          .select('txn_id')
          .eq('user_id', uid)
          .not('txn_id', 'like', 'gmail_%');
      final bankCount = (res as List).length;
      try {
        final cardCount = await countCreditCardTransactions(uid);
        return bankCount + cardCount;
      } catch (_) {
        return bankCount;
      }
    } catch (e) {
      debugPrint('[Supabase DB] Error counting transactions: $e');
      return 0;
    }
  }

  /// Updates the category for a specific transaction in public.bank_transactions
  Future<void> updateTransactionCategory({
    required String txnId,
    required String category,
    String? txnKind,
  }) async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return;

    try {
      final updates = <String, dynamic>{
        'category': category,
        'habit_category': category,
        'tag_source': 'user',
      };
      if (txnKind != null && txnKind.isNotEmpty) {
        updates['txn_kind'] = txnKind;
      }
      await client
          .from('bank_transactions')
          .update(updates)
          .eq('user_id', uid)
          .eq('txn_id', txnId);
      debugPrint('[Supabase DB] Updated category for $txnId to $category');

      // Trigger post_import_pipeline to recalculate commitments, balances, and habit profile
      try {
        await client.rpc('post_import_pipeline', params: {'p_user_id': uid});
      } catch (pipeErr) {
        debugPrint('[Supabase DB] post_import_pipeline RPC error after category update: $pipeErr');
      }
    } catch (e) {
      debugPrint('[Supabase DB] Error updating transaction category: $e');
    }
  }

  /// Updates all stored transactions matching a merchant name with the given category
  Future<void> updateAllTransactionsCategoryByMerchant({
    required String cleanMerchantName,
    required String category,
  }) async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return;

    try {
      await client
          .from('bank_transactions')
          .update({
            'category': category,
            'habit_category': category,
            'tag_source': 'user',
          })
          .eq('user_id', uid)
          .ilike('clean_merchant_name', cleanMerchantName.trim());
      debugPrint('[Supabase DB] Bulk updated category for $cleanMerchantName to $category');

      // Trigger post_import_pipeline to recalculate commitments, balances, and habit profile
      try {
        await client.rpc('post_import_pipeline', params: {'p_user_id': uid});
      } catch (pipeErr) {
        debugPrint('[Supabase DB] post_import_pipeline RPC error after bulk category update: $pipeErr');
      }
    } catch (e) {
      debugPrint('[Supabase DB] Error bulk updating merchant category: $e');
    }
  }

  /// Persists a merchant categorization rule to public.merchant_categories
  Future<void> saveMerchantRule({
    required String keyword,
    required String cleanName,
    required String category,
    String? icon,
  }) async {
    final rule = MerchantCategoryRule(
      keyword: keyword.toLowerCase().trim(),
      cleanName: cleanName.trim(),
      category: category.trim(),
      icon: icon,
    );
    MerchantCategoryRegistry.instance.addRule(rule);

    final client = _effectiveClient;
    if (client == null) return;

    try {
      await client.from('merchant_categories').upsert(
            rule.toJson(),
            onConflict: 'keyword',
          );
      debugPrint('[Supabase DB] Persisted merchant rule for $keyword -> $category');
    } catch (e) {
      debugPrint('[Supabase DB] Error saving merchant rule: $e');
    }
  }

  Future<Map<String, dynamic>>? _inFlightSyncFuture;
  String? _inFlightSyncConsentId;

  /// Triggers server-side Setu AA data session creation, polling, ReBIT parsing,
  /// and database upserts via the `sync-transactions` Supabase Edge Function.
  /// Deduplicates concurrent sync requests to prevent Setu 410 "Consent use exceeded" race conditions.
  Future<Map<String, dynamic>> triggerBackendSync({String? consentId}) async {
    final client = _effectiveClient;
    if (client == null) {
      throw Exception('Supabase client is not configured or authenticated.');
    }

    if (_inFlightSyncFuture != null && _inFlightSyncConsentId == consentId) {
      debugPrint('[Supabase DB] Sync already in-flight for consent $consentId, awaiting active session...');
      return _inFlightSyncFuture!;
    }

    final future = _executeBackendSync(client, consentId);
    _inFlightSyncFuture = future;
    _inFlightSyncConsentId = consentId;

    try {
      final res = await future;
      return res;
    } finally {
      if (_inFlightSyncFuture == future) {
        _inFlightSyncFuture = null;
        _inFlightSyncConsentId = null;
      }
    }
  }

  Future<Map<String, dynamic>> _executeBackendSync(
    SupabaseClient client,
    String? consentId,
  ) async {
    final response = await client.functions.invoke(
      'sync-transactions',
      body: consentId != null ? {'consentId': consentId} : <String, dynamic>{},
    );

    if (response.status >= 400) {
      final data = response.data;
      if (response.status == 410 ||
          (data is Map && data['code'] == 'CONSENT_EXPIRED')) {
        throw SetuConsentExpiredException(
          'Bank consent session has expired or completed. Please reconnect your bank.',
          statusCode: response.status,
          responseBody: data,
        );
      }
      throw Exception(
        'Backend sync failed (${response.status}): ${data is Map ? data['error'] ?? data : data}',
      );
    }

    return (response.data is Map<String, dynamic>)
        ? response.data as Map<String, dynamic>
        : Map<String, dynamic>.from(response.data as Map);
  }

  /// Initiates Setu AA consent on the backend using credentials securely stored in Supabase Vault.
  Future<Map<String, String>> createConsentViaBackend({
    required String mobileNumber,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw Exception('Supabase client is not configured or authenticated.');
    }

    final response = await client.functions.invoke(
      'sync-transactions',
      body: {
        'action': 'create-consent',
        'mobileNumber': mobileNumber,
      },
    );

    if (response.status >= 400) {
      final data = response.data;
      throw Exception(
        'Backend consent initiation failed (${response.status}): ${data is Map ? data['error'] ?? data : data}',
      );
    }

    final data = response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : Map<String, dynamic>.from(response.data as Map);

    return {
      'consentId': data['consentId']?.toString() ?? '',
      'url': data['url']?.toString() ?? '',
    };
  }

  /// Checks Setu AA consent status on the backend using credentials stored in Supabase Vault.
  Future<String> checkConsentStatusViaBackend({
    required String consentId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw Exception('Supabase client is not configured or authenticated.');
    }

    final response = await client.functions.invoke(
      'sync-transactions',
      body: {
        'action': 'check-consent',
        'consentId': consentId,
      },
    );

    if (response.status >= 400) {
      final data = response.data;
      throw Exception(
        'Backend consent status check failed (${response.status}): ${data is Map ? data['error'] ?? data : data}',
      );
    }

    final data = response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : Map<String, dynamic>.from(response.data as Map);

    return (data['status']?.toString() ?? 'PENDING').toUpperCase();
  }

  // ===========================================================================
  // 6. SETTHI AI CREDITS & CHAT HISTORY
  // ===========================================================================

  /// Fetches the user's current remaining AI credits from public.profiles
  Future<int> fetchAiCredits() async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return 3;

    try {
      final data = await client
          .from('profiles')
          .select('ai_credits')
          .eq('id', uid)
          .maybeSingle();

      if (data != null && data['ai_credits'] != null) {
        return (data['ai_credits'] as num).toInt();
      }
      return 3;
    } on PostgrestException catch (e) {
      if (e.code == '42703' || e.code == 'PGRST205') {
        debugPrint('[Supabase DB] Note: ai_credits column not yet migrated in public.profiles. Defaulting to 3 credits.');
      } else {
        debugPrint('[Supabase DB] Error fetching AI credits: ${e.message}');
      }
      return 3;
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching AI credits: $e');
      return 3;
    }
  }

  /// Fetches past conversation messages between the user and Setthi AI
  Future<List<ChatMessage>> fetchChatHistory({int limit = 50}) async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return [];

    try {
      final List<dynamic> rows = await client
          .from('chat_messages')
          .select('*')
          .eq('user_id', uid)
          .order('created_at', ascending: true)
          .limit(limit);

      return rows
          .map((row) => ChatMessage.fromJson(row as Map<String, dynamic>))
          .toList();
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST205' || e.code == '42P01') {
        debugPrint('[Supabase DB] Note: chat_messages table not yet migrated in DB. Returning empty history.');
      } else {
        debugPrint('[Supabase DB] Error fetching chat history: ${e.message}');
      }
      return [];
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching chat history: $e');
      return [];
    }
  }

  /// Deletes all chat messages for the current authenticated user from the backend database
  Future<bool> deleteChatHistory() async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return false;

    try {
      await client
          .from('chat_messages')
          .delete()
          .eq('user_id', uid);
      return true;
    } on PostgrestException catch (e) {
      debugPrint('[Supabase DB] Error deleting chat history: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('[Supabase DB] Error deleting chat history: $e');
      return false;
    }
  }

  // ===========================================================================
  // 6. DETERMINISTIC TELEMETRY
  // ===========================================================================

  /// Fetches real telemetry aggregations from the deterministic RPC get_telemetry_metrics
  Future<Map<String, dynamic>?> fetchTelemetryMetrics({String period = 'all'}) async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return null;

    try {
      final res = await client.rpc(
        'get_telemetry_metrics',
        params: {
          'p_user_id': uid,
          'p_period': period,
        },
      );
      if (res is Map<String, dynamic>) {
        return res;
      } else if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
      return null;
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching telemetry metrics for $period: $e');
      return null;
    }
  }

  // ===========================================================================
  // 7. CASHFLOW RHYTHM & RECURRING COMMITMENTS
  // ===========================================================================

  /// Fetches real-time financial rhythm (Safe-to-spend today/week, upcoming bills, runway)
  Future<Map<String, dynamic>?> fetchCashflowRhythm([String? userId]) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return null;

    try {
      final res = await client.rpc(
        'get_cashflow_rhythm',
        params: {'p_user_id': uid},
      );
      if (res is Map<String, dynamic>) {
        return res;
      } else if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
      return null;
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching cashflow rhythm: $e');
      return null;
    }
  }

  /// Fetches the user's recurring commitments (subscriptions, rent, bills)
  Future<List<Map<String, dynamic>>> fetchRecurringCommitments([String? userId]) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return [];

    try {
      final res = await client
          .from('user_recurring_commitments')
          .select()
          .eq('user_id', uid)
          .order('typical_due_day', ascending: true);
      return List<Map<String, dynamic>>.from(res);
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching recurring commitments: $e');
      return [];
    }
  }

  /// Toggles active status of a recurring commitment (exclude or re-include in rhythm calculations)
  Future<void> toggleRecurringCommitment({
    required String commitmentId,
    required bool isActive,
    String? userId,
  }) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return;

    try {
      await client
          .from('user_recurring_commitments')
          .update({'is_active': isActive, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', commitmentId)
          .eq('user_id', uid);
      debugPrint('[Supabase DB] Commitment $commitmentId updated isActive=$isActive');
    } catch (e) {
      debugPrint('[Supabase DB] Error toggling recurring commitment: $e');
    }
  }

  /// Adds or updates a recurring commitment
  Future<void> upsertRecurringCommitment({
    required String merchantName,
    required double expectedAmount,
    String category = 'Subscription',
    int? typicalDueDay,
    String frequency = 'MONTHLY',
    bool isConfirmed = true,
    String? userId,
  }) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return;

    try {
      final payload = <String, dynamic>{
        'user_id': uid,
        'merchant_name': merchantName.trim(),
        'expected_amount': expectedAmount,
        'category': category.trim(),
        'frequency': frequency,
        'is_confirmed': isConfirmed,
        'is_active': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (typicalDueDay != null) {
        payload['typical_due_day'] = typicalDueDay;
      }
      await client.from('user_recurring_commitments').upsert(
        payload,
        onConflict: 'user_id,merchant_name',
      );
      debugPrint('[Supabase DB] Successfully upserted recurring commitment for $merchantName');
    } catch (e) {
      debugPrint('[Supabase DB] Error upserting recurring commitment: $e');
    }
  }

  /// Fetches the user's habit profile and financial archetype from user_habit_profile
  Future<Map<String, dynamic>?> fetchHabitProfile([String? userId]) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return null;

    try {
      final res = await client
          .from('user_habit_profile')
          .select('profile, archetype, computed_at')
          .eq('user_id', uid)
          .maybeSingle();
      if (res != null) {
        return Map<String, dynamic>.from(res);
      }
      return null;
    } catch (e) {
      debugPrint('[Supabase DB] fetchHabitProfile error: $e');
      return null;
    }
  }

  /// Manually triggers recalculation of habit profile and archetype in Supabase
  Future<Map<String, dynamic>?> refreshHabitProfile([String? userId]) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return null;

    try {
      final res = await client.rpc(
        'refresh_habit_profile',
        params: {'p_user_id': uid},
      );
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
      return null;
    } catch (e) {
      debugPrint('[Supabase DB] refreshHabitProfile RPC error: $e');
      return null;
    }
  }

  // ===========================================================================
  // 9. EMAIL EXTRACTED TRANSACTIONS (PRODUCTION ISOLATED TABLE)
  // ===========================================================================

  /// Saves email-extracted transactions and discovered subscriptions directly to
  /// public.email_extracted_transactions in production, guaranteeing idempotent
  /// upserts keyed on (user_id, gmail_message_id).
  ///
  /// Subscriptions are strictly consolidated per service (e.g., 'sub_netflix')
  /// so that recurring services are stored ONCE with comprehensive details (latest amount,
  /// next due day, last paid date, card info) rather than duplicating per monthly email.
  Future<bool> saveEmailExtractedTransactions({
    required List<ExtractedEmailTransaction> transactions,
    required String userId,
    List<ExtractedEmailSubscription> subscriptions = const [],
  }) async {
    final client = _effectiveClient;
    if (client == null) return false;
    if (transactions.isEmpty && subscriptions.isEmpty) return true;

    try {
      final nowUtc = DateTime.now().toUtc().toIso8601String();

      // 1. Group and consolidate all subscription signals by service name
      final Map<String, _ConsolidatedSubscription> consolidatedSubs = {};

      for (final s in subscriptions) {
        final key = s.serviceName.trim().toLowerCase();
        final existing = consolidatedSubs[key];
        if (existing == null) {
          consolidatedSubs[key] = _ConsolidatedSubscription(
            serviceName: s.serviceName.trim(),
            expectedAmount: s.expectedAmount,
            currency: s.currency,
            typicalDueDay: s.typicalDueDay,
            frequency: s.frequency,
            latestBillingDate: s.billingDate,
            cardLast4: s.cardLast4,
            category: s.category,
          );
        } else {
          if (s.billingDate.isAfter(existing.latestBillingDate)) {
            existing.latestBillingDate = s.billingDate;
            existing.expectedAmount = s.expectedAmount;
          }
          if (existing.cardLast4 == null && s.cardLast4 != null) {
            existing.cardLast4 = s.cardLast4;
          }
          if (s.typicalDueDay > 0) {
            existing.typicalDueDay = s.typicalDueDay;
          }
        }
      }

      for (final t in transactions) {
        final isSubCategory = t.category == 'Subscription';
        final isRecurring = t.isRecurring;
        if (isSubCategory || isRecurring) {
          final key = t.merchantName.trim().toLowerCase();
          final existing = consolidatedSubs[key];
          if (existing == null) {
            consolidatedSubs[key] = _ConsolidatedSubscription(
              serviceName: t.merchantName.trim(),
              expectedAmount: t.amount,
              currency: t.currency,
              typicalDueDay: t.transactionDate.day,
              frequency: 'MONTHLY',
              latestBillingDate: t.transactionDate,
              cardLast4: t.cardLast4,
              bankOrIssuer: t.bankOrIssuer,
              category: t.category ?? 'Subscription',
            );
          } else {
            if (t.transactionDate.isAfter(existing.latestBillingDate)) {
              existing.latestBillingDate = t.transactionDate;
              existing.expectedAmount = t.amount;
            }
            if (existing.cardLast4 == null && t.cardLast4 != null) {
              existing.cardLast4 = t.cardLast4;
            }
            if (t.bankOrIssuer.isNotEmpty && existing.bankOrIssuer == null) {
              existing.bankOrIssuer = t.bankOrIssuer;
            }
          }
        }
      }

      final payloads = <Map<String, dynamic>>[];

      // 2. Map Statements and genuine one-off email transactions
      for (final t in transactions) {
        final key = t.merchantName.trim().toLowerCase();
        // Skip individual recurring subscription receipts from being saved as separate transaction rows;
        // they are consolidated into a single subscription entry below.
        // NOTE: Statements (isStatement == true) MUST always be preserved so their PDF paths and bill due dates are retained!
        if (!t.isStatement && consolidatedSubs.containsKey(key)) {
          continue;
        }

        payloads.add({
          'user_id': userId,
          'gmail_message_id': t.gmailMessageId,
          'amount': t.amount,
          'currency': t.currency,
          'merchant_name': t.merchantName,
          'payment_mode': t.paymentMode,
          'transaction_type': t.type == TransactionType.credit ? 'CREDIT' : 'DEBIT',
          'card_last4': t.cardLast4,
          'bank_or_issuer': t.bankOrIssuer,
          'transaction_date': t.transactionDate.toUtc().toIso8601String(),
          'narration': t.narration,
          'category': t.category,
          'is_recurring': false,
          'recurring_frequency': null,
          'typical_due_day': null,
          'is_statement': t.isStatement,
          'statement_pdf_path': t.statementPdfPath,
          'statement_period': t.statementPeriod,
          'statement_due_date': t.statementDueDate?.toUtc().toIso8601String(),
          'statement_total_due': t.statementTotalDue,
          'statement_min_due': t.statementMinDue,
          'updated_at': nowUtc,
        });
      }

      // 3. Map exactly ONE record per subscription service with complete details
      for (final sub in consolidatedSubs.values) {
        final syntheticMessageId = 'sub_${sub.serviceName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_')}';
        payloads.add({
          'user_id': userId,
          'gmail_message_id': syntheticMessageId,
          'amount': sub.expectedAmount,
          'currency': sub.currency,
          'merchant_name': sub.serviceName,
          'payment_mode': 'SUBSCRIPTION',
          'transaction_type': 'DEBIT',
          'card_last4': sub.cardLast4,
          'bank_or_issuer': sub.bankOrIssuer ?? 'Email Subscription',
          'transaction_date': sub.latestBillingDate.toUtc().toIso8601String(),
          'narration': 'Subscription renewal: ${sub.serviceName}',
          'category': sub.category,
          'is_recurring': true,
          'recurring_frequency': sub.frequency,
          'typical_due_day': sub.typicalDueDay,
          'is_statement': false,
          'updated_at': nowUtc,
        });
      }

      if (payloads.isNotEmpty) {
        // Chunk into batches of 50 for safety
        const int chunkSize = 50;
        for (var i = 0; i < payloads.length; i += chunkSize) {
          final chunk = payloads.sublist(
            i,
            i + chunkSize > payloads.length ? payloads.length : i + chunkSize,
          );
          await client.from('email_extracted_transactions').upsert(
            chunk,
            onConflict: 'user_id,gmail_message_id',
          );
        }
      }

      // 4. Clean up any historical duplicate raw rows in public.email_extracted_transactions
      for (final sub in consolidatedSubs.values) {
        final syntheticMessageId = 'sub_${sub.serviceName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_')}';
        try {
          await client
              .from('email_extracted_transactions')
              .delete()
              .eq('user_id', userId)
              .ilike('merchant_name', sub.serviceName)
              .neq('gmail_message_id', syntheticMessageId);
        } catch (e) {
          debugPrint('[Supabase DB] Error removing duplicate subscription rows: $e');
        }

        // Also upsert into user_recurring_commitments so rhythm calculations stay aligned
        try {
          await upsertRecurringCommitment(
            merchantName: sub.serviceName,
            expectedAmount: sub.expectedAmount,
            category: sub.category,
            typicalDueDay: sub.typicalDueDay,
            frequency: sub.frequency,
            userId: userId,
          );
        } catch (_) {}
      }

      debugPrint('[Supabase DB] Successfully saved ${payloads.length} records to email_extracted_transactions');
      return true;
    } catch (e, stack) {
      debugPrint('[Supabase DB] Error saving email_extracted_transactions: $e\n$stack');
      return false;
    }
  }

  /// Cleans up any duplicate subscription rows in email_extracted_transactions for a user,
  /// ensuring each recurring service has exactly one record.
  Future<void> cleanupDuplicateSubscriptions(String userId) async {
    final client = _effectiveClient;
    if (client == null) return;
    try {
      final rows = await client
          .from('email_extracted_transactions')
          .select('id, merchant_name, gmail_message_id, is_recurring, category')
          .eq('user_id', userId);

      final List<Map<String, dynamic>> subRows = List<Map<String, dynamic>>.from(rows)
          .where((r) => r['is_recurring'] == true || r['category'] == 'Subscription')
          .toList();

      final Map<String, List<Map<String, dynamic>>> byMerchant = {};
      for (final r in subRows) {
        final name = (r['merchant_name'] ?? '').toString().trim().toLowerCase();
        if (name.isNotEmpty) {
          byMerchant.putIfAbsent(name, () => []).add(r);
        }
      }

      for (final entry in byMerchant.entries) {
        final list = entry.value;
        if (list.length > 1) {
          final canonical = list.firstWhere(
            (r) => r['gmail_message_id']?.toString().startsWith('sub_') ?? false,
            orElse: () => list.first,
          );
          final idsToDelete = list
              .where((r) => r['id'] != canonical['id'])
              .map((r) => r['id'].toString())
              .toList();

          if (idsToDelete.isNotEmpty) {
            await client
                .from('email_extracted_transactions')
                .delete()
                .inFilter('id', idsToDelete);
            debugPrint('[Supabase DB] Cleaned up ${idsToDelete.length} duplicates for ${entry.key}');
          }
        }
      }
    } catch (e) {
      debugPrint('[Supabase DB] Error cleaning up duplicate subscriptions: $e');
    }
  }

  /// Clears legacy hardcoded email extracted subscriptions and commitments
  Future<void> clearLegacyExtractedSubscriptions({required String userId}) async {
    final client = _effectiveClient;
    if (client == null) return;
    try {
      await client
          .from('email_extracted_transactions')
          .delete()
          .eq('user_id', userId)
          .like('gmail_message_id', 'sub_%');
      await client
          .from('user_recurring_commitments')
          .delete()
          .eq('user_id', userId)
          .or('merchant_name.eq.Vi,merchant_name.eq.Jio');
      debugPrint('[Supabase DB] Cleared legacy hardcoded subscriptions for $userId');
    } catch (e) {
      debugPrint('[Supabase DB] Error clearing legacy extracted subscriptions: $e');
    }
  }

  /// Fetches saved email transactions from email_extracted_transactions
  Future<List<Map<String, dynamic>>> fetchEmailExtractedTransactions({
    String? userId,
    int limit = 100,
  }) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return [];

    try {
      final res = await client
          .from('email_extracted_transactions')
          .select()
          .eq('user_id', uid)
          .order('transaction_date', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(res);
    } catch (e) {
      debugPrint('[Supabase DB] fetchEmailExtractedTransactions error: $e');
      return [];
    }
  }

  /// Fetches the count of email extracted transactions for a given user
  Future<int> countEmailExtractedTransactions([String? userId]) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return 0;

    try {
      final res = await client
          .from('email_extracted_transactions')
          .select('id')
          .eq('user_id', uid)
          .count(CountOption.exact);
      return res.count;
    } catch (e) {
      debugPrint('[Supabase DB] countEmailExtractedTransactions error: $e');
      return 0;
    }
  }

  /// Uploads a Credit Card Statement PDF to the secure 'statements' Supabase storage bucket,
  /// strictly organized by user_id: `<user_id>/<filename>`
  Future<String?> uploadStatementPdfToStorage({
    required String userId,
    required String filename,
    required Uint8List pdfBytes,
  }) async {
    final client = _effectiveClient;
    if (client == null) return null;

    try {
      // Normalize filename to avoid collision or unsafe characters
      final safeName = filename.replaceAll(RegExp(r'[^a-zA-Z0-9_\-\.]'), '_');
      final storagePath = '$userId/$safeName';

      await client.storage.from('statements').uploadBinary(
            storagePath,
            pdfBytes,
            fileOptions: const FileOptions(
              contentType: 'application/pdf',
              upsert: true,
            ),
          );

      debugPrint('[Supabase Storage] Successfully uploaded statement PDF: $storagePath');
      return storagePath;
    } catch (e, stack) {
      debugPrint('[Supabase Storage] Error uploading statement PDF: $e\n$stack');
      return null;
    }
  }

  /// Creates a temporary signed URL to download or view a private statement PDF
  Future<String?> getStatementPdfSignedUrl({
    required String storagePath,
    int expiresInSeconds = 3600,
  }) async {
    final client = _effectiveClient;
    if (client == null) return null;

    try {
      final signedUrl = await client.storage.from('statements').createSignedUrl(
            storagePath,
            expiresInSeconds,
          );
      return signedUrl;
    } catch (e) {
      debugPrint('[Supabase Storage] Error getting signed URL for $storagePath: $e');
      return null;
    }
  }

  /// Downloads a statement PDF from the 'statements' bucket as raw bytes
  Future<Uint8List?> downloadStatementPdfFromStorage({
    required String storagePath,
  }) async {
    final client = _effectiveClient;
    if (client == null) return null;

    try {
      final bytes = await client.storage.from('statements').download(storagePath);
      return bytes;
    } catch (e) {
      debugPrint('[Supabase Storage] Error downloading statement PDF $storagePath: $e');
      return null;
    }
  }

  // ===========================================================================
  // 12. CREDIT CARD STATEMENT TRANSACTIONS
  // ===========================================================================

  /// Saves itemized credit card transactions into public.credit_card_transactions,
  /// guaranteeing idempotent upserts keyed on (user_id, reference_id).
  Future<bool> saveCreditCardTransactions({
    required List<SliceCreditCardTransaction> transactions,
    required String userId,
    String? statementId,
    String? statementPdfPath,
    String? cardLast4,
    String? billingCycle,
    DateTime? dueDate,
  }) async {
    final client = _effectiveClient;
    if (client == null || transactions.isEmpty) return false;

    try {
      final payloads = transactions
          .map((t) => t.toMap(
                userId: userId,
                statementId: statementId,
                statementPdfPath: statementPdfPath,
                cardLast4: cardLast4,
                billingCycle: billingCycle,
                dueDate: dueDate,
              ))
          .toList();

      const int chunkSize = 50;
      for (var i = 0; i < payloads.length; i += chunkSize) {
        final chunk = payloads.sublist(
          i,
          i + chunkSize > payloads.length ? payloads.length : i + chunkSize,
        );
        await client.from('credit_card_transactions').upsert(
              chunk,
              onConflict: 'user_id,reference_id',
            );
      }

      debugPrint(
        '[Supabase DB] Successfully saved ${payloads.length} records to credit_card_transactions',
      );
      return true;
    } catch (e, stack) {
      debugPrint('[Supabase DB] Error saving credit_card_transactions: $e\n$stack');
      return false;
    }
  }

  /// Fetches saved credit card transactions from public.credit_card_transactions
  Future<List<Map<String, dynamic>>> fetchCreditCardTransactions({
    required String userId,
    String? cardLast4,
    String? statementId,
    int limit = 100,
    int offset = 0,
  }) async {
    final client = _effectiveClient;
    if (client == null) return [];

    try {
      var query = client
          .from('credit_card_transactions')
          .select()
          .eq('user_id', userId);

      if (statementId != null && statementId.isNotEmpty) {
        query = query.eq('statement_id', statementId);
      } else if (cardLast4 != null && cardLast4.isNotEmpty) {
        query = query.eq('card_last4', cardLast4);
      }

      final res = await query
          .order('transaction_date', ascending: false)
          .range(offset, offset + limit - 1);

      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching credit_card_transactions: $e');
      return [];
    }
  }

  /// Returns total count of credit card transactions for a user
  Future<int> countCreditCardTransactions(String userId) async {
    final client = _effectiveClient;
    if (client == null) return 0;

    try {
      final res = await client
          .from('credit_card_transactions')
          .select('id')
          .eq('user_id', userId);
      return (res as List).length;
    } catch (e) {
      debugPrint('[Supabase DB] Error counting credit_card_transactions: $e');
      return 0;
    }
  }

  // ===========================================================================
  // 11. REMINDERS & SERVERLESS ML CLASSIFICATION (MODAL PIPELINE)
  // ===========================================================================

  /// Dispatches email messages to the serverless ML classification pipeline
  /// running on Supabase Edge Function (`classify-emails`), which invokes Modal.com
  /// (GLiClass + GLiNER) and directly persists the detected reminders in Postgres.
  Future<Map<String, dynamic>> classifyEmailsViaBackend({
    required List<Map<String, dynamic>> messages,
    String? timezone,
    bool includeDecisions = false,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw Exception('Supabase client is not configured or authenticated.');
    }

    final response = await client.functions.invoke(
      'classify-emails',
      body: {
        'messages': messages,
        'timezone': timezone ?? 'Asia/Kolkata',
        'include_decisions': includeDecisions,
      },
    );

    if (response.status >= 400) {
      final data = response.data;
      throw Exception(
        'Serverless email classification failed (${response.status}): ${data is Map ? data['message'] ?? data['error'] ?? data : data}',
      );
    }

    return (response.data is Map<String, dynamic>)
        ? response.data as Map<String, dynamic>
        : Map<String, dynamic>.from(response.data as Map);
  }

  /// Fetches reminders detected and persisted by the serverless ML pipeline
  Future<List<ReminderModel>> fetchReminders({
    String? userId,
    bool includeDismissed = false,
  }) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return [];

    try {
      var query = client
          .from('reminders')
          .select()
          .eq('user_id', uid);

      if (!includeDismissed) {
        query = query.eq('is_dismissed', false);
      }

      final res = await query.order('due_date', ascending: true, nullsFirst: false);
      return (res as List)
          .map((row) => ReminderModel.fromMap(Map<String, dynamic>.from(row as Map)))
          .toList();
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching reminders: $e');
      return [];
    }
  }

  /// Updates dismissal status of a reminder
  Future<bool> dismissReminder(String reminderId, {bool isDismissed = true}) async {
    final client = _effectiveClient;
    if (client == null) return false;

    try {
      await client
          .from('reminders')
          .update({'is_dismissed': isDismissed, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('reminder_id', reminderId);
      return true;
    } catch (e) {
      debugPrint('[Supabase DB] Error dismissing reminder $reminderId: $e');
      return false;
    }
  }

  /// Toggles whether a reminder has been paid / actioned by the user
  Future<bool> toggleReminderActioned(String reminderId, {required bool isActioned}) async {
    final client = _effectiveClient;
    if (client == null) return false;

    try {
      await client
          .from('reminders')
          .update({'is_actioned': isActioned, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('reminder_id', reminderId);
      return true;
    } catch (e) {
      debugPrint('[Supabase DB] Error updating actioned status for $reminderId: $e');
      return false;
    }
  }

  // ===========================================================================
  // 13. STATEMENT INTELLIGENCE API (MODAL OCR & GEMINI PIPELINE)
  // ===========================================================================

  /// Submits and processes a statement PDF via the Supabase Edge Function (`process-statement`).
  /// Invokes Modal.com (Tesseract OCR + multi-engine geometry + Gemini Flash Lite) in the cloud,
  /// reconciles running balances, and persists transactions to `bank_transactions` or `credit_card_transactions`.
  Future<Map<String, dynamic>> processStatementViaBackend({
    required String storagePath,
    String? filename,
    String? password,
    String? messageId,
    bool waitForCompletion = true,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw Exception('Supabase client is not configured or authenticated.');
    }

    final response = await client.functions.invoke(
      'process-statement',
      body: {
        'action': 'submit',
        'storage_path': storagePath,
        'filename': filename,
        'password': password,
        'message_id': messageId,
        'wait_for_completion': waitForCompletion,
      },
    );

    final data = response.data;
    if (response.status >= 400 || (data is Map && data['error'] != null)) {
      final msg = (data is Map ? (data['message'] ?? data['error']) : null) ??
          'Statement extraction failed with HTTP status ${response.status}';
      throw Exception(msg);
    }

    if (data is Map<String, dynamic>) {
      return data;
    }
    return Map<String, dynamic>.from(data as Map);
  }

  /// Polls the status of an ongoing statement extraction job
  Future<Map<String, dynamic>> pollStatementJob(String jobId) async {
    final client = _effectiveClient;
    if (client == null) {
      throw Exception('Supabase client is not configured or authenticated.');
    }

    final response = await client.functions.invoke(
      'process-statement',
      body: {
        'action': 'poll',
        'job_id': jobId,
      },
    );

    final data = response.data;
    if (response.status >= 400 || (data is Map && data['error'] != null)) {
      final msg = (data is Map ? (data['message'] ?? data['error']) : null) ??
          'Statement polling failed with HTTP status ${response.status}';
      throw Exception(msg);
    }

    if (data is Map<String, dynamic>) {
      return data;
    }
    return Map<String, dynamic>.from(data as Map);
  }

  /// Fetches a statement job record directly from public.statement_jobs
  Future<Map<String, dynamic>?> fetchStatementJob(String jobId) async {
    final client = _effectiveClient;
    if (client == null) return null;

    try {
      final res = await client
          .from('statement_jobs')
          .select()
          .eq('job_id', jobId)
          .maybeSingle();
      return res != null ? Map<String, dynamic>.from(res) : null;
    } catch (e) {
      debugPrint('[Supabase DB] Error fetching statement job: $e');
      return null;
    }
  }
}

class _ConsolidatedSubscription {
  final String serviceName;
  double expectedAmount;
  final String currency;
  int typicalDueDay;
  final String frequency;
  DateTime latestBillingDate;
  String? cardLast4;
  String? bankOrIssuer;
  String category;

  _ConsolidatedSubscription({
    required this.serviceName,
    required this.expectedAmount,
    required this.currency,
    required this.typicalDueDay,
    required this.frequency,
    required this.latestBillingDate,
    this.cardLast4,
    this.bankOrIssuer,
    this.category = 'Subscription',
  });
}


