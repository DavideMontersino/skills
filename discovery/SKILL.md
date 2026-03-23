---
name: discovery
description: Run a discovery phase before solutioning. Abstracts the task, researches existing patterns/frameworks/standards/regulatory context, and produces a structured brief. Use when starting non-trivial new work. In any case, always run after running the JIRA skill to understand the task or before writing EDDs.
---

# Discovery

Pre-solutioning research phase. Before jumping into implementation, abstract the problem, survey the landscape, and produce a structured brief.

## When to Use

- Starting a new feature or system (audit trail, allocation engine, validation framework, etc.)
- The task touches domains with established patterns (compliance, event sourcing, document processing, etc.)
- You're unsure whether to build, buy, or compose existing solutions
- The user explicitly asks for research before implementation

## When NOT to Use

- Bug fixes, small tweaks, refactors with clear scope
- Tasks where the user has already provided a detailed spec
- Pure implementation work on an existing EDD

## Workflow

### 1. Understand the task

Read the user's request. If they provided a Jira ticket, EDD, or other context, read it.

### 2. Abstract the problem

Ask: **"What are we actually trying to solve?"**

Strip away project-specific details and identify the underlying problem category. Examples:

| Task as stated | Abstracted problem |
|---|---|
| "Add audit trail to batch operations" | Change data capture / event sourcing / compliance logging |
| "Build a validation framework for documents" | Domain validation / rules engine / constraint checking |
| "Implement volume allocation reconciliation" | Double-entry bookkeeping / ledger reconciliation / balance verification |
| "Add ML extraction pipeline" | Document intelligence / OCR pipeline / structured data extraction |

Write down 2-4 alternative framings of the problem. Each framing opens different search paths.

### 3. Research the landscape

For each problem framing, run web searches targeting (loosely):

**Patterns & Architecture**
- "< problem category > architecture patterns"
- "< problem category > best practices < current year >"
- "< problem category > design patterns"

**Existing Solutions**
- "< problem category > open source library"
- "< problem category > AWS service" (we're AWS-native)
- "< problem category > npm package"
- "< problem category > SaaS solution"

**Standards & Compliance**
- "< problem category > industry standard"
- "< problem category > regulatory requirements" (if applicable)
- "< problem category > ISO standard" / "< problem category > compliance framework"

**Prior Art & Case Studies**
- "< problem category > implementation case study"
- "< problem category > lessons learned"
- "< problem category > common pitfalls"

**Domain-specific** (for this project's domains)
- RNG/biogas/sustainability compliance standards
- EU RED II/III regulatory requirements
- Energy certificate/guarantee of origin standards

Aim for 8-15 web searches. Read the most promising results. Don't be afraid to iterate on more searches based on what you find. or if it's a novel problem, look for adjacent domains that might have relevant patterns.

### 4. Check existing codebase

Search the codebase for related implementations, patterns, or prior attempts:

- Grep for domain-related keywords
- Check `doc/EDD/`, `doc/ADR/`, `doc/RFC/` for related design decisions
- Check if any existing packages or services partially solve the problem

### 5. Produce the discovery brief

Output a structured brief with the following sections:

```markdown
# Discovery Brief: < Task Title >

## Problem Framing

What we're actually solving (abstracted). List 2-4 alternative framings.

## Landscape Survey

### Established Patterns
- Pattern 1: brief description, when to use, trade-offs
- Pattern 2: ...

### Existing Solutions
| Solution | Type | Fit | Notes |
|----------|------|-----|-------|
| AWS EventBridge | Service | High | Native, serverless, ... |
| custom-lib | OSS | Medium | Would need adaptation... |

### Standards & Compliance
Relevant standards, regulations, or frameworks that apply.

### Prior Art
Notable implementations, case studies, or lessons learned.

## Codebase Context

What already exists in this repo that's relevant. Existing patterns, packages, decisions.

## Key Trade-offs

| Decision | Option A | Option B | Recommendation |
|----------|----------|----------|----------------|
| Build vs buy | Custom impl | AWS service | ... |
| Push vs pull | Event-driven | Polling | ... |

## Recommended Direction

1-2 paragraphs. Which framing to adopt, which patterns to follow, which solutions to leverage. Justify with evidence from the research.

## Open Questions

Things that need user input or further investigation before solutioning.
```

### 6. Discuss with user

Present the brief. Ask if they want to:
- Dive deeper into any section
- Adjust the direction before proceeding to solutioning
- Create an EDD based on these findings (use `create-edd` skill)

## Important Notes

- **Breadth over depth**: The goal is to widen the solution space, not to go deep on one approach
- **Cite sources**: Include URLs from web searches so findings can be verified
- **Stay neutral**: Present trade-offs honestly — don't pre-commit to a solution
- **Time-box**: This is research, not implementation. Keep it focused (15-20 min equivalent)
- **Be honest about gaps**: If research is inconclusive, say so. "I didn't find strong prior art" is a valid finding
