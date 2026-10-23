import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../config/supabase_config.dart';
import '../models/chat_message_model.dart';
import '../models/merchant_category_model.dart';
import '../models/transaction_model.dart';
import 'setu_aa_service.dart';

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

  /// Fetches stored bank transactions for the current user from public.bank_transactions with pagination.
  Future<List<BankTransaction>> fetchStoredTransactions({
    String? userId,
    int? limit,
    int? offset,
  }) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return [];

    try {
      var query = client
          .from('bank_transactions')
          .select()
          .eq('user_id', uid)
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
      return list.map((row) => BankTransaction.fromJson(row)).toList();
    } catch (e) {
      debugPrint('[Supabase DB] Error loading stored transactions: $e');
      return [];
    }
  }

  /// Returns the total count of stored transactions for the current user
  Future<int> countStoredTransactions([String? userId]) async {
    final client = _effectiveClient;
    final uid = userId ?? currentUserId;
    if (client == null || uid == null) return 0;

    try {
      final res = await client
          .from('bank_transactions')
          .select('txn_id')
          .eq('user_id', uid);
      return (res as List).length;
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
}
