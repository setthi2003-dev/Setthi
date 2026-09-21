import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
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
      final res = await client
          .from('profiles')
          .select()
          .eq('id', uid)
          .maybeSingle();
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

  /// Persists a batch of transactions collected from the Setu AA gateway into public.bank_transactions.
  /// Uses idempotent upsert on (user_id, txn_id) to avoid duplicates while updating current balances.
  Future<void> saveBankTransactions({
    required List<BankTransaction> transactions,
    String? accountId,
  }) async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null || transactions.isEmpty) return;

    try {
      if (!MerchantCategoryRegistry.instance.isInitializedFromRemote) {
        await fetchMerchantCategories();
      }

      final rows = transactions.map((t) {
        final match = MerchantCategoryRegistry.instance.findMatch(t.narration);
        final category = t.category ?? match?.category; // null if unmatched
        final cleanName = t.cleanMerchantName;

        return <String, dynamic>{
          'user_id': uid,
          'account_id': ?accountId,
          'txn_id': t.txnId,
          'type': t.type.value,
          'mode': t.mode,
          'amount': t.amount,
          'current_balance': t.currentBalance,
          'transaction_timestamp': t.transactionTimestamp.toUtc().toIso8601String(),
          'narration': t.narration,
          'clean_merchant_name': cleanName,
          'category': category,
        };
      }).toList();

      await client.from('bank_transactions').upsert(
            rows,
            onConflict: 'user_id,txn_id',
          );

      debugPrint(
        '[Supabase DB] Successfully persisted ${transactions.length} transactions in Supabase!',
      );
    } catch (e) {
      debugPrint('[Supabase DB] Error saving bank transactions: $e');
    }
  }

  /// Fetches stored bank transactions for the current user from public.bank_transactions with pagination.
  Future<List<BankTransaction>> fetchStoredTransactions({
    int? limit,
    int? offset,
  }) async {
    final client = _effectiveClient;
    final uid = currentUserId;
    if (client == null || uid == null) return [];

    try {
      var query = client
          .from('bank_transactions')
          .select()
          .eq('user_id', uid)
          .order('transaction_timestamp', ascending: false);

      if (limit != null) {
        final start = offset ?? 0;
        final end = start + limit - 1;
        query = query.range(start, end);
      }

      final res = await query;
      final list = List<Map<String, dynamic>>.from(res);
      return list.map((row) {
        return BankTransaction(
          txnId: row['txn_id']?.toString() ?? '',
          type: TransactionType.fromString(row['type']?.toString() ?? 'DEBIT'),
          mode: row['mode']?.toString() ?? 'UPI',
          amount: (row['amount'] as num?)?.toDouble() ?? 0.0,
          currentBalance: (row['current_balance'] as num?)?.toDouble() ?? 0.0,
          transactionTimestamp: DateTime.tryParse(
                row['transaction_timestamp']?.toString() ?? '',
              ) ??
              DateTime.now(),
          narration: row['narration']?.toString() ?? '',
          category: row['category']?.toString(),
          precomputedMerchantName: row['clean_merchant_name']?.toString(),
        );
      }).toList();
    } catch (e) {
      debugPrint('[Supabase DB] Error loading stored transactions: $e');
      return [];
    }
  }

  /// Returns the total count of stored transactions for the current user
  Future<int> countStoredTransactions() async {
    final client = _effectiveClient;
    final uid = currentUserId;
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

  /// Triggers server-side Setu AA data session creation, polling, ReBIT parsing,
  /// and database upserts via the `sync-transactions` Supabase Edge Function.
  Future<Map<String, dynamic>> triggerBackendSync({String? consentId}) async {
    final client = _effectiveClient;
    if (client == null) {
      throw Exception('Supabase client is not configured or authenticated.');
    }

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
}
