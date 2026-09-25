import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@^2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const IGNORED_BANKING_TOKENS = new Set([
  "UPI", "CARD", "CASH", "NEFT", "RTGS", "IMPS", "ATM", "POS",
  "ACH", "ECS", "NACH", "CR", "DR", "DE", "WD", "CW", "FT",
  "P2A", "P2P", "TRF", "BIL", "INB", "MB", "MOB", "REV", "RET",
  "CHQ", "CLR", "PAYMENT", "TRANSFER", "PURCHASE", "DEPOSIT",
  "WITHDRAWAL", "SETU", "REFUND", "BANK",
  "OTHER", "OTHERS", "MISC",
]);

function capitalizeWords(input: string): string {
  return input
    .split(/\s+/)
    .filter((w) => w.length > 0)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
    .join(" ");
}

function cleanMerchantName(narration: string, brandKeywords: Map<string, string>): string {
  if (!narration || narration.trim().length === 0) {
    return "Transaction";
  }

  const upperNarration = narration.toUpperCase();

  // 1. Check known brand keywords from database registry
  for (const [keyword, cleanName] of brandKeywords.entries()) {
    if (upperNarration.includes(keyword.toUpperCase())) {
      return cleanName;
    }
  }

  // 2. Structured slash-separated Indian banking narrations:
  // e.g. "CARD/DE/995415932503/Amira Salvi/ANIJ/08764285"
  //      "CASH/CR/467366268432/Sara Dave/ZTAE/35521479"
  //      "UPI/4293021984/Swiggy/swiggy@icici/Payment"
  if (narration.includes("/")) {
    const segments = narration.split("/");
    for (const rawSegment of segments) {
      let candidate = rawSegment.trim();
      if (!candidate || /^[0-9]+$/.test(candidate)) continue;
      if (IGNORED_BANKING_TOKENS.has(candidate.toUpperCase())) continue;

      if (candidate.includes("@")) {
        candidate = candidate.split("@")[0].trim();
      }

      if (/[a-zA-Z]/.test(candidate) && candidate.length >= 3) {
        return capitalizeWords(candidate);
      }
    }
  }

  // 3. Fallback: clean numbers, slashes, dashes, ignoring banking tokens
  const sanitized = narration
    .replace(/[0-9]+/g, "")
    .replace(/[/_\-]/g, " ")
    .trim();

  if (sanitized.length > 0) {
    const tokens = sanitized
      .split(/\s+/)
      .filter((s) => s.length > 2 && !IGNORED_BANKING_TOKENS.has(s.toUpperCase()))
      .slice(0, 2);

    if (tokens.length > 0) {
      return capitalizeWords(tokens.join(" "));
    }
  }

  return "Transaction";
}

interface ParsedTxn {
  txnId: string;
  type: "DEBIT" | "CREDIT";
  mode: string;
  amount: number;
  currentBalance: number;
  transactionTimestamp: string;
  narration: string;
  cleanMerchantName: string;
  rawData: Record<string, unknown>;
}

interface ParsedAccount {
  maskedAccNumber: string;
  fipId: string;
  accountType: string;
  currentBalance: number;
  currency: string;
  linkRefNumber: string | null;
  transactions: ParsedTxn[];
}

function parseRebitPayload(
  payload: Record<string, unknown>,
  brandKeywords: Map<string, string>
): ParsedAccount[] {
  const accounts: ParsedAccount[] = [];

  const topLevelItems: unknown[] = [];
  if (Array.isArray(payload.fips)) topLevelItems.push(...payload.fips);
  if (Array.isArray(payload.payload)) topLevelItems.push(...payload.payload);
  if (Array.isArray(payload.fipData)) topLevelItems.push(...payload.fipData);
  if (Array.isArray(payload.data)) topLevelItems.push(...payload.data);
  if (topLevelItems.length === 0) topLevelItems.push(payload);

  for (const item of topLevelItems) {
    if (!item || typeof item !== "object") continue;
    const p = item as Record<string, unknown>;

    const accountNodes: unknown[] = [];
    if (Array.isArray(p.accounts)) accountNodes.push(...p.accounts);
    else if (Array.isArray(p.data)) accountNodes.push(...p.data);
    else accountNodes.push(p);

    for (const node of accountNodes) {
      if (!node || typeof node !== "object") continue;
      const d = node as Record<string, unknown>;

      const rawData = (d.data ?? d.decrypted ?? d) as Record<string, unknown>;
      const account =
        (rawData.account as Record<string, unknown>) ??
        (rawData.Account as Record<string, unknown>) ??
        (d.account as Record<string, unknown>) ??
        (d.Account as Record<string, unknown>) ??
        rawData;

      const maskedAccNumber = String(
        account.maskedAccNumber ??
          account.MaskedAccNumber ??
          account.accountNumber ??
          account.maskedAccountNumber ??
          d.maskedAccNumber ??
          "XXXXXXXX8167"
      );

      const fipId = String(p.fipId ?? p.fipID ?? d.fipId ?? "setu-fip-2");
      const accountType = String(
        account.type ?? account.accType ?? account.accountType ?? "SAVINGS"
      );
      const currency = String(account.currency ?? account.Currency ?? "INR");
      const linkRefNumber = d.linkRefNumber ? String(d.linkRefNumber) : null;

      // Extract balance from summary
      const summary =
        (account.summary as Record<string, unknown>) ??
        (account.Summary as Record<string, unknown>);
      let currentBalance = 0.0;
      if (summary) {
        const balVal =
          summary.currentBalance ??
          summary.CurrentBalance ??
          summary.balance ??
          summary.Balance;
        if (balVal !== undefined && balVal !== null) {
          const cleaned = String(balVal).replace(/[^\d.-]/g, "");
          const parsed = parseFloat(cleaned);
          if (!isNaN(parsed)) currentBalance = parsed;
        }
      }

      // Extract transactions list
      const txnsObj =
        account.transactions ??
        account.Transactions ??
        account.txns ??
        account.Txns;

      let rawTxns: unknown[] = [];
      if (Array.isArray(txnsObj)) {
        rawTxns = txnsObj;
      } else if (txnsObj && typeof txnsObj === "object") {
        const tMap = txnsObj as Record<string, unknown>;
        const list =
          tMap.transaction ??
          tMap.Transaction ??
          tMap.txns ??
          tMap.Txns ??
          tMap.item ??
          tMap.items;
        if (Array.isArray(list)) rawTxns = list;
      }

      const parsedTxns: ParsedTxn[] = [];
      for (const raw of rawTxns) {
        if (!raw || typeof raw !== "object") continue;
        const t = raw as Record<string, unknown>;

        const txnId = String(
          t.txnId ?? t.TxnId ?? t.transactionId ?? t.id ?? crypto.randomUUID()
        );

        let typeStr = String(t.type ?? t.Type ?? "DEBIT").toUpperCase();
        if (typeStr === "CR" || typeStr.includes("CREDIT")) {
          typeStr = "CREDIT";
        } else {
          typeStr = "DEBIT";
        }

        const modeStr = String(t.mode ?? t.Mode ?? "UPI");

        const rawAmount = t.amount ?? t.Amount ?? 0;
        const amount = Math.abs(
          parseFloat(String(rawAmount).replace(/[^\d.-]/g, "")) || 0
        );

        let txnBal = currentBalance;
        const rawTxnBal =
          t.currentBalance ?? t.CurrentBalance ?? t.balance ?? t.Balance;
        if (rawTxnBal !== undefined && rawTxnBal !== null) {
          const parsedBal = parseFloat(
            String(rawTxnBal).replace(/[^\d.-]/g, "")
          );
          if (!isNaN(parsedBal)) txnBal = parsedBal;
        }

        let timestampStr = String(
          t.transactionTimestamp ??
            t.TransactionTimestamp ??
            t.timestamp ??
            t.date ??
            t.valueDate ??
            new Date().toISOString()
        );
        const parsedDate = new Date(timestampStr);
        if (isNaN(parsedDate.getTime())) {
          timestampStr = new Date().toISOString();
        } else {
          timestampStr = parsedDate.toISOString();
        }

        const narration = String(t.narration ?? t.Narration ?? t.description ?? "");
        const cleanName = cleanMerchantName(narration, brandKeywords);

        parsedTxns.push({
          txnId,
          type: typeStr as "DEBIT" | "CREDIT",
          mode: modeStr,
          amount,
          currentBalance: txnBal,
          transactionTimestamp: timestampStr,
          narration,
          cleanMerchantName: cleanName,
          rawData: t,
        });
      }

      // Sort newest first
      parsedTxns.sort(
        (a, b) =>
          new Date(b.transactionTimestamp).getTime() -
          new Date(a.transactionTimestamp).getTime()
      );

      accounts.push({
        maskedAccNumber,
        fipId,
        accountType,
        currentBalance,
        currency,
        linkRefNumber,
        transactions: parsedTxns,
      });
    }
  }

  return accounts;
}

interface VaultCredentials {
  clientId: string;
  clientSecret: string;
  productInstanceId: string;
  baseUrl: string;
  redirectUrl: string;
}

/// Retrieves Setu Account Aggregator API credentials exclusively from Supabase Vault
async function getSetuCredentialsFromVault(
  supabase: SupabaseClient
): Promise<VaultCredentials> {
  const { data, error } = await supabase.rpc("get_vault_secrets", {
    secret_names: [
      "SETU_CLIENT_ID",
      "SETU_CLIENT_SECRET",
      "SETU_PRODUCT_INSTANCE_ID",
      "SETU_BASE_URL",
      "SETU_REDIRECT_URL",
    ],
  });

  if (error || !data || !Array.isArray(data) || data.length === 0) {
    throw new Error(
      `Failed to retrieve Setu secrets from Supabase Vault: ${error?.message ?? "Empty secret response"}`
    );
  }

  const secretMap = new Map<string, string>();
  for (const row of data) {
    if (row.name && row.secret) {
      secretMap.set(row.name, row.secret);
    }
  }

  const clientId = secretMap.get("SETU_CLIENT_ID");
  const clientSecret = secretMap.get("SETU_CLIENT_SECRET");
  const productInstanceId = secretMap.get("SETU_PRODUCT_INSTANCE_ID");
  const baseUrl = secretMap.get("SETU_BASE_URL") || "https://fiu-sandbox.setu.co";
  const redirectUrl = secretMap.get("SETU_REDIRECT_URL") || "https://www.joinmandala.in/";

  if (!clientId || !clientSecret || !productInstanceId) {
    throw new Error(
      "Incomplete Setu credentials in Supabase Vault. Missing clientId, clientSecret, or productInstanceId."
    );
  }

  return {
    clientId,
    clientSecret,
    productInstanceId,
    baseUrl,
    redirectUrl,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // 1. Parse Request Payload
    let body: Record<string, unknown> = {};
    try {
      const parsed = await req.json();
      if (parsed && typeof parsed === "object") {
        body = parsed as Record<string, unknown>;
      }
    } catch (_) {
      // Body may be empty if called without payload
    }

    // 2. Verify Authorization JWT
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) {
      return new Response(
        JSON.stringify({ error: "Missing Authorization bearer token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let user: { id: string } | null = null;
    if (token === serviceRoleKey) {
      const targetUserId = String(body.userId ?? "");
      if (!targetUserId) {
        return new Response(
          JSON.stringify({ error: "Missing userId when authenticating with service_role" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      user = { id: targetUserId };
    } else {
      const {
        data: { user: authUser },
        error: userError,
      } = await supabase.auth.getUser(token);

      if (userError || !authUser) {
        return new Response(
          JSON.stringify({ error: "Unauthorized", details: userError?.message }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      user = authUser;
    }

    const action = String(body.action ?? "sync-transactions").toLowerCase();

    // 3. Retrieve Setu API Keys exclusively from Supabase Vault
    const vault = await getSetuCredentialsFromVault(supabase);

    const setuHeaders = {
      "Content-Type": "application/json",
      "x-client-id": vault.clientId,
      "x-client-secret": vault.clientSecret,
      "x-product-instance-id": vault.productInstanceId,
    };

    // =========================================================================
    // ACTION: create-consent
    // Initiates consent directly with Setu using Vault keys
    // =========================================================================
    if (action === "create-consent") {
      const rawPhone = String(body.mobileNumber ?? "").trim();
      let cleanPhone = rawPhone.replace(/\D/g, "");
      if (cleanPhone.length === 12 && cleanPhone.startsWith("91")) {
        cleanPhone = cleanPhone.substring(2);
      }
      const vua = cleanPhone.includes("@") ? cleanPhone : `${cleanPhone}@onemoney`;
      const fromDate = "2020-01-01T00:00:00Z";
      const toDate = new Date().toISOString();

      const consentPayload = {
        consentDuration: { unit: "MONTH", value: "3" },
        vua,
        dataRange: {
          from: fromDate,
          to: toDate,
        },
        consentMode: "STORE",
        consentTypes: ["TRANSACTIONS", "SUMMARY", "PROFILE"],
        fetchType: "ONETIME",
        redirectUrl: vault.redirectUrl,
      };

      console.log(`[sync-transactions] Creating consent for VUA ${vua}...`);
      const consentRes = await fetch(`${vault.baseUrl}/v2/consents`, {
        method: "POST",
        headers: setuHeaders,
        body: JSON.stringify(consentPayload),
      });

      const consentBody = await consentRes.text();
      if (!consentRes.ok) {
        console.error(`[sync-transactions] Consent creation failed (${consentRes.status}): ${consentBody}`);
        return new Response(
          JSON.stringify({ error: `Setu consent creation failed: ${consentBody}` }),
          { status: consentRes.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const cJson = JSON.parse(consentBody);
      const consentId = String(cJson.id ?? "");
      const consentUrl = String(cJson.url ?? "");

      // Record pending consent in database
      await supabase.from("aa_consents").upsert(
        {
          user_id: user.id,
          consent_id: consentId,
          status: "PENDING",
          vua,
          valid_from: fromDate,
          valid_to: toDate,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "consent_id" }
      );

      return new Response(
        JSON.stringify({ consentId, url: consentUrl }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // =========================================================================
    // ACTION: check-consent
    // Verifies consent status directly with Setu using Vault keys
    // =========================================================================
    if (action === "check-consent") {
      const consentId = String(body.consentId ?? "");
      if (!consentId) {
        return new Response(
          JSON.stringify({ error: "Missing consentId parameter" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const cRes = await fetch(`${vault.baseUrl}/v2/consents/${consentId}`, {
        method: "GET",
        headers: setuHeaders,
      });

      if (!cRes.ok) {
        const errText = await cRes.text();
        return new Response(
          JSON.stringify({ error: `Failed to check consent status: ${errText}` }),
          { status: cRes.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const cJson = await cRes.json();
      const status = String(cJson.status ?? "PENDING").toUpperCase();

      if (status === "ACTIVE") {
        await supabase
          .from("aa_consents")
          .update({ status: "ACTIVE", updated_at: new Date().toISOString() })
          .eq("consent_id", consentId);
      }

      return new Response(
        JSON.stringify({ status }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // =========================================================================
    // ACTION: sync-transactions (default)
    // Resolves consent, creates Setu data session, polls ReBIT data, and upserts
    // =========================================================================
    let activeConsentId = body.consentId ? String(body.consentId) : undefined;
    if (!activeConsentId) {
      const { data: consentRow, error: consentErr } = await supabase
        .from("aa_consents")
        .select("consent_id")
        .eq("user_id", user.id)
        .eq("status", "ACTIVE")
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      if (consentErr || !consentRow?.consent_id) {
        return new Response(
          JSON.stringify({
            error: "No active Account Aggregator consent found for this user. Please link your bank account first.",
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      activeConsentId = consentRow.consent_id;
    }

    // Guarantee the consent row exists in aa_consents to satisfy bank_accounts FK constraint
    await supabase.from("aa_consents").upsert(
      {
        user_id: user.id,
        consent_id: activeConsentId,
        status: "ACTIVE",
        updated_at: new Date().toISOString(),
      },
      { onConflict: "consent_id" }
    );

    // Attempt to inspect consent detail from Setu to obtain approved FIDataRange
    let consentFromDate: string | null = null;
    let consentToDate: string | null = null;
    try {
      const cRes = await fetch(`${vault.baseUrl}/v2/consents/${activeConsentId}`, {
        method: "GET",
        headers: setuHeaders,
      });
      if (cRes.ok) {
        const cJson = await cRes.json();
        const dr = cJson?.detail?.dataRange ?? cJson?.dataRange ?? cJson?.detail?.FIDataRange;
        if (dr?.from && dr?.to) {
          consentFromDate = String(dr.from);
          consentToDate = String(dr.to);
        }
      }
    } catch (_) {}

    // Candidate ranges: prioritize approved consent range, then mock sandbox ranges (2021-2024)
    const candidateRanges: Array<{ from: string; to: string }> = [];
    if (consentFromDate && consentToDate) {
      candidateRanges.push({ from: consentFromDate, to: consentToDate });
    }
    candidateRanges.push(
      { from: "2021-01-01T00:00:00.000Z", to: "2024-12-31T23:59:59.000Z" },
      { from: "2020-01-01T00:00:00.000Z", to: "2024-12-31T23:59:59.000Z" },
      { from: "2020-01-01T00:00:00.000Z", to: new Date().toISOString() }
    );

    let sessionId = "";
    let lastSessionError = "";

    for (const range of candidateRanges) {
      console.log(
        `[sync-transactions] Creating data session for ${activeConsentId} (${range.from} to ${range.to})...`
      );

      const sessionRes = await fetch(`${vault.baseUrl}/v2/sessions`, {
        method: "POST",
        headers: setuHeaders,
        body: JSON.stringify({
          consentId: activeConsentId,
          dataRange: range,
          format: "json",
        }),
      });

      const sessionBody = await sessionRes.text();
      console.log(
        `[sync-transactions] Data session response (${sessionRes.status}): ${sessionBody}`
      );

      if (sessionRes.ok) {
        try {
          const sJson = JSON.parse(sessionBody);
          if (sJson.id) {
            sessionId = String(sJson.id);
            break;
          }
        } catch (_) {}
      }

      lastSessionError = sessionBody;

      if (
        sessionBody.includes("Consent use exceeded") ||
        sessionBody.includes("Consent expired") ||
        sessionBody.includes("Consent revoked")
      ) {
        // Mark consent expired in database
        await supabase
          .from("aa_consents")
          .update({ status: "EXPIRED", updated_at: new Date().toISOString() })
          .eq("consent_id", activeConsentId);

        return new Response(
          JSON.stringify({
            error: "Consent has expired or reached usage limits. Please reconnect your bank.",
            code: "CONSENT_EXPIRED",
          }),
          { status: 410, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // If range mismatch, continue to next candidate
      if (
        sessionBody.includes("not within the consent") ||
        sessionBody.includes("FIDataRange")
      ) {
        console.log(
          "[sync-transactions] Range mismatch. Trying next fallback range..."
        );
        continue;
      }
    }

    if (!sessionId) {
      return new Response(
        JSON.stringify({
          error: "Failed to create Setu AA data session",
          details: lastSessionError,
        }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 4. Poll Data Session Until Ready
    const maxRetries = 10;
    const retryDelayMs = 2000;
    let decryptedPayload: Record<string, unknown> | null = null;

    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      console.log(
        `[sync-transactions] Polling session ${sessionId} (attempt ${attempt}/${maxRetries})...`
      );

      const pollRes = await fetch(`${vault.baseUrl}/v2/sessions/${sessionId}`, {
        method: "GET",
        headers: setuHeaders,
      });

      if (!pollRes.ok) {
        const errText = await pollRes.text();
        throw new Error(`Polling failed (${pollRes.status}): ${errText}`);
      }

      const pollJson = (await pollRes.json()) as Record<string, unknown>;
      const status = String(pollJson.status ?? "").toUpperCase();
      console.log(`[sync-transactions] Session ${sessionId} status: ${status}`);

      if (status === "COMPLETED" || status === "PARTIAL") {
        decryptedPayload = pollJson;
        break;
      } else if (status === "FAILED") {
        throw new Error(`Setu data session failed with status FAILED`);
      }

      if (attempt < maxRetries) {
        await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
      }
    }

    if (!decryptedPayload) {
      return new Response(
        JSON.stringify({ error: "Data session polling timed out" }),
        { status: 504, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 5. Query Known Merchant Category Brands for Narration Cleaning
    const brandKeywords = new Map<string, string>();
    try {
      const { data: catRows } = await supabase
        .from("merchant_categories")
        .select("keyword, clean_name");
      if (catRows) {
        for (const r of catRows) {
          if (r.keyword && r.clean_name) {
            brandKeywords.set(r.keyword, r.clean_name);
          }
        }
      }
    } catch (_) {
      console.log("[sync-transactions] Warning: could not load merchant_categories");
    }

    // 6. Parse ReBIT Payload
    const parsedAccounts = parseRebitPayload(decryptedPayload, brandKeywords);
    console.log(
      `[sync-transactions] Extracted ${parsedAccounts.length} account(s)`
    );

    let totalTxnsUpserted = 0;
    let primaryAccountId = "";
    let latestBalance = 0.0;

    for (const acc of parsedAccounts) {
      // Upsert bank account
      const { data: accRow, error: accErr } = await supabase
        .from("bank_accounts")
        .upsert(
          {
            user_id: user.id,
            consent_id: activeConsentId,
            fip_id: acc.fipId,
            masked_acc_number: acc.maskedAccNumber,
            link_ref_number: acc.linkRefNumber,
            account_type: acc.accountType,
            current_balance: acc.currentBalance,
            currency: acc.currency,
            status: "ACTIVE",
            updated_at: new Date().toISOString(),
          },
          { onConflict: "user_id,masked_acc_number,fip_id" }
        )
        .select("id")
        .single();

      if (accErr) {
        console.error(
          `[sync-transactions] Error upserting bank_account: ${JSON.stringify(accErr)}`
        );
      }

      const accountId = accRow?.id ?? null;
      if (!primaryAccountId && accountId) {
        primaryAccountId = accountId;
        latestBalance = acc.currentBalance;
      }

      // Upsert transactions
      if (acc.transactions.length > 0) {
        const txnRows = acc.transactions.map((t) => ({
          user_id: user.id,
          account_id: accountId,
          txn_id: t.txnId,
          type: t.type,
          mode: t.mode,
          amount: t.amount,
          current_balance: t.currentBalance,
          transaction_timestamp: t.transactionTimestamp,
          narration: t.narration,
          clean_merchant_name: t.cleanMerchantName,
          category: null,
          raw_data: t.rawData,
        }));

        // Batch upsert in chunks of 50
        const chunkSize = 50;
        for (let i = 0; i < txnRows.length; i += chunkSize) {
          const chunk = txnRows.slice(i, i + chunkSize);
          const { error: txnErr } = await supabase
            .from("bank_transactions")
            .upsert(chunk, { onConflict: "user_id,txn_id" });

          if (txnErr) {
            console.error(
              `[sync-transactions] Error upserting bank_transactions chunk: ${JSON.stringify(txnErr)}`
            );
          } else {
            totalTxnsUpserted += chunk.length;
          }
        }
      }
    }

    // 7. Run Habit Classification & Spend Tier Enrichment
    try {
      console.log(`[sync-transactions] Running classify_transactions for user ${user.id}...`);
      await supabase.rpc("classify_transactions", { p_user_id: user.id });
    } catch (classifyErr) {
      console.error(`[sync-transactions] Error in classify_transactions:`, classifyErr);
    }

    // 8. Run Automated Nudge Evaluation
    try {
      console.log(`[sync-transactions] Evaluating proactive AI nudges for user ${user.id}...`);

      // Determine batch temporal anchor:
      // If transactions occurred within the last 7 days of Date.now(), it's live -> anchor = Date.now().
      // Otherwise (historical statement sync or sandbox data), anchor = latest transaction in the batch!
      let batchAnchorMs = 0;
      let hasLiveTxn = false;
      const sevenDaysAgoMs = Date.now() - 7 * 24 * 60 * 60 * 1000;

      for (const acc of parsedAccounts) {
        for (const t of acc.transactions) {
          const tMs = new Date(t.transactionTimestamp).getTime();
          if (tMs >= sevenDaysAgoMs && tMs <= Date.now()) {
            hasLiveTxn = true;
          }
          if (tMs > batchAnchorMs) {
            batchAnchorMs = tMs;
          }
        }
      }
      if (!hasLiveTxn && batchAnchorMs > 0) {
        console.log(`[sync-transactions] Historical/Sandbox sync detected. Anchoring evaluation to ${new Date(batchAnchorMs).toISOString()}`);
      } else {
        batchAnchorMs = Date.now();
      }

      const anchorIso = new Date(batchAnchorMs).toISOString();

      // 8.1 Check 3+ quick-commerce transactions in 24 hours prior to anchor
      const oneDayAgo = new Date(batchAnchorMs - 24 * 60 * 60 * 1000).toISOString();
      const { data: qcTxns } = await supabase
        .from("bank_transactions")
        .select("id")
        .eq("user_id", user.id)
        .eq("type", "DEBIT")
        .gte("transaction_timestamp", oneDayAgo)
        .lte("transaction_timestamp", anchorIso)
        .or("clean_merchant_name.ilike.%zepto%,clean_merchant_name.ilike.%blinkit%,clean_merchant_name.ilike.%instamart%,narration.ilike.%zepto%,narration.ilike.%blinkit%,narration.ilike.%instamart%");

      if (qcTxns && qcTxns.length >= 3) {
        await supabase
          .from("ai_nudges")
          .update({ is_dismissed: true })
          .eq("user_id", user.id)
          .eq("headline", "Quick-Commerce Sprint ⚡");

        await supabase.from("ai_nudges").insert({
          user_id: user.id,
          headline: "Quick-Commerce Sprint ⚡",
          body: "You've placed 3+ quick deliveries in 24 hours. Impulse drain is kicking in.",
          badge_text: "IMPULSE ALERT",
          card_style: "heroPastel3",
          action_label: "Review Impulse",
          metric_tag: `${qcTxns.length} orders`,
          is_dismissed: false,
        });
      }

      // 8.2 Check if 7-day spend velocity exceeds inflow prior to anchor
      const sevenDaysAgo = new Date(batchAnchorMs - 7 * 24 * 60 * 60 * 1000).toISOString();
      const { data: recent7d } = await supabase
        .from("bank_transactions")
        .select("type, amount")
        .eq("user_id", user.id)
        .gte("transaction_timestamp", sevenDaysAgo)
        .lte("transaction_timestamp", anchorIso);

      if (recent7d && recent7d.length > 0) {
        let spent7d = 0;
        let inflow7d = 0;
        for (const t of recent7d) {
          if (t.type === "DEBIT") spent7d += Number(t.amount || 0);
          else if (t.type === "CREDIT") inflow7d += Number(t.amount || 0);
        }

        if (spent7d > inflow7d && spent7d > 0) {
          const deltaPercent = inflow7d > 0
            ? Math.round(((spent7d - inflow7d) / inflow7d) * 100)
            : 100;

          await supabase
            .from("ai_nudges")
            .update({ is_dismissed: true })
            .eq("user_id", user.id)
            .eq("headline", "Burn Rate Warning ⚠️");

          await supabase.from("ai_nudges").insert({
            user_id: user.id,
            headline: "Burn Rate Warning ⚠️",
            body: `Outflows are outpacing weekly inflows by ${deltaPercent}%. Time to pump the brakes.`,
            badge_text: "VELOCITY",
            card_style: "heroPastel2",
            action_label: "Inspect Burn",
            metric_tag: `+${deltaPercent}% over`,
            is_dismissed: false,
          });
        }
      }
    } catch (nudgeErr) {
      console.error(`[sync-transactions] Error evaluating nudges:`, nudgeErr);
    }

    return new Response(
      JSON.stringify({
        success: true,
        count: totalTxnsUpserted,
        accountId: primaryAccountId,
        latestBalance,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[sync-transactions] Unhandled error: ${message}`);
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
