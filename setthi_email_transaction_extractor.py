"""Setthi MVP v5.3.3 — GLiClass classification + GLiNER2.5 amount extraction.

Tracks ONLY: trial endings, subscription renewals, credit-card statements.
An auxiliary `ordinary_bill` model option disambiguates utility/mobile bills, but
is mapped to `other` in the user-facing output. No ledger or bank transactions.

GLiClass v4 API: `prompt=...`, not `instruction=...`. Dot-separated internal
labels and in-prompt label definitions keep the public taxonomy at four tags.

Privacy: emits a small alert list and optional per-message decisions, not raw mail.
Run in Colab: select GPU, run setup cell, then run code cell.
"""
from __future__ import annotations

import argparse
import base64
import json
import logging
import hashlib
import unicodedata
import re
import sys
import time
from collections import Counter
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from decimal import Decimal, InvalidOperation
from email.header import decode_header
from email.utils import parseaddr, parsedate_to_datetime
from pathlib import Path
from typing import Any

from bs4 import BeautifulSoup

VERSION = "setthi-mvp-v5.3.3-precision-guard"
PUBLIC_LABELS = ("trial_ending", "subscription", "credit_card_statement", "other")
MODEL_LABELS = (
    "reminder.trial_ending",
    "reminder.subscription",
    "reminder.credit_card_statement",
    "not_reminder.ordinary_bill",
    "not_reminder.other",
)
LABEL_MAP = {
    "reminder.trial_ending": "trial_ending",
    "reminder.subscription": "subscription",
    "reminder.credit_card_statement": "credit_card_statement",
    "not_reminder.ordinary_bill": "other",
    "not_reminder.other": "other",
}
TASK_PROMPT = """You classify the PRIMARY PURPOSE of a received email for a small reminder application.
Choose exactly ONE option. Labels have these meanings:
- reminder.trial_ending: An EXISTING free trial will end, expires soon, or has just ended. Includes warnings about an automatic charge after the trial; NOT invitations to start a trial.
- reminder.subscription: An EXISTING subscription, domain, membership or recurring paid service will renew, be billed, or expire; includes confirmed scheduled auto-renewal in an order confirmation. NOT ads to upgrade, free-plan onboarding, or marketing prices.
- reminder.credit_card_statement: An actual CREDIT CARD statement, monthly card billing summary, or payment due reminder. Expect credit-card/account indicators, card ending digits, statement balance or minimum amount due. A mobile postpaid bill, utility invoice or an ordinary receipt is NOT a credit-card statement.
- not_reminder.ordinary_bill: An electricity, mobile, utility, internet or ordinary invoice/bill with payment due; NOT a credit-card statement. Ignore this category for the MVP.
- not_reminder.other: Login/OAuth alerts, general security notices, receipts for completed purchases, promotions, trial-start notices, upgrades, general product newsletters, or anything outside the three reminder categories.
Generic auto-renewal clauses, hypothetical trial endings, tutorials, sample card statements, and sign-up offers do NOT establish an actual user obligation.
Prefer the subject and primary message. Ignore generic legal footers and unrelated links.
Choose the most specific class; do not infer a credit card from the word 'bill' alone.
"""

@dataclass(frozen=True)
class Settings:
    input_file: str = "/content/latest_gmail_raw_api.json"
    output_file: str = "/content/setthi_mvp_results.json"
    classifier_model: str = "knowledgator/gliclass-v4-edge"
    gliner_model: str = "fastino/gliner2.5-base-v1"
    use_gliner: bool = True
    max_body_chars: int = 3400
    max_messages: int = 0
    min_score: float = 0.48  # heuristic screening, not calibrated on Setthi
    min_margin: float = 0.08
    amount_model_threshold: float = 0.25  # GLiNER discovery threshold, not calibrated
    today: date | None = None  # Optional deterministic/testing override
    timezone_name: str = "Asia/Kolkata"  # Backend: pass each user's IANA timezone
    state_file: str | None = None  # Optional JSON event registry; must be durable in production
    save_decisions: bool = True
    log_level: str = "INFO"  # INFO: per-email logs; DEBUG: extra parsing/trace details

MONTH = r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t|tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
DATE_RE = re.compile(
    rf"(?<!\w)(?:\d{{4}}[-/]\d{{1,2}}[-/]\d{{1,2}}|\d{{1,2}}[-/]\d{{1,2}}[-/]\d{{2,4}}|"
    rf"\d{{1,2}}(?:st|nd|rd|th)?\s+{MONTH}\s*,?\s*\d{{4}}|"
    rf"{MONTH}\s+\d{{1,2}}(?:st|nd|rd|th)?,?\s+\d{{4}}|"
    rf"\d{{1,2}}(?:st|nd|rd|th)?\s+{MONTH}|{MONTH}\s+\d{{1,2}}(?:st|nd|rd|th)?)\b", re.I)
MONEY_RE = re.compile(
    r"(?<!\w)(?P<symbol>INR|Rs\.?|₹|USD|\$|EUR|€|GBP|£)\s*"
    r"(?P<num>(?:\d{{1,3}}(?:,\d{{2,3}})+|\d+)(?:\.\d{{1,2}})?)(?!\d)".replace("{{", "{").replace("}}", "}"), re.I)
CC_CARD = re.compile(r"\b(?:credit\s*card|card\s*(?:ending|number|no\.?|\*{2,}|x{2,}|#)|visa|mastercard|rupay|amex)\b", re.I)
CC_STATEMENT = re.compile(r"\b(?:statement|amount\s+due|minimum\s+(?:amount\s+)?due|payment\s+due|statement\s+balance|outstanding\s+balance)\b", re.I)
ORDINARY_BILL = re.compile(r"\b(?:mobile\s+bill|postpaid|electricity|utility\s+bill|broadband\s+bill|internet\s+bill|gas\s+bill)\b", re.I)
TRIAL_END = re.compile(r"\btrial\b.{0,95}\b(?:end(?:s|ed|ing)?|expir(?:es|ed|ing|y|ation)|finish(?:es|ed|ing)?)\b|\b(?:end(?:s|ed|ing)?|expir(?:es|ed|ing|y|ation))\b.{0,95}\btrial\b", re.I | re.S)
TRIAL_STARTED = re.compile(r"\btrial\b.{0,25}\b(?:started|began|activated|is\s+ready)\b|\b(?:start|activate|try)\b.{0,35}\b(?:free\s+)?trial\b", re.I)
RENEWAL = re.compile(r"\b(?:auto[-\s]?renews?|auto[-\s]?renewal|automatic\s+renewal|renews?\s+on|renewal\s+date|subscription\s+(?:renews?|expires?|ends?)|next\s+(?:billing|charge|payment)\s+date|will\s+be\s+(?:charged|renewed))\b", re.I)
# Require a PERSONAL confirmed renewal, not generic subscription T&Cs such as
# "Uber One is a subscription that auto-renews" or "your auto-renewal date".
RENEWAL_EXPLICIT = re.compile(
    r"\b(?:auto[-\s]?renews?\s+on\s+(?:\d|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"
    r"|your\s+(?:(?:existing|current|active)\s+)?(?:subscription|membership|plan|domain|service)\s+"
    r"(?:will\s+(?:be\s+)?|is\s+(?:scheduled\s+to\s+|going\s+to\s+|set\s+to\s+)?)?"
    r"(?:automatically\s+|auto[-\s]?)?(?:renew(?:s|ed|ing)?|expir(?:e|es|ed|ing)?|end(?:s|ed|ing)?)\b"
    r"|(?:your\s+)?next\s+(?:billing|renewal|payment|charge)\s+date\b"
    r"|renewal\s+(?:is\s+)?scheduled\s+(?:for|on)\b"
    r"|your\s+.{1,70}?\s+auto[-\s]?renews?\s+(?:on|in)\b)", re.I)
PROMOTIONAL_INVITATION = re.compile(
    r"\b(?:join\s+(?:our|the|a|[A-Za-z][\w-]*)\s+(?:subscription|membership|one)|"
    r"join\s+.{1,32}?\s+(?:and\s+save|as\s+a\s+member)|"
    r"try\s+(?:\d+\s+(?:days?|weeks?|months?)\s+)?(?:for\s+)?free|"
    r"start\s+(?:your|a)\s+free\s+trial|"
    r"sign\s+up\s+(?:today|now|for)|"
    r"choose\s+(?:your|a)\s+plan|become\s+a\s+member|"
    r"upgrade\s+(?:to|now))\b", re.I)

NEGATIVE_PRICE = re.compile(r"\b(?:upgrade\s+to|upgrade\s+now|lifetime\s+access|special\s+offer|save\s+\d+%|only\s+for|sign\s+up|start\s+your\s+free\s+trial)\b",re.I)
AMOUNT_CUES = {
    "trial_ending": re.compile(r"\b(?:next\s+payment|after\s+(?:the\s+)?trial|automatically\s+charged|you(?:'|’)?ll\s+be\s+charged|renewal\s+(?:amount|price)|payment\s+date)\b",re.I),
    "subscription": re.compile(r"\b(?:next\s+(?:payment|charge|bill)|auto[-\s]?renew(?:s|al)?|renewal\s+(?:amount|price)|(?:will\s+be\s+)?charged|recurring\s+payment)\b",re.I),
    "credit_card_statement": re.compile(r"\b(?:total\s+(?:amount\s+)?due|statement\s+balance|amount\s+payable|outstanding\s+balance|payment\s+due|minimum\s+(?:amount\s+)?due|amount\s+due)\b",re.I),
}
# GLiNER2.5 does the extraction. There are only two model entity types per
# reminder: the target amount, and any other money amount for comparison.
# Regex NEVER scans the full email to invent an amount; it only normalizes and
# ranks spans actually returned by GLiNER.
AMOUNT_ENTITY_SCHEMAS = {
    "trial_ending": {
        "reminder_amount": "Monetary amount to be charged after this existing free trial ends or converts to a paid plan. Exclude upgrades, discount offers and unrelated prices.",
        "money_amount": "Any monetary amount, currency amount, or price stated in this text.",
    },
    "subscription": {
        "reminder_amount": "Upcoming automatic renewal or next recurring subscription charge amount. Exclude current order totals, original purchase price, marketing offers and taxes.",
        "money_amount": "Any monetary amount, currency amount, or price stated in this text.",
    },
    "credit_card_statement": {
        "reminder_amount": "Total amount due or outstanding statement balance of this credit card bill; not the minimum payment, card limit, rewards, or individual transactions.",
        "money_amount": "Any monetary amount, currency amount, or price stated in this text.",
    },
}
NUMBER_IN_ENTITY = re.compile(r"(?<![\w])(?:\d{1,3}(?:,\d{2,3})+|\d+)(?:\.\d{1,2})?(?![\w])")
CURRENCY_IN_ENTITY = re.compile(r"(?<![A-Za-z])(?:INR|Rs\.?|₹|USD|\$|EUR|€|GBP|£)(?![A-Za-z])", re.I)

DATE_CUES = {
    "trial_ending": [
        (re.compile(r"\b(?:trial\b.{0,85}\b(?:end|expir|finish)|(?:end|expir)\b.{0,65}\btrial)\w*\b", re.I | re.S), 30),
        (re.compile(r"\b(?:trial\s+end\s+date|payment\s+date|next\s+payment\s+date)\b",re.I),10),
    ],
    "subscription": [
        (re.compile(r"\b(?:auto[-\s]?renews?|renews?|renewal|next\s+(?:payment|billing|charge)|subscription\s+end|expires?|expiry)\b",re.I),25),
    ],
    "credit_card_statement": [
        (re.compile(r"\b(?:payment\s+due(?:\s+date)?|due\s+(?:on|date|by)|pay\s+by|last\s+date\s+to\s+pay|minimum\s+(?:amount\s+)?due)\b",re.I),30),
    ],
}
CURRENCY = {"inr":"INR", "rs":"INR", "rs.":"INR", "₹":"INR", "usd":"USD", "eur":"EUR", "€":"EUR", "gbp":"GBP", "£":"GBP"}


LOGGER = logging.getLogger("setthi.mvp")


def configure_logging(level: str = "INFO") -> None:
    """Visible Colab/CLI logging without duplicating handlers after cell reruns."""
    level = str(level).upper()
    if level not in ("DEBUG", "INFO", "WARNING", "ERROR"):
        raise ValueError(f"Invalid log level {level!r}")
    LOGGER.setLevel(getattr(logging, level))
    LOGGER.propagate = False
    if not LOGGER.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(logging.Formatter(
            "%(asctime)s | %(levelname)-7s | %(message)s", datefmt="%H:%M:%S"))
        LOGGER.addHandler(handler)
    for handler in LOGGER.handlers:
        handler.setLevel(getattr(logging, level))


def _subject_for_log(subject: str, width: int = 105) -> str:
    """Redact obvious addresses / long numbers; never log raw message bodies."""
    value = " ".join(str(subject).split())
    value = re.sub(r"[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}", "[email]", value)
    value = re.sub(r"(?<!\d)\d{8,}(?!\d)", "[number]", value)
    return value[:width] + ("..." if len(value) > width else "")


def _decode_header(value: str) -> str:
    try:
        return "".join(x.decode(enc or "utf-8", "replace") if isinstance(x,bytes) else str(x)
                       for x,enc in decode_header(value))
    except Exception: return value


def _b64(value: str) -> str:
    return base64.urlsafe_b64decode(value + "="*(-len(value)%4)).decode("utf-8", "replace")


def _clean(text: str, html: bool = False) -> str:
    if html:
        soup=BeautifulSoup(text,"html.parser")
        for tag in soup(["script","style","head","noscript","meta"]):tag.decompose()
        text=soup.get_text("\n", strip=True)
    return "\n".join(x.strip() for x in text.replace("\r","\n").splitlines() if x.strip())


def parse_email(item: dict) -> dict:
    if not isinstance(item,dict): raise ValueError("Email must be JSON object")
    p=item.get("payload")
    if isinstance(p,dict):
        h={str(x.get("name","")).lower():_decode_header(str(x.get("value",""))) for x in p.get("headers",[]) if isinstance(x,dict)}
        subject=h.get("subject", ""); sender=h.get("from", ""); sent=h.get("date", "")
        plains=[]; htmls=[]; attachments=[]
        def walk(node):
            mime=str(node.get("mimeType") or "").lower()
            body=node.get("body") or {}
            if node.get("filename") or body.get("attachmentId"):
                attachments.append(node.get("filename") or mime)
            elif body.get("data") and mime in ("text/plain","text/html"):
                try:(plains if mime=="text/plain" else htmls).append(_b64(body["data"]))
                except (ValueError,UnicodeError,base64.binascii.Error):pass
            for part in node.get("parts") or []:
                if isinstance(part,dict):walk(part)
        walk(p)
        if plains:body=_clean("\n".join(plains))
        elif htmls:body=_clean("\n".join(htmls),True)
        else:body=str(item.get("snippet") or "")
        attachment_count=len(attachments)
    else:
        subject=str(item.get("subject") or "");sender=str(item.get("from") or "")
        sent=item.get("date") or "";body=str(item.get("body") or item.get("text") or "")
        attachment_count=0
    addr=parseaddr(sender)[1];domain=addr.rsplit("@",1)[-1].lower() if "@" in addr else None
    try:
        if isinstance(sent,(int,float)):sent_date=datetime.fromtimestamp(float(sent),tz=timezone.utc).date()
        else:sent_date=parsedate_to_datetime(str(sent)).date()
    except Exception:
        try:sent_date=datetime.fromtimestamp(int(item["internalDate"])/1000,timezone.utc).date()
        except Exception:sent_date=None
    return {"id":str(item.get("id") or item.get("messageId") or ""),"subject":subject,
            "body":body,"sender_domain":domain,"sent_date":sent_date,"attachment_count":attachment_count}


def model_input(mail: dict, settings: Settings) -> str:
    body=mail['body'][:settings.max_body_chars]
    # Avoid HTML footer and long link pollution by retaining the beginning of the real message.
    return f"Subject: {mail['subject']}\nMessage: {body}"


def _parse_scores(raw: Any) -> dict[str,float]:
    """Accept GLiClass flat predictions, hierarchical dicts, and one-item batches."""
    import math
    known={s.lower():s for s in MODEL_LABELS}
    scores={}
    def visit(x: Any, prefix: str = ""):
        if isinstance(x,(tuple,list)):
            for item in x:visit(item,prefix)
        elif isinstance(x,dict):
            if 'label' in x and 'score' in x:
                name=str(x['label']).lower().strip()
                if name not in known and prefix:
                    name=f'{prefix}.{name}'
                if name in known:
                    try:
                        value=float(x['score'])
                        if math.isfinite(value) and 0<=value<=1:scores[known[name]]=value
                    except (ValueError,TypeError): pass
            else:
                for key,v in x.items():
                    name=f"{prefix}.{key}".strip('.').lower()
                    if isinstance(v,(list,dict)):visit(v,name)
                    elif name in known:
                        try:
                            value=float(v)
                            if math.isfinite(value) and 0<=value<=1:scores[known[name]]=value
                        except (ValueError,TypeError):pass
    visit(raw)
    if not scores:
        raise ValueError(f"Unsupported GLiClass response: {type(raw).__name__}; no matching label scores")
    return scores


class GLiClassClassifier:
    def __init__(self, settings:Settings):
        t0 = time.perf_counter()
        LOGGER.info("MODEL | Loading GLiClass: %s", settings.classifier_model)
        import torch
        from gliclass import GLiClassModel, ZeroShotClassificationPipeline
        device="cuda:0" if torch.cuda.is_available() else "cpu"
        LOGGER.info("MODEL | Compute device: %s", device)
        try:model=GLiClassModel.from_pretrained(settings.classifier_model,torch_dtype=torch.float16 if device.startswith("cuda") else torch.float32)
        except TypeError:model=GLiClassModel.from_pretrained(settings.classifier_model)
        model=model.to(device).eval()
        self.pipe=ZeroShotClassificationPipeline(model,settings.classifier_model,
                 classification_type="single-label",max_length=1536,device=device,progress_bar=False)
        LOGGER.info("MODEL | GLiClass ready in %.2fs (five internal labels)", time.perf_counter()-t0)
    def classify(self, text:str)->dict:
        import torch
        with torch.inference_mode():
            raw=self.pipe(text,list(MODEL_LABELS),prompt=TASK_PROMPT,
                           classification_type="single-label",return_hierarchical=True)
        scores=_parse_scores(raw)
        ranked=sorted(scores.items(),key=lambda kv:-kv[1])
        return {"label":ranked[0][0], "score":round(ranked[0][1],4),
                "margin":round(ranked[0][1]-(ranked[1][1] if len(ranked)>1 else 0),4)}


class GLiNERExtractor:
    """Local GLiNER2.5 model, reused for monetary amounts and optional provider NER."""
    def __init__(self, settings: Settings):
        t0 = time.perf_counter()
        LOGGER.info("MODEL | Loading GLiNER2.5 for amount extraction: %s", settings.gliner_model)
        import torch
        from gliner2 import AutoExtractor
        opts = {"map_location": "cuda" if torch.cuda.is_available() else "cpu"}
        if opts["map_location"] == "cuda":
            opts["quantize"] = True
        self.model = AutoExtractor.from_pretrained(settings.gliner_model, **opts)
        self.model.eval()
        self.settings = settings
        LOGGER.info("MODEL | GLiNER ready in %.2fs | amount extraction enabled", time.perf_counter()-t0)

    def extract_amount(self, mail: dict, tag: str) -> dict | None:
        if tag not in AMOUNT_ENTITY_SCHEMAS:
            return None
        text = f"Subject: {mail['subject']}\nMessage: {mail['body'][:5600]}"
        result = self.model.extract_entities_long(
            text, AMOUNT_ENTITY_SCHEMAS[tag], threshold=self.settings.amount_model_threshold,
            chunk_size=280, chunk_overlap=48, include_spans=True, include_confidence=True,
        )
        return select_gliner_amount(text, result, tag)

    def extract(self, text: str) -> str | None:
        text = text[:1250]
        result = self.model.extract_entities_long(
            text, ["subscription service or card issuer"], chunk_size=280,
            chunk_overlap=48, include_spans=True, include_confidence=True,
        )
        candidates = result.get("entities", {}).get("subscription service or card issuer", []) if isinstance(result, dict) else []
        for entity in sorted(candidates, key=lambda x: -(x.get("confidence") or 0) if isinstance(x, dict) else 0):
            if not isinstance(entity, dict):
                continue
            a,b,name = entity.get("start"),entity.get("end"),entity.get("text")
            if isinstance(a,int) and isinstance(b,int) and isinstance(name,str) and text[a:b] == name and a < 900 and 2 <= len(name) <= 60:
                if not re.search(r"\b(?:login|support|account|help|chat|store|subscribe)\b", name, re.I):
                    return name
        return None


class LazyGLiNER:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.impl = None

    def _load(self):
        if self.impl is None:
            try:
                self.impl = GLiNERExtractor(self.settings)
            except Exception as exc:
                LOGGER.exception("MODEL | GLiNER amount model failed to initialize")
                raise RuntimeError(f"GLiNER amount model cannot load: {type(exc).__name__}: {exc}") from exc
        return self.impl

    def extract_amount(self, mail: dict, tag: str) -> dict | None:
        try:
            return self._load().extract_amount(mail, tag)
        except Exception:
            LOGGER.exception("AMOUNT | GLiNER extraction failed for email %s", mail['id'][:16])
            raise

    def extract(self, text: str) -> str | None:
        # Provider extraction is best-effort; required amount extraction is not.
        try:
            return self._load().extract(text)
        except Exception:
            LOGGER.warning("MODEL | GLiNER provider extraction failed; sender domain fallback used")
            return None


def _source_money(text: str, start: int, end: int) -> tuple[str, str | None] | None:
    """Normalize a GLiNER source span. Never search the full email for money."""
    phrase = text[start:end]
    if not phrase or len(phrase) > 90:
        return None
    nums = list(NUMBER_IN_ENTITY.finditer(phrase))
    if len(nums) != 1:
        return None
    try:
        value = Decimal(nums[0].group().replace(",", ""))
        if not value.is_finite() or value < 0:
            return None
        value_str = str(value.quantize(Decimal("0.01")))
    except (InvalidOperation, ValueError):
        return None
    # Currency can be outside the extracted span: "₹" + model span "899.00".
    near = text[max(0,start-9):min(len(text),end+9)]
    symbols = list(CURRENCY_IN_ENTITY.finditer(phrase)) or list(CURRENCY_IN_ENTITY.finditer(near))
    currency = None
    if symbols:
        sym = symbols[-1].group().lower()
        currency = CURRENCY.get(sym)
        if sym == "$":
            currency = "USD" if re.search(r"\b(?:USD|US dollars?)\b", text[max(0,start-70):end+70], re.I) else None
    return value_str, currency


def select_gliner_amount(text: str, result: Any, tag: str) -> dict | None:
    """Pick a literal GLiNER money span using the relevant reminder's nearby cue."""
    if not isinstance(result, dict) or not isinstance(result.get('entities'), dict):
        raise ValueError('GLiNER returned an unexpected extraction response; expected entities mapping')
    candidates = []
    for label in ('reminder_amount', 'money_amount'):
        for entity in result['entities'].get(label, []) or []:
            if not isinstance(entity, dict):
                continue
            raw = entity.get('text')
            a,b = entity.get('start'),entity.get('end')
            if not isinstance(raw,str):
                continue
            if not (isinstance(a,int) and isinstance(b,int) and 0<=a<b<=len(text) and text[a:b]==raw):
                # Do not trust a model value that cannot be located verbatim.
                # For old model responses without spans, accept ONLY unique matches.
                if not isinstance(a,int) and not isinstance(b,int) and text.count(raw)==1:
                    a=text.index(raw);b=a+len(raw)
                else:
                    continue
            amount = _source_money(text,a,b)
            if not amount:
                continue
            try:
                conf = float(entity.get('confidence', 0.5))
            except (TypeError,ValueError):
                conf = 0.5
            if not 0<=conf<=1:
                continue
            before = text[max(0,a-195):a]
            after = text[b:min(len(text),b+65)]
            cue_hits = list(AMOUNT_CUES[tag].finditer(before))
            nearest = len(before)-cue_hits[-1].end() if cue_hits else 999
            direct_cue = bool(cue_hits and nearest<=125)
            # For general emails the model's semantic label can supply evidence
            # when the wording is unfamiliar; literal spans remain mandatory.
            semantic = label=='reminder_amount' and conf>=0.70
            if not (direct_cue or semantic):
                continue
            # A model might label card-ending digits, a date, or an order ID
            # as an amount. Without a nearby currency sign, require an actual
            # charge/due cue, even if the entity label is confident.
            nearby_currency = bool(CURRENCY_IN_ENTITY.search(text[max(0,a-10):min(len(text),b+10)]))
            if not nearby_currency and not direct_cue:
                continue
            local = before[-85:] + text[a:b] + after[:35]
            if NEGATIVE_PRICE.search(local) and not direct_cue:
                continue
            if tag=='trial_ending' and re.search(r'\b(?:lifetime|one[- ]time|special offer)\b',local,re.I) and not direct_cue:
                continue
            # A statement may show both min due and total due. Prefer total.
            priority = 0.0
            if tag=='credit_card_statement':
                if re.search(r'\b(?:total\s+(?:amount\s+)?due|statement\s+balance|outstanding\s+balance)\b', before[-85:], re.I):
                    priority += 45
                if re.search(r'\bminimum\s+(?:amount\s+)?due\b', before[-80:],re.I):
                    priority -= 35
            if tag=='subscription':
                if re.search(r'\b(?:order\s+total|total\s+order|checkout)\b',before[-65:],re.I) and not direct_cue:
                    continue
            # Local relevance outranks label score to prevent e.g. order total.
            score = (65 if direct_cue else 0) + (26 if label=='reminder_amount' else 0) + priority
            score += max(0,140-nearest)/10 if direct_cue else 0
            score += conf*12 - a/10000
            candidates.append((score, a, {'amount':amount[0], 'currency':amount[1],
                                          'model_label':label,'confidence':round(conf,4),
                                          'source_span':[a,b], 'source_text':raw}))
    if not candidates:
        return None
    candidates.sort(key=lambda c: (-c[0], c[1]))
    chosen = candidates[0][2]
    LOGGER.debug('AMOUNT | GLiNER candidates=%d selected_label=%s conf=%.3f',
                 len(candidates),chosen['model_label'],chosen['confidence'])
    return chosen


# High-precision safeguards for post-model evidence recovery. These are not
# financial entity classifiers: they only distinguish an actual personalized
# notice from educational examples, offers, and conditional marketing terms.
EXPLANATION_SUBJECT = re.compile(
    r"\b(?:how\s+to|how\s+do|guide\s+to|tips\s+(?:for|on)|tutorial|"
    r"(?:sample|example|template|hypothetical|demo)\s+(?:credit|card|statement|trial|subscription)|"
    r"understanding\s+(?:your\s+)?(?:credit|card|statement)|"
    r"learn\s+(?:how|to|about)|what\s+(?:is|are)\s+(?:a|your|the)\s+(?:credit|trial|statement))\b", re.I)
INVITATION_SUBJECT = re.compile(
    r"\b(?:sign\s+up|join\b|subscribe\b|try\s+(?:a|the|your|our)?\s*(?:free\s+)?trial|"
    r"start\s+(?:a|your|the)\s+(?:free\s+)?trial|"
    r"get\s+(?:a|your|our)\s+(?:free\s+)?(?:trial|membership|subscription)|"
    r"(?:free\s+trial|membership|subscription)\s+(?:offer|invitation)|"
    r"choose\s+(?:a|your)\s+plan|upgrade\s+(?:your|to|now))\b", re.I)
HYPOTHETICAL = re.compile(
    r"\b(?:for\s+example|e\.g\.|hypothetical(?:ly)?|sample\s+(?:message|email|statement)|"
    r"if\s+(?:you|a\s+customer|someone)\s+(?:start|begin|activate|sign\s+up|join|subscribe|have)|"
    r"once\s+you\s+(?:start|activate|join|sign\s+up)|"
    r"when\s+you\s+(?:start|activate|sign\s+up|join))\b", re.I)
PERSONAL_TRIAL = re.compile(
    r"\b(?:your|your\s+current|an\s+existing|your\s+existing|current|active)\b.{0,100}\btrial\b", re.I|re.S)
EXISTING_RENEWAL = re.compile(
    r"\byour\s+(?:(?:existing|current|active|paid)\s+)?"
    r"(?:[a-zA-Z0-9.-]+\s+){0,3}(?:subscription|plan|membership|domain|service|product)\b"
    r".{0,125}\b(?:auto[-\s]?renew|renew|expir|end|next\s+(?:payment|billing|charge))", re.I|re.S)
CONFIRMED_ORDER = re.compile(
    r"\b(?:order\s+confirmation|your\s+order\b|thanks\s+for\s+buying|"
    r"thank\s+you\s+for\s+(?:purchasing|your\s+order)|"
    r"purchase\s+confirmation|order\s+number|you\s+purchased|"
    r"your\s+purchase\b)\b", re.I)
PURCHASED_SERVICE = re.compile(
    r"\b(?:domain\s+registration|registered\s+domain|product\s+registration|"
    r"your\s+(?:new|registered)\s+domain|purchased\s+(?:domain|service|membership|plan)|"
    r"\d+\s+(?:year|month)s?\s+auto[-\s]?renew)\b", re.I)
CARD_NOTICE = re.compile(
    r"\b(?:your\b.{0,95}\b(?:credit\s+card\s+statement|card\s+statement)|"
    r"\byour\s+(?:credit\s+)?card\b.{0,95}\b(?:amount\s+due|payment\s+due|bill)|"
    r"\byour\s+statement\s+(?:is\s+ready|has\s+been\s+(?:generated|issued)|for\s+\w+))\b", re.I|re.S)
CARD_BALANCE = re.compile(
    r"\b(?:total\s+(?:amount\s+)?due|statement\s+balance|"
    r"minimum\s+(?:amount\s+)?due|payment\s+due|outstanding\s+balance)\s*[:\-]?\s*"
    r"(?:INR|Rs\.?|₹|USD|\$|EUR|€|GBP|£)\s*[\d,]+", re.I)
CARD_PERSONAL_ACCOUNT = re.compile(
    r"\b(?:card|account)\s+(?:ending|no\.?|number|xx|x{2,}|\*{2,})\b|[xX*]{2,}\d{3,4}",re.I)


def _primary_content(mail:dict)->str:
    """Keep the subject and main message; discard frequent marketing footers."""
    subject=mail.get('subject','')
    body=''.join(c for c in mail.get('body','') if unicodedata.category(c) != 'Cf')
    boilerplate=re.search(
        r"\b(?:view\s+the\s+renewable\s+membership\s+t\s*&\s*cs|"
        r"terms\s+(?:and|&)\s+conditions\s*[:\n]|"
        r"email\s+preferences|to\s+unsubscribe\b|"
        r"benefits\s+available\s+only\s+where)\b",body,re.I)
    if boilerplate:body=body[:boilerplate.start()]
    return subject+'\n'+body[:2600]


def _is_general_explanation(subject:str,primary:str)->bool:
    """Reject explainers and sample notices, not actual billed statements."""
    if EXPLANATION_SUBJECT.search(subject):
        return True
    intro=primary.split('\n',1)[-1][:220]
    if HYPOTHETICAL.search(intro) and not re.search(r"\b(?:your|attached)\s+(?:credit\s+card\s+)?statement\s+is\s+ready\b",subject,re.I):
        return True
    return False


def _has_card_statement_evidence(text:str) -> bool:
    """Requires a personalized, issued card bill; a tutorial cannot recover a model miss."""
    subject=text.split('\n',1)[0]
    primary=text[:1800]
    if _is_general_explanation(subject,primary):return False
    if not (CC_CARD.search(primary) and CC_STATEMENT.search(primary)):
        return False
    if ORDINARY_BILL.search(primary[:500]) and not re.search(r"\bcredit\s*card\b",primary[:1100],re.I):
        return False
    # The issued-statement subject itself establishes that this is an actual
    # document, even when the due amount lives in an unprocessed PDF.
    addressed_statement=bool(re.search(r"\b(?:your|fwd:\s*your)\b.{0,100}\b(?:credit\s+card|card)\s+statement\b",subject,re.I))
    actual_billing=bool(CARD_BALANCE.search(primary) and (CARD_NOTICE.search(primary) or CARD_PERSONAL_ACCOUNT.search(primary)))
    if addressed_statement or actual_billing:return True
    return False


def _explicit_trial_notice(text:str)->bool:
    """Existing trial end notices only; exclude offers with conditional end dates."""
    primary=text[:1150]
    subject=primary.split('\n',1)[0]
    if _is_general_explanation(subject,primary) or INVITATION_SUBJECT.search(subject):return False
    trial_subject=TRIAL_END.search(subject)
    if trial_subject and (PERSONAL_TRIAL.search(subject) or re.search(r"\btrial\s+(?:ending|expired|expires|ends)\s+reminder\b",subject,re.I)):
        if HYPOTHETICAL.search(subject):return False
        return True
    # An unspecified body phrase such as 'if you join, your trial ends ...'
    # is *not* proof of an existing subscription trial.
    main=primary.split('\n',1)[-1]
    hit=TRIAL_END.search(main)
    if not hit:return False
    if not PERSONAL_TRIAL.search(main[max(0,hit.start()-130):hit.end()+100]):return False
    if HYPOTHETICAL.search(main[max(0,hit.start()-145):hit.end()+45]):return False
    promo=PROMOTIONAL_INVITATION.search(main[:min(len(main),hit.end())])
    if promo and promo.start()<hit.start():return False
    if TRIAL_STARTED.search(main[:min(200,hit.start())]):return False
    return True


def _explicit_renewal_notice(mail:dict)->bool:
    """Accept existing account renewals and confirmed purchases, not sign-up terms."""
    primary=_primary_content(mail)
    subject=mail.get('subject','')
    if _is_general_explanation(subject,primary) or INVITATION_SUBJECT.search(subject):return False
    confirmed=RENEWAL_EXPLICIT.search(primary)
    if not confirmed:return False
    promo=PROMOTIONAL_INVITATION.search(primary[:1100])
    if promo and promo.start()<confirmed.start():return False
    if HYPOTHETICAL.search(primary[max(0,confirmed.start()-180):confirmed.end()+40]):return False
    # The phrase 'Auto-renews on <date>' alone describes a plan's *terms*.
    # It only proves a real upcoming charge with an existing personal plan
    # or a purchased/order-confirmed auto-renewing product.
    if EXISTING_RENEWAL.search(subject):return True
    if EXISTING_RENEWAL.search(primary[:min(1500,len(primary))]):return True
    if re.search(r"\byour\s+next\s+(?:billing|renewal|charge|payment)\s+date\b",primary[:1500],re.I):return True
    if re.search(r"\byour\s+.{1,65}?\s+auto[-\s]?renews?\s+(?:on|in)\b",primary[:1500],re.I|re.S):return True
    # GoDaddy-style receipts: order confirmation + acquired product + exact
    # auto-renew date. Don't let marketing plan descriptions through.
    if (CONFIRMED_ORDER.search(primary[:1450]) and PURCHASED_SERVICE.search(primary[:2000])
            and re.search(r"\bauto[-\s]?renews?\s+on\s+(?:\d|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)",primary[:2200],re.I)):
        return True
    return False


def choose_type(mail:dict,decision:dict,settings:Settings)->tuple[str,list[str]]:
    label=decision.get('label')
    if label not in LABEL_MAP:raise ValueError(f"Unrecognized GLiClass label: {label}")
    tag=LABEL_MAP[label]
    head=_primary_content(mail)
    reasons=[]
    trial=_explicit_trial_notice(head)
    renewal=_explicit_renewal_notice(mail)
    card=_has_card_statement_evidence(head)
    if tag=='credit_card_statement' and not card:
        tag='other';reasons.append('credit_card_prediction_lacks_card_evidence')
    elif tag=='trial_ending' and not trial:
        tag='other';reasons.append('trial_prediction_lacks_ending_notice')
    elif tag=='subscription' and not renewal:
        tag='other';reasons.append('subscription_prediction_lacks_confirmed_renewal')
    # A correction may promote a negative classification ONLY with an actual
    # event. The first clause also keeps a genuine free-trial conversion from
    # being mislabeled a normal subscription renewal.
    if trial and tag!='trial_ending':tag='trial_ending';reasons.append('confirmed_existing_trial_end_notice')
    elif not trial and card and tag!='credit_card_statement':tag='credit_card_statement';reasons.append('confirmed_issued_card_statement')
    elif not trial and not card and renewal and tag!='subscription':
        tag='subscription';reasons.append('confirmed_existing_renewal_notice')
    if tag=='other' and not renewal and PROMOTIONAL_INVITATION.search(head[:1100]) and RENEWAL.search(mail['body'][:3400]):
        reasons.append('ignored_promo_renewal_terms')
    return tag,reasons


def _iso(raw:str,sent:date|None)->str|None:
    from dateutil import parser
    t=re.sub(r"(?<=\d)(?:st|nd|rd|th)\b","",raw.strip(),flags=re.I)
    explicit=bool(re.search(r"\b(?:19|20)\d{2}\b",t))
    if not explicit and sent is None:return None
    m=re.fullmatch(r"(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})",t)
    if m:
        a,b=int(m.group(1)),int(m.group(2))
        if a<=12 and b<=12:return None # ambiguous locale, must not schedule
        dayfirst=a>12
    else:dayfirst=not bool(re.match(r"\d{4}",t))
    ref=sent or date(2026,1,1)
    try:
        default=datetime(ref.year,ref.month,min(ref.day,28))
        d=parser.parse(t,dayfirst=dayfirst,default=default).date()
        if not explicit:
            # Yearless dates should be near the email date; don't move expired
            # trial notices a full year into the future.
            possibilities=[]
            for y in (ref.year-1,ref.year,ref.year+1):
                try:possibilities.append(d.replace(year=y))
                except ValueError:pass
            if not possibilities:return None
            d=min(possibilities,key=lambda dt:abs((dt-ref).days))
        if 2000<=d.year<=2100:return d.isoformat()
    except (ValueError,OverflowError,TypeError):pass
    return None


def extract_date(mail:dict,tag:str)->str|None:
    if tag=='other':return None
    # The subject often contains the best date. Build candidate matches separately
    # from the body and require a nearby event-date cue.
    parts=[(mail['subject'],35),(mail['body'][:5500],0)]
    candidates=[]
    for text,subject_bonus in parts:
        for m in DATE_RE.finditer(text):
            left=text[max(0,m.start()-125):m.start()]
            right=text[m.end():m.end()+35]
            if re.search(r"(?:statement\s+date|issued\s+on|last\s+payment\s+date|receipt\s+date)\s*:?\s*$",left[-35:],re.I):continue
            best=None
            for pat,bonus in DATE_CUES[tag]:
                matches=list(pat.finditer(left))
                if matches:
                    near=matches[-1]
                    distance=len(left)-near.end()
                    score=bonus+max(0,100-distance)+subject_bonus-m.start()/1000
                    if best is None or score>best:best=score
            if best is None:continue
            result=_iso(m.group(0),mail['sent_date'])
            if result:candidates.append((best,result))
    if candidates:return max(candidates,key=lambda x:x[0])[1]
    # Relative dates anchored to the SENT date. Future reminders with no explicit
    # date remain unschedulable; never infer one from the current clock.
    sent=mail['sent_date']
    if sent:
        text=(mail['subject']+' '+mail['body'][:900])
        cue=RENEWAL if tag=='subscription' else TRIAL_END if tag=='trial_ending' else CC_STATEMENT
        hit=cue.search(text)
        if hit:
            fragment=text[max(0,hit.start()-15):hit.end()+110]
            d=re.search(r"\bin\s+(\d{1,2})\s+days?\b",fragment,re.I)
            if d:return (sent+timedelta(days=int(d.group(1)))).isoformat()
            if re.search(r"\btomorrow\b",fragment,re.I):return (sent+timedelta(days=1)).isoformat()
    return None



def _provider(mail:dict,tag:str,provider_model:Any=None)->str|None:
    subject=mail['subject'];provider=None
    if tag=='trial_ending':
        p=re.search(r"\btrial\s+for\s+(.{2,80}?)\s+(?:will\s+)?(?:end|expir)",subject,re.I)
        if p:provider=p.group(1).strip(' :,.!-')
    if tag=='subscription':
        p=re.search(r"\byour\s+(.{2,65}?)\s+(?:subscription|membership)\b",subject,re.I)
        if p:provider=p.group(1).strip(' :,.!-')
    if tag=='credit_card_statement':
        p=re.search(r"\b(?:your\s+)?([\w &.-]{2,55}?)\s+credit\s+card\s+statement\b",subject,re.I)
        if p and p.group(1).strip().lower() not in ('your','monthly'):provider=p.group(1).strip(' :,.!-')
    if provider:return provider
    # Prefer domain as a stable provider fallback to speculative entities.
    domain=mail['sender_domain']
    if domain and domain not in ('gmail.com','googlemail.com'):return domain
    if provider_model is not None:
        return provider_model.extract(subject+'\n'+mail['body'][:700]) or domain
    return domain


def classify_email(mail:dict,settings:Settings,classifier:Any,provider_model:Any=None)->tuple[dict|None,dict]:
    decision=classifier.classify(model_input(mail,settings))
    tag,reasons=choose_type(mail,decision,settings)
    LOGGER.info("CLASSIFY | id=%s | model=%s (%.3f, margin=%.3f) -> final=%s%s",
                mail['id'][:16] or "unknown",decision['label'],decision['score'],
                decision['margin'],tag, " | checks="+",".join(reasons) if reasons else "")
    confidence_low=decision['score']<settings.min_score or decision['margin']<settings.min_margin
    decision_log={"message_id":mail['id'],"model_label":decision['label'],
                  "model_score":decision['score'],"model_margin":decision['margin'],
                  "final_type":tag}
    if reasons:decision_log['adjustments']=reasons
    if tag=='other':
        LOGGER.info("SKIP | id=%s | not an MVP reminder",mail['id'][:16] or "unknown")
        return None,decision_log
    when=extract_date(mail,tag)
    if settings.use_gliner and provider_model is None:
        raise RuntimeError('GLiNER is enabled but no extractor is configured')
    extraction = provider_model.extract_amount(mail,tag) if settings.use_gliner else None
    amount = extraction['amount'] if extraction else None
    currency = extraction['currency'] if extraction else None
    extraction_status = ('found' if extraction else 'not_found') if settings.use_gliner else 'disabled'
    LOGGER.info("AMOUNT | id=%s | GLiNER=%s | value=%s | currency=%s%s",
                mail['id'][:16] or "unknown", extraction_status, amount, currency,
                " | model_label="+extraction['model_label']+" conf="+str(extraction['confidence']) if extraction else "")
    LOGGER.debug("EXTRACT | id=%s | date=%s | amount=%s | currency=%s",
                 mail['id'][:16] or "unknown",when,amount,currency)
    today=_reference_date(settings)
    state='unknown'
    if when:
        event=date.fromisoformat(when)
        state='today' if event==today else ('upcoming' if event>today else 'past')
    # Forwarded messages may be about someone else; keep for read-only review.
    forwarded=bool(re.match(r"\s*(?:fwd?|fw)\s*:",mail['subject'],re.I))
    review=bool(confidence_low or not when or forwarded)
    alert={"message_id":mail['id'],"type":tag,"provider":_provider(mail,tag,provider_model),
           "date":when,"timing":state,"amount":amount,"currency":currency,
           "amount_source":"gliner2.5" if extraction else None,"amount_extraction_status":extraction_status,
           "review":review,"reminder_eligible":bool(state in ('today','upcoming') and not review)}
    if extraction:
        alert['amount_evidence']={'text':extraction['source_text'], 'confidence':extraction['confidence'], 'model_label':extraction['model_label'], 'source_span':extraction['source_span']}
    if tag=='credit_card_statement' and mail['attachment_count']:
        alert['attachment_present']=True
        # If amount isn't in the email body, PDF extraction is not done by this MVP.
        if amount is None:alert['review']=True;alert['reminder_eligible']=False
    if forwarded:alert['ownership_unverified']=True
    decision_log['review']=alert['review']
    LOGGER.info("ALERT | id=%s | type=%s | provider=%s | date=%s | timing=%s | amount=%s %s | review=%s | eligible=%s",
                mail['id'][:16] or "unknown",tag,alert['provider'],when,state,amount,currency,
                alert['review'],alert['reminder_eligible'])
    return alert,decision_log


def load_messages(path:str)->list[dict]:
    """Read Gmail API export, identifying invalid or empty input before model load."""
    file=Path(path).expanduser()
    if not file.is_file():
        raise FileNotFoundError(f'Gmail JSON file not found: {file}. Upload the dataset or specify --input PATH.')
    size=file.stat().st_size
    LOGGER.info('INPUT | checking JSON file=%s | size=%.2f MB',file,size/(1024*1024))
    if size == 0:
        raise ValueError(f'Gmail JSON is EMPTY: {file}. Re-upload the actual JSON export (do not use an empty placeholder).')
    try:
        obj=json.loads(file.read_text(encoding='utf-8-sig'))
    except UnicodeError as exc:
        raise ValueError(f'Gmail input is not UTF-8 text: {file}. Re-export as UTF-8 JSON.') from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f'Gmail input is invalid JSON: {file} ({size} bytes); '
                         f'line {exc.lineno}, column {exc.colno}: {exc.msg}. '
                         'Check the selected filename and re-upload the complete JSON export.') from exc
    if isinstance(obj,dict):
        obj=next((obj[k] for k in ('messages','emails','data') if isinstance(obj.get(k),list)),None)
    if not isinstance(obj,list):
        raise ValueError(f'Expected a JSON list of Gmail API messages in {file} (or messages/emails/data list).')
    if not obj:
        raise ValueError(f'Gmail JSON contains zero emails: {file}.')
    if not all(isinstance(r,dict) for r in obj):
        raise ValueError(f'Gmail JSON contains an item that is not an object: {file}.')
    LOGGER.info('INPUT | JSON valid | messages=%d | selected=%s',len(obj),file)
    return obj


def _reference_date(settings:Settings)->date:
    """Use the account's local calendar date, never Colab's server timezone."""
    try: zone=ZoneInfo(settings.timezone_name)
    except (ZoneInfoNotFoundError,ValueError,TypeError) as exc:
        raise ValueError(f'Invalid IANA timezone: {settings.timezone_name!r}') from exc
    return settings.today or datetime.now(zone).date()


def _reminder_key(item:dict,subject:str,sent_date:date|None)->str:
    """Stable and conservative per-event ID, independent of a Gmail message ID.

    Subject is deliberately retained to avoid merging distinct cards/accounts
    with the same provider and due date. Undated notices are read-only and
    scoped to their sender-date so repeat scans remain idempotent.
    """
    clean=re.sub(r'^(?:(?:fwd?|re)\s*:\s*)+','',subject.casefold().strip())
    clean=re.sub(r'\W+',' ',clean).strip()
    key=[item['type'],(item.get('provider') or '').casefold(),
         item.get('date') or f'undated:{sent_date.isoformat() if sent_date else "unknown"}',
         clean]
    return 'sth_'+hashlib.sha256(json.dumps(key,ensure_ascii=False).encode('utf-8')).hexdigest()[:24]


def _load_registry(path:str|None)->dict:
    if not path:return {'version':1,'reminders':{}}
    p=Path(path).expanduser()
    if not p.exists():return {'version':1,'reminders':{}}
    try: obj=json.loads(p.read_text(encoding='utf-8'))
    except (OSError,UnicodeError,json.JSONDecodeError) as exc:
        raise ValueError(f'Reminder state file is unreadable/invalid: {p}. Back it up; it was not overwritten.') from exc
    if not isinstance(obj,dict) or obj.get('version')!=1 or not isinstance(obj.get('reminders'),dict):
        raise ValueError(f'Invalid reminder state format: {p}. Refusing to overwrite.')
    return obj


def _save_registry(path:str,state:dict)->None:
    p=Path(path).expanduser();p.parent.mkdir(parents=True,exist_ok=True)
    tmp=p.with_suffix(p.suffix+'.tmp')
    tmp.write_text(json.dumps(state,ensure_ascii=False,indent=2),encoding='utf-8')
    tmp.replace(p)


def mark_notification_delivered(state_file:str,reminder_id:str,delivery_key:str)->None:
    """Call only *after* a downstream notifier confirms successful delivery.

    ``delivery_key`` identifies a scheduled notification (e.g. 7d/1d/day-of),
    so reprocessing does not send the same event+schedule twice. The pipeline
    itself NEVER sends a notification or marks one as sent.
    """
    if not state_file or not reminder_id or not delivery_key:raise ValueError('state_file, reminder_id and delivery_key are required')
    state=_load_registry(state_file)
    record=state['reminders'].get(reminder_id)
    if record is None:raise KeyError(f'Unknown reminder ID: {reminder_id}')
    done=record.setdefault('delivered',[])
    if delivery_key not in done:done.append(delivery_key)
    _save_registry(state_file,state)


def run_pipeline(settings:Settings,classifier:Any=None,provider_model:Any=None)->dict:
    configure_logging(settings.log_level)
    start=time.perf_counter()
    reference_today=_reference_date(settings)
    LOGGER.info("START | %s | model-first reminder classification | no transaction posting",VERSION)
    LOGGER.info("INPUT | reading %s",settings.input_file)
    messages=load_messages(settings.input_file)
    if settings.max_messages:messages=messages[:settings.max_messages]
    LOGGER.info("INPUT | loaded %d messages | output=%s",len(messages),settings.output_file)
    LOGGER.info("CONFIG | model=%s | GLiNER=%s | log_level=%s | decisions_saved=%s",
                settings.classifier_model,settings.use_gliner,settings.log_level,settings.save_decisions)
    LOGGER.info("CONFIG | reminder date reference=%s | timezone=%s | registry=%s",
                reference_today,settings.timezone_name,settings.state_file or "disabled")
    registry=_load_registry(settings.state_file)
    previously_seen=set(registry['reminders'])

    if classifier is None:classifier=GLiClassClassifier(settings)
    if isinstance(classifier,GLiClassClassifier):
        LOGGER.info("MODEL | Running single-message GLiClass preflight")
        try:
            sample=classifier.classify('Subject: Account login security alert\nMessage: Your password was changed.')
            if sample['label'] not in MODEL_LABELS:
                raise ValueError("preflight returned an unknown label")
        except Exception as exc:
            LOGGER.exception("MODEL | GLiClass preflight failed")
            raise RuntimeError(f'GLiClass preflight failed: {type(exc).__name__}: {str(exc)[:240]}') from exc
        LOGGER.info("MODEL | Preflight OK: %s, score=%.3f",sample['label'],sample['score'])
    else:
        LOGGER.info("MODEL | External classifier supplied (test/integration mode)")
    if settings.use_gliner and provider_model is None:
        provider_model=LazyGLiNER(settings)
        LOGGER.info("MODEL | GLiNER amount extraction enabled; loading on first reminder")
    elif not settings.use_gliner:
        LOGGER.warning("MODEL | GLiNER DISABLED (--no-gliner); amounts intentionally remain null")

    counts=Counter();alerts=[];decisions=[];errors=[];seen={};duplicate_count=0
    LOGGER.info("PROCESS | Beginning per-email classification")
    for i,raw in enumerate(messages):
        t0=time.perf_counter()
        msgid=str(raw.get('id',''))[:16] if isinstance(raw,dict) else "unknown"
        try:
            mail=parse_email(raw)
            LOGGER.info("EMAIL %03d/%03d | id=%s | subject=%s | attachments=%d",
                        i+1,len(messages),mail['id'][:16] or "unknown",
                        _subject_for_log(mail['subject']),mail['attachment_count'])
            item,detail=classify_email(mail,settings,classifier,provider_model)
            if settings.save_decisions:decisions.append(detail)
            if item is None:
                counts['other']+=1
                if detail['model_label']=='not_reminder.ordinary_bill':
                    counts['ordinary_bill_ignored']+=1
                LOGGER.debug("EMAIL %03d/%03d | handled as other in %.1fms",i+1,len(messages),1000*(time.perf_counter()-t0))
                continue
            # Stable identity is independent of Gmail message ID. Same event
            # is grouped in-run and remains stable across repeated scans.
            event_id=_reminder_key(item,mail['subject'],mail['sent_date'])
            item['reminder_id']=event_id
            item['is_new']=event_id not in previously_seen
            key=event_id
            if key in seen:
                original=alerts[seen[key]]
                original.setdefault('source_message_ids',[original['message_id']]).append(item['message_id'])
                duplicate_count+=1
                counts[item['type']]+=1
                LOGGER.info("DEDUP | id=%s | grouped with %s (same reminder_id=%s)",
                            mail['id'][:16],original['message_id'][:16],event_id)
            else:
                seen[key]=len(alerts)
                alerts.append(item);counts[item['type']]+=1
            LOGGER.debug("EMAIL %03d/%03d | completed in %.1fms",i+1,len(messages),1000*(time.perf_counter()-t0))
        except Exception as exc:
            err={'index':i,'message_id':msgid,
                 'error_type':type(exc).__name__,'message':str(exc)[:240]}
            errors.append(err)
            LOGGER.exception("ERROR | email %03d/%03d id=%s failed",i+1,len(messages),msgid)
        finally:
            if (i+1)%10==0 or i+1==len(messages):
                LOGGER.info("PROGRESS | %d/%d processed | saved alerts=%d | errors=%d",
                            i+1,len(messages),len(alerts),len(errors))
    summary={"processed":len(messages),"by_type":{k:counts.get(k,0) for k in PUBLIC_LABELS},
             "alerts":len(alerts),"upcoming":sum(x['timing']=='upcoming' for x in alerts),
             "today":sum(x['timing']=='today' for x in alerts),
             "new_reminders":sum(x['is_new'] for x in alerts),
             "reminder_eligible":sum(x['reminder_eligible'] for x in alerts),
             "review":sum(x['review'] for x in alerts),"duplicates_grouped":duplicate_count,
             "ordinary_bills_ignored":counts['ordinary_bill_ignored'],
             "amounts_from_gliner":sum(x.get('amount_source')=='gliner2.5' for x in alerts),
             "amounts_not_found":sum(x.get('amount_extraction_status')=='not_found' for x in alerts),
             "errors":len(errors),
             "seconds_including_model_load":round(time.perf_counter()-start,2)}
    result={"version":VERSION,"model":settings.classifier_model,"amount_model":settings.gliner_model if settings.use_gliner else None,
            "public_labels":list(PUBLIC_LABELS),
            "today_local":reference_today.isoformat(),"timezone":settings.timezone_name,
            "state_file":settings.state_file,
            "summary":summary,"alerts":alerts,"errors":errors,
            "notes":["GLiNER2.5 extracts amounts; regex only validates and ranks model-returned source spans.",
                     "No emails or PDF attachments were written to output.",
                     "Classification confidence has not been calibrated on Setthi user data.",
                     "No reminders are sent and no financial transactions are created.",
                     "State registry tracks seen reminders, NOT delivered notifications. Call mark_notification_delivered only after confirmed delivery."]}
    if settings.save_decisions:result['decisions']=decisions
    target=Path(settings.output_file);target.parent.mkdir(parents=True,exist_ok=True)
    temp=target.with_suffix(target.suffix+'.tmp')
    temp.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    temp.replace(target)
    # Do not commit seen IDs when processing failed: retries should be safe.
    if not errors and settings.state_file:
        now_utc=datetime.now(timezone.utc).isoformat(timespec='seconds')
        for item in alerts:
            rid=item['reminder_id']
            if rid not in registry['reminders']:
                registry['reminders'][rid]={"type":item['type'],"provider":item.get('provider'),
                                            "date":item.get('date'),"first_seen":now_utc,
                                            "delivered":[]}
            registry['reminders'][rid]['last_seen']=now_utc
        _save_registry(settings.state_file,registry)
        LOGGER.info("STATE | %d reminders registered | %d new | file=%s",
                    len(alerts),summary['new_reminders'],settings.state_file)
    LOGGER.info("OUTPUT | JSON written successfully: %s (%.1f KB)",target,target.stat().st_size/1024)
    LOGGER.info("SUMMARY | %s",summary)
    if errors:
        LOGGER.error("FINISH | %d email(s) failed; see the saved JSON for details",len(errors))
        raise RuntimeError(f'{len(errors)} emails failed; first: {errors[0]["error_type"]}: {errors[0]["message"]}. See {target}')
    LOGGER.info("FINISH | All %d emails processed successfully in %.2fs",len(messages),time.perf_counter()-start)
    return result


def _find_input(path:str|None)->str:
    """Never silently reuse an invalid/stale default file for a new dataset."""
    if path:
        selected=Path(path).expanduser()
        load_messages(str(selected))  # fail before initializing either model
        LOGGER.info('INPUT | selected explicitly: %s',selected)
        return str(selected)
    candidates={}
    for root in (Path.cwd(),Path('/content')):
        if not root.is_dir():
            continue
        for candidate in root.glob('latest_gmail_raw_api*.json'):
            if candidate.is_file():
                candidates[str(candidate.resolve())]=candidate
    # Prefer the newest VALID file; Colab may retain a stale empty canonical file.
    for candidate in sorted(candidates.values(),key=lambda p:p.stat().st_mtime,reverse=True):
        try:
            load_messages(str(candidate))
        except (ValueError,FileNotFoundError) as exc:
            LOGGER.warning('INPUT | ignoring invalid candidate=%s | reason=%s',candidate.name,exc)
            continue
        LOGGER.info('INPUT | automatically selected newest valid file: %s',candidate)
        return str(candidate)
    try:
        from google.colab import files
    except ImportError:
        raise FileNotFoundError('No valid Gmail JSON found. Use --input /path/to/dataset.json')
    LOGGER.info('INPUT | no valid Gmail export found; opening Colab upload dialog')
    uploads=files.upload()
    if len(uploads)!=1:
        raise ValueError('Select exactly one complete Gmail JSON export to process.')
    filename=next(iter(uploads))
    load_messages(filename)
    return filename


def main(argv:list[str]|None=None)->dict:
    parser=argparse.ArgumentParser(description='Setthi MVP V5.3.3 GLiClass + GLiNER amount extraction')
    parser.add_argument('--input',default=None,help='Exact JSON filename; omit to select newest valid latest_gmail_raw_api*.json')
    parser.add_argument('--output',default='/content/setthi_mvp_results.json')
    parser.add_argument('--today',help='Local date YYYY-MM-DD used for reminder status')
    parser.add_argument('--timezone',default='Asia/Kolkata',help='IANA timezone (e.g. Asia/Kolkata, America/New_York)')
    parser.add_argument('--state-file',default=None,help='Persistent registry path; in Colab mount Drive for cross-session persistence')
    parser.add_argument('--no-gliner',action='store_true', help='Debug only: disable GLiNER amount extraction')
    parser.add_argument('--no-decisions',action='store_true')
    parser.add_argument('--max-messages',type=int,default=0)
    parser.add_argument('--log-level',choices=['DEBUG','INFO','WARNING','ERROR'],default='INFO',
                        help='INFO logs every email; DEBUG also logs extracted fields and timings')
    if argv is None:
        launcher=Path(sys.argv[0]).name.lower()
        argv=[] if ('ipykernel' in launcher or 'colab_kernel' in launcher) else sys.argv[1:]
    args=parser.parse_args(argv)
    configure_logging(args.log_level)
    LOGGER.info('BOOT | Setthi MVP V5.3.3 started | GLiClass classify, GLiNER2.5 extract amounts | 3 reminder types')
    return run_pipeline(Settings(input_file=_find_input(args.input),output_file=args.output,
                                 use_gliner=not args.no_gliner,max_messages=args.max_messages,
                                 today=date.fromisoformat(args.today) if args.today else None,
                                 timezone_name=args.timezone,state_file=args.state_file,
                                 save_decisions=not args.no_decisions,log_level=args.log_level))

if __name__=='__main__':main()
