---
layout: default
title: "Scenario Analyzer"
grand_parent: English
parent: Skill Guides
nav_order: 36
lang_peer: /ja/skills/scenario-analyzer/
permalink: /en/skills/scenario-analyzer/
---

# Scenario Analyzer
{: .no_toc }

Analyze news headlines to build 18-month investment scenarios. Uses the `scenario-analyst` agent for primary analysis and the `strategy-reviewer` agent for a second opinion. Generates comprehensive reports including primary/secondary/tertiary sector impacts, stock picks, and critical review. Output is in Japanese.
{: .fs-6 .fw-300 }

<span class="badge badge-free">No API</span>

[Download Skill Package (.skill)](https://github.com/tradermonty/claude-trading-skills/raw/main/skill-packages/scenario-analyzer.skill){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[View Source on GitHub](https://github.com/tradermonty/claude-trading-skills/tree/main/skills/scenario-analyzer){: .btn .fs-5 .mb-4 .mb-md-0 }

<details open markdown="block">
  <summary>Table of Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## 1. Overview

This skill takes a news headline as input and builds medium-to-long-term (18-month) investment scenarios. It sequentially invokes two specialized agents (`scenario-analyst` and `strategy-reviewer`) to produce a comprehensive report that integrates multi-angle analysis with critical review.

---

## 2. When to Use

- Analyze the medium-to-long-term investment impact of a news headline
- Build multiple 18-month forward-looking scenarios (Base / Bull / Bear)
- Organize sector and stock impacts across primary, secondary, and tertiary levels
- Obtain a comprehensive analysis that includes a second opinion
- Generate a Japanese-language scenario report

**Usage examples:**
```
/headline-scenario-analyzer "Fed raises interest rates by 50bp, signals more hikes ahead"
/headline-scenario-analyzer "China announces new tariffs on US semiconductors"
/headline-scenario-analyzer "OPEC+ agrees to cut oil production by 2 million barrels per day"
```

---

## 3. Prerequisites

- **API Key:** None required
- **Python 3.9+** recommended

---

## 4. Quick Start

```bash
Read references/headline_event_patterns.md
Read references/sector_sensitivity_matrix.md
Read references/scenario_playbooks.md
```

---

## 5. Workflow

### Phase 1: Preparation

#### Step 1.1: Headline Parsing

Parse the headline provided by the user.

1. **Headline verification** -- confirm a headline was passed as an argument; if not, prompt the user for input.
2. **Keyword extraction** -- extract key entities (companies, countries, institutions), numerical data (rates, prices, quantities), and actions (raise, cut, announce, agree, etc.).

#### Step 1.2: Event-Type Classification

Classify the headline into one of the following categories:

| Category | Examples |
|----------|----------|
| Monetary Policy | FOMC, ECB, BOJ, rate hike/cut, QE/QT |
| Geopolitics | War, sanctions, tariffs, trade friction |
| Regulation / Policy | Environmental regulation, financial regulation, antitrust |
| Technology | AI, EV, renewables, semiconductors |
| Commodities | Oil, gold, copper, agriculture |
| Corporate / M&A | Acquisitions, bankruptcies, earnings, industry consolidation |

#### Step 1.3: Load References

Based on the event type, load the relevant reference documents:

```
Read references/headline_event_patterns.md
Read references/sector_sensitivity_matrix.md
Read references/scenario_playbooks.md
```

**Reference contents:**
- `headline_event_patterns.md`: Historical event patterns and market reactions
- `sector_sensitivity_matrix.md`: Event-to-sector impact matrix
- `scenario_playbooks.md`: Scenario-building templates and best practices

---

### Phase 2: Agent Invocation

#### Step 2.1: Invoke scenario-analyst

Use the Agent tool to invoke the primary analysis agent. The agent:
1. Collects related news from the past 2 weeks via WebSearch
2. Builds 3 scenarios (Base / Bull / Bear) with probabilities summing to 100%
3. Analyzes primary / secondary / tertiary impacts by sector
4. Selects 3-5 positively and negatively affected stocks (US-listed only)
5. Outputs everything in Japanese

**Expected output:** related news list, 3 scenario details, sector impact analysis, stock pick list.

#### Step 2.2: Invoke strategy-reviewer

Pass the scenario-analyst output to the review agent. Review criteria:
1. Missed sectors or stocks
2. Scenario probability allocation reasonableness
3. Logical consistency of impact analysis
4. Optimistic / pessimistic bias detection
5. Alternative scenario proposals
6. Timeline realism

**Expected output:** gap identification, probability feedback, bias flags, alternative scenarios, final recommendations.

---

### Phase 3: Integration & Report Generation

#### Step 3.1: Consolidate Results

Integrate both agents' outputs into a final investment thesis:
1. Fill gaps identified by the reviewer
2. Adjust probability allocations if warranted
3. Incorporate bias considerations into the final judgment
4. Formulate a concrete action plan

#### Step 3.2: Generate Report

Save the final report to `reports/scenario_analysis_<topic>_YYYYMMDD.md` in the following structure:

- Headline and event type
- Related news articles
- 3 scenarios (Base / Bull / Bear) with probabilities
- Sector impacts (primary / secondary / tertiary)
- Positively and negatively affected stocks (3-5 each)
- Second opinion / review section
- Final investment thesis with recommended actions, risk factors, and monitoring points

---

---

## 6. Resources

**References:**

- `skills/scenario-analyzer/references/headline_event_patterns.md`
- `skills/scenario-analyzer/references/scenario_playbooks.md`
- `skills/scenario-analyzer/references/sector_sensitivity_matrix.md`
