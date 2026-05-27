# Vin's Questions — AI Infrastructure Research

---

## 1. How could we handle "agent got stuck" scenarios?

Several layers apply here:

**At the Kubernetes level** — because kagent agents run as pods, standard `livenessProbe` / `readinessProbe` + `restartPolicy` already covers the most common case: if an agent process hangs, kubelet kills and restarts it.

**At the framework level** — kagent's `Agent` CRD supports `timeout` on task execution. Once the deadline fires, the controller marks the run as failed and can retry (configurable `retryPolicy`). This is the declarative equivalent of a watchdog.

**At the gateway level** — agentgateway (envoy-based) enforces HTTP request timeouts on all LLM calls. A stuck upstream provider doesn't block the agent indefinitely; the gateway returns a 504 and the agent gets a clear error to handle.

**At the governance level** — `mcp-governance` in this repo runs an AI-powered scan every 10 minutes (see `mcp-governance.yaml`) that can detect misbehaving agents and alert or quarantine them.

**Practical recommendation:** combine kagent task timeouts (short, e.g. 30 s per step) + agentgateway upstream timeouts + set `maxUnavailable: 1` in the Deployment's rolling update strategy so restarts don't knock out all replicas simultaneously. Add a `PodDisruptionBudget` on top to guard against node drains and cluster upgrades evicting all agent pods at once.

---

## 2. Any automatic timeout / circuit-breaker patterns coming from this framework?

Yes, from multiple components:

| Component | Mechanism |
|---|---|
| **agentgateway** | Per-backend `timeout`, passive outlier detection (consecutive 5xx → eject backend), and retry budgets — all Envoy primitives |
| **kagent** | Task-level `timeout` + `retryPolicy` on the `Agent` CRD |
| **mcp-governance** | `requireRateLimit: true` (see `mcp-governance.yaml`) — enforces rate limits on MCP tool calls, which acts as a soft circuit breaker |
| **Flux CD** | If a HelmRelease fails repeatedly, Flux suspends reconciliation — preventing bad versions from being re-applied in a loop |

Circuit-breaker semantics come from agentgateway's Envoy outlier detection and follow the standard three-state cycle: Closed (normal operation, requests pass through) → Open (error threshold breached, requests fail fast without hitting the backend) → Half-Open (after the eject interval expires, a probe request is allowed through to test recovery) → back to Closed on success, or Open again on failure. You configure the threshold via `consecutiveGatewayErrors` and the cooldown via `interval` in the `AgentgatewayBackend` or upstream `TrafficPolicy`.


---

## 3. How does kgateway handle model failover?

kgateway is a CNCF Envoy-based gateway implementing the Gateway API spec — it handles failover through weighted `backendRefs` on `HTTPRoute` resources and outlier detection in a `TrafficPolicy`. Once a backend accumulates enough consecutive errors, Envoy ejects it from the pool for a cooldown period and traffic shifts to the next healthy backend.

agentgateway (an AI-aware extension built on kgateway, published under the same `kgateway-dev` org) extends this and treats LLM providers as weighted backend pools. It also adds `AITrafficPolicy`, which can act on LLM-specific signals like token-budget headers before hard HTTP errors occur. Failover works like this:
1. You define multiple `AgentgatewayBackend` resources pointing to different providers (OpenAI, Anthropic, a local vLLM endpoint, etc.).
2. A `TrafficPolicy` on the `HTTPRoute` specifies priority or weighted distribution.
3. If a provider returns repeated errors (configurable threshold), Envoy's outlier detection ejects it from the pool for a cooldown period and traffic automatically shifts to the next healthy backend.
4. Health is checked passively (response codes) and optionally actively (periodic probe requests).

---

## 4. Can we automatically switch from OpenAI to Claude to local model?

Yes, this is a first-class use case for agentgateway:

```
OpenAI (primary) → Claude (secondary) → vLLM/local (tertiary)
```

Each provider gets an `AgentgatewayBackend`. The `HTTPRoute` (with a `TrafficPolicy`) selects among them based on priority + health. When OpenAI goes over quota or latency spikes past the threshold, traffic shifts to Claude; if Claude is also degraded, it falls to the local model.

**Caveats:**
- Model capability differs — a prompt tuned for GPT-4o may produce lower quality on a 7B local model.
- You can mitigate this by keeping the same system-prompt contract and letting the gateway handle transport-level failover transparently to the agent.
- The `kagent` `ModelConfig` CRD decouples the agent definition from the concrete model, making per-agent failover targets easy to configure without touching agent YAML.

---

## 5. Could we seamlessly handle the response formats from these providers?

Mostly yes — with caveats.

agentgateway normalises LLM traffic to the **OpenAI Chat Completions API shape**, so agents coded against that schema get consistent responses regardless of the backend. Anthropic's Claude, for example, is proxied through a translation layer that maps `role/content` arrays and tool-call structures.

**Where it gets rough:**
- Extended thinking / reasoning tokens (Claude's `thinking` blocks, OpenAI's `reasoning_effort`) are provider-specific and dropped or ignored by the proxy.
- Streaming format differences (SSE chunk shapes) can surface if agents consume raw streams.
- Tool call IDs and schemas differ slightly; test your tool-use flows against each backend before relying on automatic failover.

For the vast majority of text-in / text-out agentic steps, the abstraction holds well.

---

## 6. Can we version the agents built from kagent?

Yes — agents are Kubernetes CRDs (`Agent`, `ModelConfig`, `MCPServer`), which means:

- **Git is the version store.** Every change to `k8s-readonly-agent.yaml` is a git commit with full history.
- **Flux CD + OCI artifacts** mean agent versions can be tagged and promoted through environments (dev → staging → prod) the same way Helm chart versions are.
- **Kubernetes labels** (`version: v1.2.0`) on the `Agent` resource let you run multiple agent versions side-by-side in the same cluster.
- **kagent's controller** reconciles declarative state — rolling back an agent is `git revert` + push.

There is no native "agent version history" UI in kagent itself yet, but the GitOps workflow gives a full audit trail.

---

## 7. Any blue/green or canary deployment patterns for agents?

Native options:

**Blue/Green:** Deploy two `Agent` resources (`k8s-agent-v1`, `k8s-agent-v2`) in parallel. Flip the agentgateway `HTTPRoute` to point to the new one. Roll back in seconds by reverting the route.

**Canary:** Use agentgateway's weighted routing — send 10% of requests to the new agent version, 90% to the stable one. Increment gradually. The `AgentgatewayBackend` weight field supports this directly.

**With Flagger (progressive delivery):** Flagger can automate the canary increment based on error rate or latency metrics from Prometheus. Since agent responses go through agentgateway, the metrics are already there.

In this repo, the foundation is in place (agentgateway routes, Flux CD source control) — Flagger would be an additive component.

---

## 8. What's the fastmcp-python framework?

`fastmcp` is a high-level Python library for building **Model Context Protocol (MCP) servers**. It is now the recommended way to author MCP servers in Python.

Core idea: decorate a Python function → it becomes an MCP tool automatically.

```python
from fastmcp import FastMCP

mcp = FastMCP("my-server")

@mcp.tool()
def list_pods(namespace: str) -> list[str]:
    """Lists pods in a namespace."""
    ...
```

It handles the MCP wire protocol (JSON-RPC), tool schema generation from type hints, and both `stdio` and HTTP (`SSE`) transports.

---

## 9. Is fastmcp the easiest path to MCP?
For Python tool authoring - yes.
But if you're deploying to Kubernetes, `kmcp` goes further: it scaffolds the full project (kmcp init), generates the Dockerfile and Kubernetes manifests, and wires the result into kagent automatically. You still write fastmcp-style functions, but you never touch the deployment plumbing. That makes kmcp the easier end-to-end path for Kubernetes-based deployments.

Compared to alternatives:
- **Raw MCP Python SDK** — you write JSON-RPC handlers and schema dicts by hand.
- **TypeScript MCP SDK** — similar ergonomics to fastmcp but requires Node toolchain.
- **fastmcp alone** — simplest for writing the tool code, but you still have to containerise and deploy it yourself.
- **kmcp** — scaffolds the full project (`kmcp init`), builds the image, and deploys to Kubernetes with a single workflow. Easiest end-to-end path within the kagent ecosystem.

---

## 10–13. FinOps: token control, per-agent budgets, custom cost controls

**What's available today in this stack:**

| Control | Where | Granularity |
|---|---|---|
| Rate limiting | agentgateway `RateLimitPolicy` + mcp-governance | Per route / per agent namespace |
| Token limits | `ModelConfig` `maxTokens` field (kagent) | Per agent |
| Request quotas | Kubernetes `ResourceQuota` on the `kagent` namespace | Per namespace |
| Cost alerting | agentgateway metrics → Prometheus → Alertmanager | Cluster-wide |

**Per-agent token limits** are set in the `ModelConfig` CRD — `maxTokens`, `temperature`, etc. Each `Agent` references a `ModelConfig`, so you can give the cheap read-only agent a tight token budget and the conductor agent a larger one.

**Custom cost controls** require a bit more wiring:
- agentgateway exposes token-usage metrics (prompt tokens, completion tokens) per backend.
- A Prometheus recording rule can accumulate spend per `agent_name` label.
- A custom admission webhook or Flux automation can suspend an `Agent` when accumulated cost exceeds a budget threshold.

There is no out-of-the-box "budget exhausted → auto-suspend" feature in kagent 0.9.x, but the observability primitives to build it are present. This is an area the project is actively developing.

---

## 14. Is vLLM suitable for agents with many back-and-forth tool calls?

**Short answer:** vLLM is usable for agentic workloads, but it is better optimised for throughput than for the low-latency-per-call pattern that heavy tool-calling agents need.

**Why it matters for agents:**
An agent making 15 LLM calls per task cares about **latency per call** more than **tokens/second throughput**. vLLM's PagedAttention and continuous batching are tuned for maximising GPU utilisation across many concurrent requests — great for inference APIs serving many users, less ideal for a single agent doing sequential reasoning steps.

**What helps in vLLM for agents:**
- **Prefix caching** (radix cache): if each call re-sends the same system prompt + growing history, vLLM can cache the KV state for the common prefix, cutting TTFT significantly on subsequent calls.
- **Chunked prefill**: reduces jitter on short-context follow-up calls.
- **Speculative decoding**: can lower latency on short generation outputs (tool call JSON is usually short).

**Verdict:** vLLM works well when you need a flexible self-hosted setup. For agent-heavy workloads where every LLM call counts, llm-d or SGLang have an advantage due to smarter KV-cache scheduling. If you're running both agents and batch inference, vLLM covers both well enough.

---

## 15. Does llm-d's scheduler help when an agent makes 15 LLM calls?

**Yes — and this is precisely the scenario llm-d is designed for.**

llm-d (from Red Hat / IBM) is a Kubernetes-native distributed LLM serving framework with a **KV-cache-aware scheduler**. The key insight: for sequential agent calls from the same session, the KV cache computed for the system prompt + tool history is reusable — but only if the request lands on the same decode instance.

**How the scheduler helps:**
- It tracks which decode pod holds which KV cache prefix.
- When call #2 arrives from the same agent session, the scheduler routes it to the pod that already has the cached state from call #1.
- Cache hit → the model skips recomputing the prompt prefix → latency drops significantly (TTFT improvements vary widely by prompt length and model; expect meaningful gains on long shared contexts, but measure for your specific workload).

For 15 sequential calls within one agent run, the compounding benefit is significant: calls 2–15 all hit warm cache instead of recomputing a growing context from scratch each time.

**What's needed to use this:**
- llm-d deployed as the inference backend (replaces a standalone vLLM deployment).
- Requests must carry a consistent session identifier so the scheduler can track affinity.
- agentgateway can pass a `x-session-id` header downstream, making the integration straightforward.

**Bottom line:** if your agents are chatty (many calls, long shared context), llm-d's scheduler is worth the operational complexity over plain vLLM. For single-shot or low-call-count agents, the difference is negligible.
