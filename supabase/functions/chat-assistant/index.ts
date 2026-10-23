import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@^2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface ToolCall {
  name: string;
  args?: Record<string, unknown>;
}

// Tool declarations for Google Gemini 1.5 Flash
const geminiTools = [
  {
    functionDeclarations: [
      {
        name: "resolve_financial_event",
        description:
          "Finds the exact date, amount, sender/merchant, and narration of an income or financial event (such as 'allowance', 'salary', 'stipend', 'pocket money', or a transfer from family/someone). ALWAYS call this tool first whenever the user asks a question anchored to an event (e.g. 'since I got my allowance', 'after my salary came in', 'after Jayadev sent money', 'where did my allowance go?') to resolve the exact start date.",
        parameters: {
          type: "OBJECT",
          properties: {
            event_type: {
              type: "STRING",
              description: "Type of financial event, e.g. 'allowance', 'salary', 'stipend', 'transfer', 'credit'",
            },
            hint: {
              type: "STRING",
              description: "Optional sender name, merchant name, or keyword hint if mentioned by the user (e.g. 'Jayadev', 'mom', 'dad')",
            },
          },
          required: ["event_type"],
        },
      },
      {
        name: "search_transactions",
        description:
          "Searches for specific transactions by merchant name, person name, keyword, category, or exact amount. Returns matching transactions with date, amount, type (DEBIT/CREDIT), merchant, and narration.",
        parameters: {
          type: "OBJECT",
          properties: {
            query: {
              type: "STRING",
              description: "Search keyword, person name, shop name, narration fragment, or amount to find",
            },
            flow_type: {
              type: "STRING",
              enum: ["DEBIT", "CREDIT"],
              description: "Optional flow filter: 'DEBIT' for spending/outflows, 'CREDIT' for income/inflows",
            },
            start_date: {
              type: "STRING",
              description: "Optional ISO start date in YYYY-MM-DD format",
            },
            end_date: {
              type: "STRING",
              description: "Optional ISO end date in YYYY-MM-DD format",
            },
            limit: {
              type: "INTEGER",
              description: "Maximum number of transactions to return (default 10, max 20)",
            },
          },
          required: ["query"],
        },
      },
      {
        name: "recall_memory",
        description:
          "Searches persistent memory for saved facts, preferences, habits, goals, or financial anchors about the user. Use this when the user asks what you know about them or refers to a goal/fact mentioned in the past.",
        parameters: {
          type: "OBJECT",
          properties: {
            query: {
              type: "STRING",
              description: "Topic or keyword to recall, e.g. 'allowance', 'rent', 'savings goal', 'salary', 'habit'",
            },
            memory_type: {
              type: "STRING",
              enum: ["fact", "preference", "goal", "event_anchor"],
              description: "Optional category filter",
            },
          },
        },
      },
      {
        name: "save_memory",
        description:
          "Saves a new persistent fact, preference, goal, or event anchor about the user for future conversations. Use this when the user reveals something important about their financial life that you should remember across sessions (e.g., 'I want to save 2000 each month', 'I get pocket money on the 1st', 'Remind me that my rent is 8000').",
        parameters: {
          type: "OBJECT",
          properties: {
            memory_type: {
              type: "STRING",
              enum: ["fact", "preference", "goal", "event_anchor"],
              description: "Category of the memory",
            },
            content: {
              type: "STRING",
              description: "Concise description of the fact, preference, or goal to remember",
            },
            confidence: {
              type: "NUMBER",
              description: "Confidence level 0.0 to 1.0 (default 1.0 for user-stated information)",
            },
          },
          required: ["memory_type", "content"],
        },
      },
      {
        name: "compare_periods",
        description:
          "Compares spending, money out, payments to people, and bank charges between two time periods or two different months (e.g. comparing August vs September, or this week vs last week). Calculates exact percentage changes, difference amounts, and trends deterministically in PostgreSQL.",
        parameters: {
          type: "OBJECT",
          properties: {
            period1_start: {
              type: "STRING",
              description: "Start date of baseline period (YYYY-MM-DD)",
            },
            period1_end: {
              type: "STRING",
              description: "End date of baseline period (YYYY-MM-DD)",
            },
            period2_start: {
              type: "STRING",
              description: "Start date of comparison period (YYYY-MM-DD)",
            },
            period2_end: {
              type: "STRING",
              description: "End date of comparison period (YYYY-MM-DD)",
            },
            category: {
              type: "STRING",
              description: "Optional category to compare across both periods",
            },
          },
          required: ["period1_start", "period1_end", "period2_start", "period2_end"],
        },
      },
      {
        name: "get_category_breakdown",
        description:
          "Returns a complete breakdown of all money out / debits grouped by category (including shop categories, bank charges/fees, and transfers) with amounts, transaction counts, and percentage shares for a date range or the active statement. ALWAYS call this when the user asks for a category breakdown, asks where their money went, or asks for their top spending areas.",
        parameters: {
          type: "OBJECT",
          properties: {
            start_date: {
              type: "STRING",
              description: "Optional ISO start date (YYYY-MM-DD)",
            },
            end_date: {
              type: "STRING",
              description: "Optional ISO end date (YYYY-MM-DD)",
            },
          },
        },
      },
      {
        name: "get_spending_summary",
        description:
          "Spending at shops and services. Payments to people and bank charges are reported separately. Pass no category for a general 'how much did I spend' question. If the user asks about multiple categories, call this tool once per category.",
        parameters: {
          type: "OBJECT",
          properties: {
            category: {
              type: "STRING",
              enum: [
                "Eating out, tea & snacks",
                "Groceries & daily needs",
                "Fuel",
                "Gaming",
                "Subscriptions & tools",
                "Travel & transport",
                "Movies & fun",
                "Medical & pharmacy",
                "Bills & recharge",
                "Shopping",
                "Pan shops & small stalls",
                "Local shops & stalls",
                "Local shops",
              ],
              description:
                "Category of spending. Available categories:\n- Eating out, tea & snacks: restaurants, tea stalls, bakeries, snacks\n- Groceries & daily needs: supermarkets, kirana, daily staples\n- Fuel: petrol, diesel, gas stations\n- Gaming: game stores, in-app gaming purchases\n- Subscriptions & tools: software, online tools, recurring services\n- Travel & transport: rides, trains, flights, transit\n- Movies & fun: cinema, events, outings\n- Medical & pharmacy: medical stores, clinics, health\n- Bills & recharge: mobile recharge, electricity, utility bills\n- Shopping: clothing, electronics, ecommerce goods\n- Pan shops & small stalls: paan, kiosks, small street vendors\n- Local shops & stalls: general local retail and neighborhood stalls\n- Local shops: general local stores\nPass NO category for general spending across all shops. Call this tool once per category if the user means both (e.g. food = Eating out, tea & snacks AND Groceries & daily needs only if both are requested).",
            },
            merchant: {
              type: "STRING",
              description:
                "Optional merchant name or keyword, e.g. 'Swiggy', 'Zomato', 'Amazon', 'Starbucks', 'Uber'",
            },
            start_date: {
              type: "STRING",
              description: "Optional ISO start date in YYYY-MM-DD format",
            },
            end_date: {
              type: "STRING",
              description: "Optional ISO end date in YYYY-MM-DD format",
            },
          },
        },
      },
      {
        name: "list_recent_transactions",
        description:
          "Most recent transactions in the statement, by date. Times are not available from statements.",
        parameters: {
          type: "OBJECT",
          properties: {
            limit: {
              type: "INTEGER",
              description: "Number of transactions to fetch (between 1 and 5, default 5)",
            },
            flow_type: {
              type: "STRING",
              enum: ["DEBIT", "CREDIT"],
              description: "Optional filter: 'DEBIT' for spending/outflows, 'CREDIT' for income/inflows",
            },
          },
        },
      },
      {
        name: "get_cashflow_rhythm",
        description:
          "Daily safe spending limit until the next money-in date, bills coming up, and how long the balance would last, all as of the statement end date.",
        parameters: {
          type: "OBJECT",
          properties: {},
        },
      },
      {
        name: "get_safe_to_spend",
        description:
          "Calculates safe-to-spend amounts (daily and total for the remainder of the month) after reserving funds for upcoming recurring bills. Call this when the user asks how much they can safely spend or about budget leeway.",
        parameters: {
          type: "OBJECT",
          properties: {},
        },
      },
      {
        name: "detect_recurring_costs",
        description:
          "Identifies active recurring subscriptions, bills, and fixed commitments with merchant names, monthly amounts, and categories. Call this when the user asks about subscriptions, fixed costs, bills, or recurring charges.",
        parameters: {
          type: "OBJECT",
          properties: {},
        },
      },
      {
        name: "get_cashflow_velocity",
        description:
          "Calculates daily spending pace over the last N days (default 7) compared to the previous period, pace delta percentage, and estimated runway in days. Call this when the user asks about spending pace, money out, or how long balance will last.",
        parameters: {
          type: "OBJECT",
          properties: {
            days: {
              type: "INTEGER",
              description: "Number of days for calculation window (default 7)",
            },
          },
        },
      },
      {
        name: "get_current_balance",
        description:
          "Retrieves the user's verified bank balance as of their statement end date, including as_of_date, days_since_statement_end, stale flag, and verification status. Call this whenever the user asks about their current balance, total balance, account balance, or how much money they have.",
        parameters: {
          type: "OBJECT",
          properties: {},
        },
      },
    ],
  },
];

// Strict allow-list filter preventing forbidden or misleading metrics from reaching Gemini
const FORBIDDEN_TOOL_KEYS = new Set([
  "financial_health_score",
  "savings_ratio",
  "discretionary_ratio",
  "impulse_spent",
  "health_status",
  "is_live",
  "is_live_data",
  "total_spent",
]);

function filterToolResult(fnName: string, raw: unknown): unknown {
  if (!raw || typeof raw !== "object") return raw;
  if ((raw as Record<string, unknown>).error) return raw;

  if (fnName === "get_current_balance") {
    const b = raw as Record<string, unknown>;
    return {
      available: b.available,
      current_balance: b.current_balance,
      as_of_date: b.as_of_date,
      days_since_statement_end: b.days_since_statement_end,
      stale: b.stale,
      verified: b.verified,
      ...(b.reason ? { reason: b.reason } : {}),
    };
  }

  if (fnName === "get_spending_summary") {
    const s = raw as Record<string, unknown>;
    const topTxns = Array.isArray(s.top_transactions)
      ? s.top_transactions.map((t: Record<string, unknown>) => ({
        merchant: t.merchant,
        amount: t.amount,
        date: t.date,
        category: t.category,
        txn_kind: t.txn_kind,
      }))
      : [];
    return {
      period_start: s.period_start,
      period_end: s.period_end,
      transaction_count: s.transaction_count,
      breakdown: s.breakdown,
      top_transactions: topTxns,
    };
  }

  if (fnName === "get_cashflow_rhythm") {
    const r = raw as Record<string, unknown>;
    return {
      available: r.available,
      data_as_of: r.data_as_of,
      days_since_statement_end: r.days_since_statement_end,
      stale: r.stale,
      balance: r.balance,
      horizon: r.horizon,
      upcoming_bills: r.upcoming_bills,
      upcoming_bills_total: r.upcoming_bills_total,
      safe_pool: r.safe_pool,
      safe_per_day: r.safe_per_day,
      shortfall: r.shortfall,
      runway_days: r.runway_days,
      daily_outflow_30d: r.daily_outflow_30d,
      daily_spend_30d: r.daily_spend_30d,
      spent_on_last_day: r.spent_on_last_day,
      spent_this_week_to_date: r.spent_this_week_to_date,
    };
  }

  if (fnName === "get_cashflow_velocity") {
    const v = raw as Record<string, unknown>;
    return {
      data_as_of: v.data_as_of,
      days: v.days,
      window_start: v.window_start,
      window_end: v.window_end,
      previous_window_complete: v.previous_window_complete,
      current_daily_spend: v.current_daily_spend,
      previous_daily_spend: v.previous_daily_spend,
      delta_percent_spend: v.delta_percent_spend,
      current_daily_outflow: v.current_daily_outflow,
      previous_daily_outflow: v.previous_daily_outflow,
      delta_percent_outflow: v.delta_percent_outflow,
      balance_as_of: v.balance_as_of,
      current_balance: v.current_balance,
      runway_days: v.runway_days,
    };
  }

  if (fnName === "detect_recurring_costs") {
    const d = raw as Record<string, unknown>;
    return {
      total_monthly_recurring: d.total_monthly_recurring,
      recurring: d.recurring ?? [],
      possible: d.possible ?? [],
    };
  }

  if (fnName === "get_safe_to_spend") {
    const s = raw as Record<string, unknown>;
    return {
      available: s.available,
      safe_to_spend_daily: s.safe_to_spend_daily,
      safe_to_spend_total: s.safe_to_spend_total,
      days_remaining: s.days_remaining,
      pending_recurring_total: s.pending_recurring_total,
      shortfall: s.shortfall,
      current_balance: s.current_balance,
      balance_as_of: s.balance_as_of,
      horizon_end: s.horizon_end,
      horizon_basis: s.horizon_basis,
      stale: s.stale,
    };
  }

  const stripForbidden = (obj: unknown): unknown => {
    if (Array.isArray(obj)) return obj.map(stripForbidden);
    if (obj !== null && typeof obj === "object") {
      const clean: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
        if (!FORBIDDEN_TOOL_KEYS.has(k)) {
          clean[k] = stripForbidden(v);
        }
      }
      return clean;
    }
    return obj;
  };

  return stripForbidden(raw);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    let geminiApiKey = Deno.env.get("GEMINI_API_KEY") || Deno.env.get("GOOGLE_API_KEY");

    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // If not in Deno.env, fetch from Supabase Vault (vault.decrypted_secrets)
    if (!geminiApiKey) {
      try {
        const { data: vaultKey } = await supabase.rpc("get_vault_secret", {
          p_name: "GEMINI_API_KEY",
        });
        if (vaultKey) {
          geminiApiKey = String(vaultKey).trim();
          console.log("[chat-assistant] Successfully loaded GEMINI_API_KEY from Supabase Vault.");
        }
      } catch (err) {
        console.error("[chat-assistant] Note: Vault retrieval failed:", err);
      }
    }

    // 1. Verify Authentication JWT
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) {
      return new Response(
        JSON.stringify({ error: "Unauthorized", message: "Missing Bearer token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser(token);

    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized", message: userError?.message ?? "Invalid user token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 2. Parse Request Payload
    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch (_) {
      return new Response(
        JSON.stringify({ error: "Bad Request", message: "Invalid JSON body" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const userPrompt = String(body.prompt ?? body.message ?? "").trim();
    if (!userPrompt) {
      return new Response(
        JSON.stringify({ error: "Bad Request", message: "Prompt cannot be empty" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 3. User Profile & Credit Check
    const { data: profile } = await supabase
      .from("profiles")
      .select("ai_credits")
      .eq("id", user.id)
      .maybeSingle();

    const currentCredits = profile?.ai_credits ?? 3;
    if (currentCredits <= 0) {
      return new Response(
        JSON.stringify({
          error: "OUT_OF_CREDITS",
          message: "You have 0 AI credits remaining. Credit top-ups coming soon!",
          ai_credits: 0,
        }),
        { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 4. Fallback if GEMINI_API_KEY is not configured
    if (!geminiApiKey) {
      console.error("[chat-assistant] Missing GEMINI_API_KEY in environment");
      return new Response(
        JSON.stringify({
          error: "CONFIGURATION_ERROR",
          message: "Gemini API key is not configured. Please set GEMINI_API_KEY in Supabase Edge Function secrets.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 5. Session Tracking & Multi-Turn Threading
    let activeSessionId = body.session_id ? String(body.session_id) : null;
    if (!activeSessionId) {
      const { data: latestMsg } = await supabase
        .from("chat_messages")
        .select("session_id, created_at")
        .eq("user_id", user.id)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      const lastCreatedAt = latestMsg?.created_at ? new Date(latestMsg.created_at).getTime() : 0;
      const thirtyMinutesAgo = Date.now() - 30 * 60 * 1000;

      if (latestMsg?.session_id && lastCreatedAt > thirtyMinutesAgo) {
        activeSessionId = latestMsg.session_id;
      } else {
        activeSessionId = crypto.randomUUID();
      }
    }

    // Fetch Recent Conversation History for active session (last 20 messages)
    let historyQuery = supabase
      .from("chat_messages")
      .select("role, content")
      .eq("user_id", user.id);

    if (activeSessionId) {
      historyQuery = historyQuery.eq("session_id", activeSessionId);
    }

    const { data: historyRows } = await historyQuery
      .order("created_at", { ascending: false })
      .limit(20);

    const history = (historyRows ?? []).reverse();

    // Persist the user's incoming message immediately with session_id
    await supabase.from("chat_messages").insert({
      user_id: user.id,
      session_id: activeSessionId,
      role: "user",
      content: userPrompt,
      metadata: {
        source: "flutter_client",
        timestamp: new Date().toISOString(),
      },
    });

    // 6. Instant Memory Snapshot Injection & Temporal Grounding
    let snapshotText = "No statement records available.";
    let statementStart = "";
    let statementEnd = "";
    let statementDays = 0;
    let daysSinceEnd = 0;
    let isStale = false;

    let userProfileText = "";
    let userMemoryText = "";

    try {
      const [boundsRes, balRes, profileRes, habitRes, memoryRes] = await Promise.all([
        supabase.rpc("statement_bounds", { p_user_id: user.id }),
        supabase.rpc("get_balance_facts", { p_user_id: user.id }),
        supabase.from("profiles").select("full_name, income_type, expected_monthly_income, age, gender").eq("id", user.id).maybeSingle(),
        supabase.from("user_habit_profile").select("archetype").eq("user_id", user.id).maybeSingle(),
        supabase.from("user_memory").select("memory_type, content, confidence").eq("user_id", user.id).eq("is_active", true).order("updated_at", { ascending: false }).limit(10),
      ]);

      const bounds = Array.isArray(boundsRes.data) ? boundsRes.data[0] : boundsRes.data;
      if (bounds?.start_date && bounds?.end_date) {
        statementStart = String(bounds.start_date);
        statementEnd = String(bounds.end_date);
        statementDays = Number(bounds.days ?? 0);
      }

      const bal = balRes.data as Record<string, unknown> | null;
      if (bal && statementEnd) {
        daysSinceEnd = Number(bal.days_since_statement_end ?? 0);
        isStale = Boolean(bal.stale);
        if (bal.available && bal.amount !== null) {
          const balAmount = Number(bal.amount).toFixed(2);
          snapshotText = `Statement Period: ${statementStart} to ${statementEnd} (${statementDays} days). Balance: ₹${balAmount} as of ${bal.as_of_date} (${daysSinceEnd} days ago, stale: ${isStale}).`;
        } else {
          snapshotText = `Statement Period: ${statementStart} to ${statementEnd} (${statementDays} days). Balance: Unavailable or unverified.`;
        }
      }

      const prof = profileRes.data;
      const habit = habitRes.data;
      if (prof) {
        userProfileText += `User Name: ${prof.full_name || "User"}\n`;
        if (prof.age) userProfileText += `Age: ${prof.age}\n`;
        if (prof.income_type) userProfileText += `Income Source: ${prof.income_type}\n`;
        if (prof.expected_monthly_income) userProfileText += `Expected Monthly Income: ₹${Number(prof.expected_monthly_income).toLocaleString("en-IN")}\n`;
      }
      if (habit?.archetype) {
        const arch = habit.archetype as Record<string, unknown>;
        const primary = (arch.primary as Record<string, unknown>)?.name;
        const primaryPlain = (arch.primary as Record<string, unknown>)?.plain;
        const secondary = (arch.secondary as Record<string, unknown>)?.name;
        if (primary) {
          userProfileText += `Spending Personality Archetype: ${primary}${primaryPlain ? ` (${primaryPlain})` : ""}\n`;
          if (secondary) userProfileText += `Secondary Tendency: ${secondary}\n`;
        }
      }

      const memories = memoryRes?.data;
      if (Array.isArray(memories) && memories.length > 0) {
        userMemoryText = "WHAT I REMEMBER ABOUT YOU (PERSISTENT MEMORY):\n" +
          memories.map((m: Record<string, unknown>) => `- [${String(m.memory_type).toUpperCase()}] ${m.content}`).join("\n") + "\n";
      }
    } catch (err) {
      console.warn("[chat-assistant] Failed to fetch financial snapshot/profile/memory:", err);
    }

    // 7. Assemble Gemini Prompt & Instructions
    const nowIso = new Date().toISOString();
    const istTime = new Date().toLocaleString("en-IN", { timeZone: "Asia/Kolkata" });
    const currentYear = new Date().getFullYear();

    const systemInstruction = {
      role: "system",
      parts: [
        {
          text: `You are Setthi AI, a witty, empathetic, candid Gen Z personal finance companion (inspired by Cleo).
You talk like a savvy, candid financial advisor and companion who helps the user understand their money with light humor and sharp, insightful real talk.
Always format currency in Indian Rupee format (₹X,XXX).
Current Clock Time in India (IST): ${istTime} (ISO: ${nowIso}).

STATEMENT DATA CONTEXT:
1. Setthi analyzes bank-statement PDF uploads. Every user's data is a SNAPSHOT ending on their statement end date (${statementEnd || "latest statement date"}). There is NO live bank connection.
2. Active Statement Window: ${statementStart ? `${statementStart} to ${statementEnd} (${statementDays} days)` : "statement period"}.
3. ALWAYS state the exact period (dates) in every spending answer (e.g. "Between 6 Jul and 6 Oct 2026...").

ACCOUNT BALANCE & DATE CITATION RULES (CRITICAL):
1. You HAVE access to the user's recorded account balance and the date of that record (via get_current_balance or your snapshot).
2. ALWAYS quote the balance with its "as of" date:
   - Example: "₹37.21 as of 6 Oct 2026 (5 days ago)" or "Rs 37.21 as of 6 Oct 2026 (5 days ago)".
   - NEVER say "your balance is" or "you have" without the "as of" date!
   - If stale is true, explicitly state that the balance is from ${daysSinceEnd} days ago and may have changed since, and do NOT give definitive yes/no spending advice.
   - If available is false or balance is missing, state clearly that the balance is not available from this statement; NEVER invent, estimate, or assume 0.00.

"CAN I AFFORD X?" & SAFE LIMIT RULES:
1. "Daily safe limit" is a limit per day until a specific date (e.g. until the next money-in or end of month); NEVER say "today" or "this week" for it!
2. When asked if the user can afford a purchase X:
   - Compare X only with balance, shortfall, and bills due returned by get_safe_to_spend or get_current_balance.
   - You MUST state that all figures are as of the statement end date (${statementEnd}).
   - Do NOT tell the user to spend. Only compare the amounts objectively.

TERMINOLOGY & MONEY CLASSIFICATIONS:
1. When asked "Where did my money go?", "What took my money?", "What was my biggest spend / expense?", or general outflow questions:
   - Report the COMPLETE picture of money out, which includes:
     a) Shop and merchant spending (SPEND)
     b) Bank charges, penalties, and minimum balance fees (BANK_FEE)
     c) Transfers sent to people (PERSON_OUT)
   - ALWAYS proactively highlight unexpected or large bank charges (like AMB non-maintenance / minimum balance charges), because they directly drain the user's balance and allowance!
2. "Shop spending" refers specifically to merchant purchases at stores and online services (SPEND).
3. For peer-to-peer transfers (PERSON_OUT), say "sent to people" or "transfers to people".
4. For bank charges and fees (BANK_FEE), explicitly identify them as "bank charges", "minimum balance penalties", or "account fees".
5. For unclassified debits (UNSURE), say "unclear".
6. Money received from people (PERSON_IN) is NOT salary or income unless the user confirms it. Say "received from people".
7. When asked "What was my biggest spend / purchase / expense?":
   - Inspect top_transactions in get_spending_summary or search_transactions.
   - If the largest debit was a bank charge (e.g. ₹590 minimum balance fee), clearly state it as the largest overall debit/fee, and also mention the biggest store purchase (e.g. Playo ₹301.08) so the user gets complete clarity.
8. When discussing recurring costs, mention possible items only as a question ("Is X a regular bill?"), never as a fact, and NEVER add them to totals.
9. delta_percent_* from get_cashflow_velocity can ONLY be used with the specific window dates, and outflow figures include money sent to people.

STRICT NUMERICAL FIDELITY (NO ARITHMETIC):
1. Do NOT do mental arithmetic or calculate numbers yourself (comparisons like X > Y are allowed).
2. Quote numbers EXACTLY as returned by the tools. If a number is not in the tool result, say you do not have it.
3. If is_partial is true, explicitly state that it is a partial month.
4. If delta_percent is null, make NO trend claim (do not guess whether spending went up or down).

CRITICAL FORMATTING & EMOJI RULE (ZERO TOLERANCE):
NEVER use any emoji, emoticon, smiley, or unicode emotion symbol under any circumstance in your response.
Your responses must be 100% free of emojis (no emojis at all).
Do NOT include pizza, rockets, sparkles, shopping bags, medals, nail polish, or any pictograms.

USER FINANCIAL SNAPSHOT:
${snapshotText}
${userProfileText ? `\nUSER PROFILE & FINANCIAL PERSONALITY:\n${userProfileText}` : ""}${userMemoryText ? `\n${userMemoryText}` : ""}
CRITICAL LANGUAGE RULE (ZERO TOLERANCE):
NEVER use the word "data" under any circumstance in your thoughts, reasoning, or response.
Do NOT say "I have the data", "we store your data", "based on your data", "according to the data", "in your data", or any phrase containing the word "data".
Instead, refer naturally to "records", "transactions", "statement", "account history", "activity", or "finances".

SIMPLE EVERYDAY LANGUAGE POLICY (FOR NON-TECHNICAL & NON-FINANCIAL USERS):
1. You are a personal finance assistant for EVERYDAY PEOPLE. Your users are not financial experts, accountants, or engineers.
2. Speak in simple, everyday words that anyone can immediately understand. Keep your explanations conversational, natural, and friendly.
3. NEVER use heavy financial jargon or technical terms.
   - Do NOT say "ledger", "deterministic", "liquidity runway", "cashflow rhythm", "burn velocity", "discretionary ratio", "inflow / outflow elasticity", "temporal anchoring", or "telemetry".
   - Instead, always use simple everyday phrases:
     * Say "transactions" or "bank statement" instead of "ledger".
     * Say "money in" or "income" instead of "inflow".
     * Say "money out" or "spending" instead of "outflow / debits".
     * Say "wants vs needs" or "extra spending" instead of "discretionary spending".
     * Say "daily spending pace" or "how much you spend each day" instead of "daily velocity" or "burn rate".
     * Say "how long your money will last" instead of "runway".
     * Say "bills and subscriptions" instead of "recurring commitments".
     * Say "daily safe spending limit" instead of "calibrated safe-to-spend baseline".
4. When explaining numbers or percentages, explain them in plain English.
5. Keep your tone supportive, clear, and easy to follow. Never make the user feel overwhelmed by complex terms.

DYNAMIC TOOL USAGE PROTOCOL:
1. EVENT-ANCHORED OR TIME-RELATIVE QUERIES (CRITICAL):
   If the user asks about money/spending since an event (e.g. "since my allowance", "after salary came in", "where did my allowance go?", "after Jayadev sent money", "since Diwali"):
   - Step 1: ALWAYS call resolve_financial_event first with event_type (e.g. 'allowance', 'salary') and optional name hint (e.g. 'Jayadev').
   - Step 2: Use the returned suggested_start_date and suggested_end_date.
   - Step 3: Call get_spending_summary AND get_category_breakdown with those exact start_date and end_date to see where all the money went (including shop spend, bank fees like minimum balance charges, and transfers)!
   - Step 4: Proactively flag any bank charges, minimum balance fees, or large outflows alongside category totals!
   - NEVER default to the start of the entire statement if the user specifically asked about spending since an event or allowance!
2. SEARCH TRANSACTIONS: If the user asks about a specific person, store, keyword, or transaction amount (e.g. "did I pay Zomato?", "find payments to Jayadev", "show ₹500 transactions"), call search_transactions.
3. PERSISTENT MEMORY & GOALS:
   - You have persistent memory about this user (listed under 'WHAT I REMEMBER ABOUT YOU'). Use it naturally to personalize answers without repeating it verbatim.
   - If the user explicitly shares a new personal financial goal, rule, or preference (e.g. "I want to save 2000 every month", "my rent is 8000", "I want to stop ordering from Zomato"), call save_memory to store it!
   - If the user asks what you remember about them or asks about a past goal/anchor, call recall_memory.
4. COMPARISONS BETWEEN MONTHS / PERIODS:
   - If the user asks to compare two months or time windows (e.g. "how did my spending compare between August and September?", "was this month higher than last?"), ALWAYS call compare_periods.
   - Quote the exact numbers and percentage changes from the tool output. Never do mental math or guess comparisons!
5. BALANCE INQUIRIES: If the user asks about their balance, call get_current_balance. Quote the amount with "as of [Date] ([N] days ago)".
6. SPENDING / CATEGORY / MERCHANT QUERIES:
   - For a general breakdown across all categories or "where did my money go", ALWAYS call get_category_breakdown first! (It now includes shop categories, bank charges, and transfers). Also check get_spending_summary for top debits.
   - For spending on a specific merchant or single category, call get_spending_summary.
7. RECENT ACTIVITY: Call list_recent_transactions.
8. RECURRING BILLS: Call detect_recurring_costs.
9. SAFE TO SPEND / BUDGET LEEWAY: Call get_safe_to_spend or get_cashflow_rhythm.
10. SPENDING PACE / RUNWAY: Call get_cashflow_velocity.
11. CASUAL CHAT: Answer conversationally without tools.
12. Keep answers punchy, helpful, formatted with clean bullets if listing items, and never more than 2-3 short paragraphs.

SELF-VALIDATION PROTOCOL (FOR REASONING FIDELITY):
Before formulating your response:
1. Verify whether the user referenced a relative event anchor (e.g. allowance, salary); if so, ensure resolve_financial_event was called first.
2. Confirm that reported figures for shop spending (SPEND), payments sent to people (PERSON_OUT), and bank charges (BANK_FEE) remain strictly separated.
3. Check that date ranges quoted in your text strictly correspond to tool results.
4. Adhere to zero emojis, Indian Rupee format (₹X,XXX), and zero occurrences of the word 'data'.`,
        },
      ],
    };

    // Format chat history for Gemini contents
    const contents: Array<Record<string, unknown>> = [];
    for (const msg of history) {
      contents.push({
        role: msg.role === "assistant" ? "model" : "user",
        parts: [{ text: msg.content }],
      });
    }

    // Add current user prompt
    contents.push({
      role: "user",
      parts: [{ text: userPrompt }],
    });

    // 7. Function Calling Evaluation Loop (up to 3 tool turns)
    const geminiEndpoint = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=${geminiApiKey}`;

    interface ExecutedToolRecord {
      tool: string;
      args: Record<string, unknown>;
      result: unknown;
      timestamp: string;
    }

    const executedTools: ExecutedToolRecord[] = [];
    const startTimeMs = Date.now();

    // Intent Pre-Routing: Fast-path bypass for casual greetings/salutations
    const isPureCasualChat = /^(hi|hello|hey|hey there|yo|thanks|thank you|ty|who are you|what can you do|good morning|good afternoon|good evening|good night|sup)\s*[\!\?\.]*$/i.test(userPrompt.trim());

    let needsAnotherTurn = !isPureCasualChat;
    let turnCount = 0;
    const maxToolTurns = 5;

    while (needsAnotherTurn && turnCount < maxToolTurns) {
      turnCount++;

      const res = await fetch(geminiEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents,
          systemInstruction,
          tools: geminiTools,
          toolConfig: {
            functionCallingConfig: {
              mode: "AUTO",
            },
          },
          generationConfig: {
            temperature: 0.7,
            maxOutputTokens: 2048,
            thinkingConfig: {
              thinkingBudget: 1024,
            },
          },
        }),
      });

      if (!res.ok) {
        const errBody = await res.text();
        console.error(`[chat-assistant] Gemini API error: ${errBody}`);
        throw new Error(`Gemini generation failed (${res.status}): ${errBody}`);
      }

      const resJson = await res.json();
      const candidate = resJson.candidates?.[0];
      const parts = candidate?.content?.parts ?? [];

      // Check if candidate made any function call
      const functionCalls: ToolCall[] = [];
      for (const p of parts) {
        if (p.functionCall) {
          functionCalls.push(p.functionCall);
        }
      }

      if (functionCalls.length === 0) {
        // No function calls made; model generated text or final answer
        needsAnotherTurn = false;
        break;
      }

      // Add the model's functionCall turn to conversation
      contents.push(candidate.content);

      // Execute each tool call against PostgreSQL via Supabase PostgREST
      const functionResponseParts: Array<Record<string, unknown>> = [];

      for (const call of functionCalls) {
        const fnName = call.name;
        const fnArgs = (call.args ?? {}) as Record<string, unknown>;
        console.log(`[chat-assistant] Invoking tool ${fnName} with args:`, fnArgs);

        let toolResult: unknown = {};

        try {
          if (fnName === "get_current_balance") {
            const { data, error } = await supabase.rpc("get_current_balance", {
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "get_spending_summary") {
            const { data, error } = await supabase.rpc("get_spending_summary", {
              p_category: fnArgs.category ? String(fnArgs.category) : null,
              p_merchant: fnArgs.merchant ? String(fnArgs.merchant) : null,
              p_start_date: fnArgs.start_date ? String(fnArgs.start_date) : null,
              p_end_date: fnArgs.end_date ? String(fnArgs.end_date) : null,
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "list_recent_transactions") {
            const limit = fnArgs.limit ? Number(fnArgs.limit) : 5;
            let query = supabase
              .from("bank_transactions")
              .select("counterparty_key, clean_merchant_name, amount, type, habit_category, txn_kind, transaction_timestamp, seq")
              .eq("user_id", user.id)
              .order("transaction_timestamp", { ascending: false })
              .order("seq", { ascending: false })
              .limit(limit);

            if (fnArgs.flow_type) {
              query = query.eq("type", String(fnArgs.flow_type).toUpperCase());
            }

            const { data, error } = await query;
            if (error || !data) {
              const { data: rpcData, error: rpcErr } = await supabase.rpc("list_recent_transactions", {
                p_limit: limit,
                p_flow_type: fnArgs.flow_type ? String(fnArgs.flow_type) : null,
                p_user_id: user.id,
              });
              toolResult = rpcErr ? { error: rpcErr.message } : rpcData;
            } else {
              toolResult = data.map((t) => {
                const dateOnly = t.transaction_timestamp
                  ? new Date(t.transaction_timestamp).toLocaleDateString("en-IN", {
                    timeZone: "Asia/Kolkata",
                    day: "numeric",
                    month: "short",
                    year: "numeric",
                  })
                  : null;
                const merchantName = t.counterparty_key
                  ? String(t.counterparty_key).toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase())
                  : (t.clean_merchant_name || "Unknown");
                return {
                  merchant: merchantName,
                  amount: t.amount,
                  type: t.type,
                  habit_category: t.habit_category ?? "Not categorised",
                  txn_kind: t.txn_kind,
                  date: dateOnly,
                };
              });
            }
          } else if (fnName === "get_cashflow_rhythm") {
            const { data, error } = await supabase.rpc("get_cashflow_rhythm", {
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "get_safe_to_spend") {
            const { data, error } = await supabase.rpc("get_safe_to_spend", {
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "detect_recurring_costs") {
            const { data, error } = await supabase.rpc("detect_recurring_costs", {
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "get_cashflow_velocity") {
            const { data, error } = await supabase.rpc("get_cashflow_velocity", {
              p_user_id: user.id,
              p_days: fnArgs.days ? Number(fnArgs.days) : 7,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "resolve_financial_event") {
            const { data, error } = await supabase.rpc("resolve_financial_event", {
              p_event_type: String(fnArgs.event_type ?? "income"),
              p_hint: fnArgs.hint ? String(fnArgs.hint) : null,
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "search_transactions") {
            const { data, error } = await supabase.rpc("search_transactions", {
              p_query: String(fnArgs.query ?? ""),
              p_type: fnArgs.flow_type ? String(fnArgs.flow_type).toUpperCase() : null,
              p_start_date: fnArgs.start_date ? String(fnArgs.start_date) : null,
              p_end_date: fnArgs.end_date ? String(fnArgs.end_date) : null,
              p_limit: fnArgs.limit ? Number(fnArgs.limit) : 10,
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "recall_memory") {
            const { data, error } = await supabase.rpc("recall_user_memories", {
              p_query: fnArgs.query ? String(fnArgs.query) : null,
              p_memory_type: fnArgs.memory_type ? String(fnArgs.memory_type) : null,
              p_limit: 10,
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "save_memory") {
            const { data, error } = await supabase.rpc("save_user_memory", {
              p_memory_type: String(fnArgs.memory_type ?? "fact"),
              p_content: String(fnArgs.content ?? ""),
              p_confidence: fnArgs.confidence ? Number(fnArgs.confidence) : 1.0,
              p_source: "user_stated",
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "compare_periods") {
            const { data, error } = await supabase.rpc("compare_periods", {
              p_period1_start: String(fnArgs.period1_start),
              p_period1_end: String(fnArgs.period1_end),
              p_period2_start: String(fnArgs.period2_start),
              p_period2_end: String(fnArgs.period2_end),
              p_category: fnArgs.category ? String(fnArgs.category) : null,
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "get_category_breakdown") {
            const { data, error } = await supabase.rpc("get_category_breakdown", {
              p_start_date: fnArgs.start_date ? String(fnArgs.start_date) : null,
              p_end_date: fnArgs.end_date ? String(fnArgs.end_date) : null,
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else {
            toolResult = { error: `Unknown tool name: ${fnName}` };
          }
        } catch (rpcErr) {
          console.error(`[chat-assistant] RPC execution failed for ${fnName}:`, rpcErr);
          toolResult = { error: String(rpcErr) };
        }

        // Apply strict allow-list serialization filter
        toolResult = filterToolResult(fnName, toolResult);

        console.log(`[chat-assistant] Tool ${fnName} result:`, toolResult);

        executedTools.push({
          tool: fnName,
          args: fnArgs,
          result: toolResult,
          timestamp: new Date().toISOString(),
        });

        functionResponseParts.push({
          functionResponse: {
            name: fnName,
            response: {
              result: toolResult,
            },
          },
        });
      }

      // Add tool responses back to conversation contents
      contents.push({
        role: "user",
        parts: functionResponseParts,
      });
    }

    // 8. Stream Final Response with Server-Sent Events (SSE)
    const streamEndpoint = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent?alt=sse&key=${geminiApiKey}`;

    // Pass tools with mode: "NONE" so Gemini is forced to generate a textual synthesis
    // and does not fail due to missing tool declarations in a multi-turn conversation.
    const streamPayload: Record<string, unknown> = {
      contents,
      systemInstruction,
      tools: geminiTools,
      toolConfig: {
        functionCallingConfig: {
          mode: "NONE",
        },
      },
      generationConfig: {
        temperature: 0.7,
        maxOutputTokens: 2048,
        thinkingConfig: {
          thinkingBudget: 1024,
        },
      },
    };

    let geminiStreamRes = await fetch(streamEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(streamPayload),
    });

    // Fallback if mode: "NONE" is rejected by the streaming endpoint
    if (!geminiStreamRes.ok) {
      console.warn(`[chat-assistant] Stream with toolConfig failed (${geminiStreamRes.status}), retrying without toolConfig...`);
      delete streamPayload.toolConfig;
      delete streamPayload.tools;
      geminiStreamRes = await fetch(streamEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(streamPayload),
      });
    }

    if (!geminiStreamRes.ok) {
      const errText = await geminiStreamRes.text();
      console.error(`[chat-assistant] Gemini stream error: ${errText}`);
      throw new Error(`Failed to initiate Gemini text stream: ${errText}`);
    }

    // Transform stream into SSE lines for the Flutter client
    let accumulatedText = "";
    const reader = geminiStreamRes.body?.getReader();
    const decoder = new TextDecoder();
    const encoder = new TextEncoder();

    const customStream = new ReadableStream({
      async start(controller) {
        if (!reader) {
          controller.close();
          return;
        }

        let buffer = "";

        try {
          const emojiRegex =
            /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE00}-\u{FE0F}\u{1F900}-\u{1F9FF}\u{1F600}-\u{1F64F}\u{1F680}-\u{1F6FF}\u{200D}\u{2300}-\u{23FF}\u{2B50}]/gu;

          const sanitizeText = (txt: string): string => {
            const noData = txt.replace(/\bdata\b/gi, (match) => {
              if (match === "DATA") return "RECORDS";
              if (match === "Data") return "Records";
              return "records";
            });
            return noData.replace(emojiRegex, "");
          };

          const processJsonChunk = (jsonStr: string) => {
            if (jsonStr === "[DONE]") return;
            try {
              const parsed = JSON.parse(jsonStr);
              const candidate = parsed.candidates?.[0];
              if (candidate?.finishReason && candidate.finishReason !== "STOP") {
                console.log(`[chat-assistant] Stream candidate finishReason: ${candidate.finishReason}`);
              }
              const parts = candidate?.content?.parts ?? [];
              for (const part of parts) {
                if (part.thought) {
                  // Skip internal chain-of-thought from streaming to user UI
                  continue;
                }
                if (part.text) {
                  const cleanChunk = sanitizeText(part.text);
                  if (cleanChunk.length > 0) {
                    accumulatedText += cleanChunk;
                    controller.enqueue(
                      encoder.encode(
                        `data: ${JSON.stringify({ text: cleanChunk, done: false })}\n\n`
                      )
                    );
                  }
                }
              }
            } catch (_) {
              // Non-JSON line or keep-alive
            }
          };

          while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            buffer += decoder.decode(value, { stream: true });
            const lines = buffer.split("\n");
            buffer = lines.pop() ?? "";

            for (const line of lines) {
              const trimmed = line.trim();
              if (trimmed.startsWith("data: ")) {
                processJsonChunk(trimmed.substring(6).trim());
              }
            }
          }

          // Flush any trailing line in buffer
          if (buffer.trim().startsWith("data: ")) {
            processJsonChunk(buffer.trim().substring(6).trim());
          }

          // Fallback: Ensure the user NEVER receives an empty bubble or empty result
          if (accumulatedText.trim().length === 0) {
            const periodStr = statementEnd ? `${statementStart} to ${statementEnd}` : "statement period";
            const fallbackText = `I reviewed your statement (${periodStr}), but couldn't find any records matching that request. Most of your recorded transactions are peer-to-peer transfers or general expenses.`;
            accumulatedText = fallbackText;
            controller.enqueue(
              encoder.encode(
                `data: ${JSON.stringify({ text: fallbackText, done: false })}\n\n`
              )
            );
          }

          // Stream completed: Deduct 1 credit atomically ONLY if response was provided
          let remainingCredits = currentCredits;
          if (accumulatedText.trim().length > 0) {
            try {
              const { data: deducted } = await supabase.rpc("deduct_ai_credit", {
                p_user_id: user.id,
              });

              if (deducted) {
                remainingCredits = Math.max(0, currentCredits - 1);
                const { data: updatedProfile } = await supabase
                  .from("profiles")
                  .select("ai_credits")
                  .eq("id", user.id)
                  .maybeSingle();

                if (updatedProfile?.ai_credits !== undefined) {
                  remainingCredits = updatedProfile.ai_credits;
                }
              }
            } catch (deductErr) {
              console.error("[chat-assistant] Failed to deduct credit:", deductErr);
            }

            // Persist the completed assistant message to chat_messages
            const assistantMetadata = {
              model: "gemini-3.6-flash",
              latency_ms: Date.now() - startTimeMs,
              turn_count: turnCount,
              tools_called: executedTools.map((t) => t.tool),
              tools_executed: executedTools,
              remaining_credits: remainingCredits,
            };

            await supabase.from("chat_messages").insert({
              user_id: user.id,
              session_id: activeSessionId,
              role: "assistant",
              content: sanitizeText(accumulatedText.trim()),
              metadata: assistantMetadata,
            });

            // Phase 2: Asynchronously extract and update persistent memories if new user facts/goals detected
            extractMemoriesInBackground(
              supabase,
              geminiApiKey,
              user.id,
              userPrompt,
              accumulatedText.trim()
            ).catch((e) => console.warn("[chat-assistant] Auto-memory error:", e));
          }

          // Emit the final SSE event with updated credit balance, session_id, and dynamic suggestions
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({
                done: true,
                remaining_credits: remainingCredits,
                session_id: activeSessionId,
                suggestions: generateDynamicSuggestions(userPrompt),
              })}\n\n`
            )
          );

          controller.close();
        } catch (streamErr) {
          console.error("[chat-assistant] Error inside streaming controller:", streamErr);
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({
                error: String(streamErr),
                done: true,
              })}\n\n`
            )
          );
          controller.close();
        }
      },
    });

    return new Response(customStream, {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      },
    });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[chat-assistant] Fatal exception: ${msg}`);
    return new Response(
      JSON.stringify({ error: "INTERNAL_ERROR", message: msg }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

async function extractMemoriesInBackground(
  supabase: any,
  geminiApiKey: string,
  userId: string,
  userPrompt: string,
  assistantReply: string
): Promise<void> {
  try {
    const triggerRegex = /\b(save|goal|budget|allowance|salary|prefer|target|rent|bill|monthly|owe|debt|pay|plan)\b/i;
    if (!triggerRegex.test(userPrompt)) return;

    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=${geminiApiKey}`;
    const payload = {
      contents: [
        {
          role: "user",
          parts: [
            {
              text: `Extract any new, durable financial facts, goals, or preferences stated by the user.
User: "${userPrompt}"
Assistant: "${assistantReply}"

If there is a clear new fact, goal, or preference, return a JSON array:
[{"memory_type": "fact"|"preference"|"goal"|"event_anchor", "content": "concise description", "confidence": 1.0}]
If there is NO new durable financial fact/preference/goal, return an empty array: [].
Return ONLY raw JSON, without markdown formatting.`,
            },
          ],
        },
      ],
      generationConfig: {
        temperature: 0.1,
        maxOutputTokens: 256,
        thinkingConfig: { thinkingBudget: 0 },
      },
    };

    const res = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    if (!res.ok) return;

    const resJson = await res.json();
    const rawText = resJson.candidates?.[0]?.content?.parts?.[0]?.text?.trim() || "";
    const cleanJson = rawText.replace(/^```json/i, "").replace(/^```/, "").replace(/```$/, "").trim();

    if (cleanJson.startsWith("[")) {
      const items = JSON.parse(cleanJson);
      for (const item of items) {
        if (item.content && item.memory_type) {
          await supabase.rpc("save_user_memory", {
            p_memory_type: String(item.memory_type),
            p_content: String(item.content),
            p_confidence: Number(item.confidence || 0.8),
            p_source: "inferred",
            p_user_id: userId,
          });
          console.log(`[chat-assistant] Auto-extracted memory for ${userId}:`, item.content);
        }
      }
    }
  } catch (err) {
    console.warn("[chat-assistant] Background memory extraction skipped:", err);
  }
}

function generateDynamicSuggestions(prompt: string): string[] {
  const p = prompt.toLowerCase();
  if (p.includes("allowance") || p.includes("salary") || p.includes("income")) {
    return [
      "What was my biggest spend?",
      "How much can I safely spend each day?",
      "Break down my spending by category",
    ];
  }
  if (p.includes("category") || p.includes("breakdown") || p.includes("shops")) {
    return [
      "How does September compare to August?",
      "Who did I send money to?",
      "What is my current safe daily limit?",
    ];
  }
  if (p.includes("balance") || p.includes("afford") || p.includes("safe")) {
    return [
      "How long will my money last?",
      "Are there any recurring bills coming up?",
      "Where did my allowance go?",
    ];
  }
  if (p.includes("goal") || p.includes("save") || p.includes("target")) {
    return [
      "What is my safe limit after saving?",
      "Where can I cut back on spending?",
      "What are my top spending categories?",
    ];
  }
  return [
    "Where did my allowance go?",
    "What are my top spending categories?",
    "How did September compare to August?",
  ];
}


